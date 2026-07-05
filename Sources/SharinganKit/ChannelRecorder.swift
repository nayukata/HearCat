@preconcurrency import AVFoundation
import Foundation

/// 1チャンネル分(自分 or 相手)の音声を m4a (AAC) ファイルへ書き続ける。
/// ファイルは最初のバッファが届いた時に、そのバッファのフォーマットに合わせて遅延生成する。
/// (録音トグルがオフのまま終わったセッションに空ファイルを残さないため)
public actor ChannelRecorder {
    private let url: URL
    private var file: AVAudioFile?
    private var creationFailed = false
    private let converter = BufferConverter()

    public init(url: URL) {
        self.url = url
    }

    public func write(_ buffer: AVAudioPCMBuffer) {
        guard !creationFailed else { return }
        do {
            if file == nil {
                let format = buffer.format
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: Int(format.channelCount),
                    AVEncoderBitRateKey: 128_000,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings)
            }
            guard let file else { return }
            // AVAudioFile は processingFormat(非圧縮 PCM)のバッファしか受け付けない。
            let converted = try converter.convert(buffer, to: file.processingFormat)
            try file.write(from: converted)
        } catch {
            // 録音の失敗で文字起こしまで巻き込まない。以後の書き込みは諦めてログに残す。
            creationFailed = true
            FileHandle.standardError.write(
                Data("録音エラー(\(url.lastPathComponent)): \(error)\n".utf8))
        }
    }

    /// AVAudioFile は解放時にヘッダを確定してクローズされる。
    public func close() {
        file = nil
    }
}
