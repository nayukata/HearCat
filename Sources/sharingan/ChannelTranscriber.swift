@preconcurrency import AVFoundation
import Foundation
import Speech

/// 1チャンネル分(自分 or 相手)のライブ文字起こし。
/// 生の AVAudioPCMBuffer を受け取り、確定したテキストだけを sink へ流す。
@MainActor
final class ChannelTranscriber {
    private let speaker: String
    private let locale: Locale
    private let sink: AsyncStream<TranscriptSegment>.Continuation

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private let converter = BufferConverter()

    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var fedCount = 0

    init(speaker: String, locale: Locale, sink: AsyncStream<TranscriptSegment>.Continuation) {
        self.speaker = speaker
        self.locale = locale
        self.sink = sink
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputStream = stream
        self.inputContinuation = continuation
    }

    func start() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // 暫定結果も受け取るが、書き出すのは確定分のみ(ファイルを安定させるため)。
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])

        try await Self.ensureModel(for: transcriber, locale: locale)

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let format = analyzerFormat else { throw TranscriptionError.noAudioFormat }
        debugLog("\(speaker) analyzerFormat sr=\(format.sampleRate) ch=\(format.channelCount)")

        let speaker = self.speaker
        let sink = self.sink
        resultsTask = Task { @MainActor in
            do {
                for try await case let result in transcriber.results {
                    // 確定した結果だけをファイルへ。暫定(volatile)は捨てる。
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    sink.yield(TranscriptSegment(speaker: speaker, text: text, timestamp: Date()))
                }
            } catch {
                FileHandle.standardError.write(Data("[\(speaker)] 認識エラー: \(error)\n".utf8))
            }
        }

        try await analyzer?.start(inputSequence: inputStream)
    }

    /// 生バッファを受け取り、解析フォーマットへ変換して analyzer へ流す。
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let format = analyzerFormat else { return }
        do {
            let converted = try converter.convert(buffer, to: format)
            inputContinuation.yield(AnalyzerInput(buffer: converted))
            fedCount += 1
            if sharinganDebug && fedCount % 100 == 0 {
                debugLog("\(speaker) fed=\(fedCount) level=\(rmsLevel(converted))")
            }
        } catch {
            FileHandle.standardError.write(Data("[\(speaker)] 変換エラー: \(error)\n".utf8))
        }
    }

    func stop() async {
        inputContinuation.finish()
        // 末尾に残った音声を確定結果として吐き出してから停止する。
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
    }

    /// ja-JP の認識モデルが未DLならダウンロードし、locale を予約(reserve)する。
    private static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw TranscriptionError.localeNotSupported
        }
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: locale)
        }
    }
}
