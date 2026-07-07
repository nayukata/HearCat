@preconcurrency import AVFoundation
import Foundation

/// 確定した1発話ぶんの文字起こし。話者ラベルと壁時計の時刻を持つ。
public struct TranscriptSegment: Sendable {
    public let speaker: String
    public let text: String
    public let timestamp: Date

    public init(speaker: String, text: String, timestamp: Date) {
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }
}

/// 文字起こしの途中経過。ファイルには確定(final)だけを書き、
/// 暫定(volatile)は UI のライブ表示にだけ使う。
/// startedAt はその発話が始まった実時刻。ライブ表示が「認識中」の行を
/// 確定行と同じ時系列(話し始めた順)に並べるために使う。
public enum TranscriberEvent: Sendable {
    case volatile(speaker: String, text: String, startedAt: Date)
    case final(TranscriptSegment)
}

/// AVAudioPCMBuffer は Sendable でない。
/// ここでは「コピー済みバッファを音声スレッドから消費側へ1回だけ受け渡す」用途に限定するため、
/// @unchecked Sendable で包んで安全に運ぶ。
public struct SendableBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

// HEARCAT_DEBUG=1 で診断ログを出す(音声レベル・フォーマット・認識の生結果)。
public let hearcatDebug = ProcessInfo.processInfo.environment["HEARCAT_DEBUG"] != nil

/// 診断ログの書き込み先。stderr は open/Finder 経由の起動で失われるため、
/// HEARCAT_DEBUG 時はファイル(~/Library/Application Support/HearCat/debug.log)にも残す。
/// 複数 actor から呼ばれるためロックで直列化する。
private final class DebugLogFile: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    private let formatter: DateFormatter

    init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        guard hearcatDebug else {
            handle = nil
            return
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearCat")
        let url = dir.appendingPathComponent("debug.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        write("==== 起動 \(Date().formatted()) ====")
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[debug] \(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        try? handle?.write(contentsOf: Data(line.utf8))
    }
}

private let debugLogFile = DebugLogFile()

public func debugLog(_ message: String) {
    guard hearcatDebug else { return }
    debugLogFile.write(message)
}

/// エラーの報告。常に stderr へ出し、HEARCAT_DEBUG 時は診断ファイルにも残す。
public func errorLog(_ message: String) {
    if hearcatDebug {
        debugLogFile.write(message)
    } else {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// バッファの音量(RMS)。音声が届いているか(無音でないか)の切り分けに使う。
/// Float32 / Int16 の両方に対応する(SpeechAnalyzer 側は Int16 で来ることが多い)。
public func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return -1 }
    if let channel = buffer.floatChannelData {
        var sum: Float = 0
        let data = channel[0]
        for i in 0..<frames { sum += data[i] * data[i] }
        return (sum / Float(frames)).squareRoot()
    }
    if let channel = buffer.int16ChannelData {
        var sum: Double = 0
        let data = channel[0]
        for i in 0..<frames {
            let v = Double(data[i]) / 32768.0
            sum += v * v
        }
        return Float((sum / Double(frames)).squareRoot())
    }
    return -1
}

public enum TranscriptionError: Error {
    case localeNotSupported
    case noAudioFormat
}

public enum SystemAudioError: Error {
    case tapCreateFailed(OSStatus)
    case aggregateCreateFailed(OSStatus)
    case formatFailed
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)
    case propertyFailed(OSStatus)
}

extension AVAudioPCMBuffer {
    /// 全チャンネルを平均したモノラル Float 列。
    /// interleaved / deinterleaved、Float32 / Int16 の両対応。該当しないフォーマットは空を返す。
    public func monoFloatSamples() -> [Float] {
        let frames = Int(frameLength)
        guard frames > 0 else { return [] }
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frames)

        if let data = floatChannelData {
            if format.isInterleaved {
                let p = data[0]
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += p[i * channels + c] }
                    mono[i] = sum / Float(channels)
                }
            } else {
                for c in 0..<channels {
                    let p = data[c]
                    for i in 0..<frames { mono[i] += p[i] }
                }
                let scale = 1 / Float(channels)
                for i in 0..<frames { mono[i] *= scale }
            }
            return mono
        }
        if let data = int16ChannelData {
            let scale = 1 / (Float(channels) * 32768)
            if format.isInterleaved {
                let p = data[0]
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += Float(p[i * channels + c]) }
                    mono[i] = sum * scale
                }
            } else {
                for c in 0..<channels {
                    let p = data[c]
                    for i in 0..<frames { mono[i] += Float(p[i]) }
                }
                for i in 0..<frames { mono[i] *= scale }
            }
            return mono
        }
        return []
    }

    /// 音声スレッドが渡すバッファは即座に使い回される。
    /// 別スレッド(解析側)へ渡す前に深いコピーを取る。
    ///
    /// 実装メモ: AudioBufferList 経由の memcpy は罠がある。新規確保した AVAudioPCMBuffer の
    /// mutableAudioBufferList は mDataByteSize が 0 のことがあり、min(src, dst) すると 0 バイト
    /// コピー(= 無音)になる。そのため型付きチャンネルデータ(floatChannelData など)を直接使い、
    /// 該当しない稀なフォーマットは src の mDataByteSize を優先した AudioBufferList コピーで
    /// フォールバックする。
    ///
    /// interleaved フォーマットはチャンネル全部が1本のバッファ(plane)に詰まっているため、
    /// コピーする要素数は frames × channels。frames だけコピーすると後半が欠けて
    /// 周期的なゲート状ノイズ(無音まじりの機械音)になる。
    public func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let frames = Int(frameLength)
        let channels = Int(format.channelCount)
        let planes = format.isInterleaved ? 1 : channels
        let valuesPerPlane = format.isInterleaved ? frames * channels : frames
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for p in 0..<planes { dst[p].update(from: src[p], count: valuesPerPlane) }
            return copy
        }
        if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for p in 0..<planes { dst[p].update(from: src[p], count: valuesPerPlane) }
            return copy
        }
        if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for p in 0..<planes { dst[p].update(from: src[p], count: valuesPerPlane) }
            return copy
        }
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dstList = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        guard srcList.count == dstList.count else { return nil }
        for i in 0..<srcList.count {
            guard let s = srcList[i].mData, let d = dstList[i].mData else { continue }
            let bytes = Int(srcList[i].mDataByteSize)
            memcpy(d, s, bytes)
            dstList[i].mDataByteSize = UInt32(bytes)
        }
        return copy
    }
}
