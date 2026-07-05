@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 1チャンネル分(自分 or 相手)のライブ文字起こし。
/// 生の AVAudioPCMBuffer を受け取り、確定/暫定のイベントを sink へ流す。
/// actor なのは、バッファ変換や解析投入を UI(メインスレッド)から切り離すため。
public actor ChannelTranscriber {
    private let speaker: String
    private let locale: Locale
    private let sink: AsyncStream<TranscriberEvent>.Continuation

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private let converter = BufferConverter()

    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var fedCount = 0

    /// 直近1分の解析用音声。確定文の時刻範囲から発話末尾を切り出し、
    /// ピッチ上昇(イントネーション疑問文)の判定に使う。
    private var ring: AudioRing?

    public init(speaker: String, locale: Locale, sink: AsyncStream<TranscriberEvent>.Continuation) {
        self.speaker = speaker
        self.locale = locale
        self.sink = sink
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputStream = stream
        self.inputContinuation = continuation
    }

    public func start() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // 暫定結果はライブ表示用。ファイルへ書くのは確定分のみ(ファイルを安定させるため)。
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])

        try await Self.ensureModel(for: transcriber, locale: locale)

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let format = analyzerFormat else { throw TranscriptionError.noAudioFormat }
        debugLog("\(speaker) analyzerFormat sr=\(format.sampleRate) ch=\(format.channelCount)")
        ring = AudioRing(capacity: Int(format.sampleRate) * 60)

        let speaker = self.speaker
        let sink = self.sink
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let raw = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { continue }
                    if result.isFinal {
                        let text = self.finalizeText(raw, range: result.range)
                        sink.yield(.final(TranscriptSegment(speaker: speaker, text: text, timestamp: Date())))
                    } else {
                        sink.yield(.volatile(speaker: speaker, text: raw))
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("[\(speaker)] 認識エラー: \(error)\n".utf8))
            }
        }

        try await analyzer?.start(inputSequence: inputStream)
    }

    /// 確定文の仕上げ。疑問文(語彙 or 末尾のピッチ上昇)なら文末を「？」に直す。
    private func finalizeText(_ text: String, range: CMTimeRange) -> String {
        if QuestionDetector.isLexicalQuestion(text) {
            return QuestionDetector.markAsQuestion(text)
        }
        guard let format = analyzerFormat, let ring else { return text }
        let sampleRate = format.sampleRate
        let endSeconds = range.end.seconds
        guard endSeconds.isFinite, endSeconds > 0 else { return text }
        // range.end は発話の終わりではなく、確定処理までの無音を含んだ広い範囲を指す。
        // そのため範囲全体(上限10秒)を渡し、末尾の有声区間の探索は検出器側に任せる。
        let endFrame = min(Int(endSeconds * sampleRate), ring.totalWritten)
        let startFrame = max(Int(range.start.seconds * sampleRate), endFrame - Int(sampleRate * 10))
        guard let tail = ring.slice(start: startFrame, end: endFrame) else {
            debugLog("\(speaker) 疑問判定: '\(text)' リング範囲外 range=\(range.start.seconds)-\(endSeconds) written=\(ring.totalWritten)")
            return text
        }
        let analysis = QuestionDetector.risingPitchAnalysis(tail: tail, sampleRate: sampleRate)
        if sharinganDebug {
            var sumSq: Float = 0
            for v in tail { sumSq += v * v }
            let rms = (sumSq / Float(max(tail.count, 1))).squareRoot()
            debugLog("\(speaker) 疑問判定: '\(text)' rising=\(analysis.rising) voiced=\(analysis.voicedFrames)/\(analysis.totalVoiced)/\(analysis.windows) head=\(Int(analysis.headF0)) tail=\(Int(analysis.tailF0)) sliceRms=\(rms) range=\(String(format: "%.2f", range.start.seconds))-\(String(format: "%.2f", endSeconds))")
        }
        if analysis.rising {
            return QuestionDetector.markAsQuestion(text)
        }
        return text
    }

    /// 生バッファを受け取り、解析フォーマットへ変換して analyzer へ流す。
    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let format = analyzerFormat else { return }
        do {
            let converted = try converter.convert(buffer, to: format)
            inputContinuation.yield(AnalyzerInput(buffer: converted))
            ring?.append(converted.monoFloatSamples())
            fedCount += 1
            if sharinganDebug && fedCount % 100 == 0 {
                debugLog("\(speaker) fed=\(fedCount) level=\(rmsLevel(converted))")
            }
        } catch {
            FileHandle.standardError.write(Data("[\(speaker)] 変換エラー: \(error)\n".utf8))
        }
    }

    public func stop() async {
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
