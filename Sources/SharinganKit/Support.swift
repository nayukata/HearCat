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
public enum TranscriberEvent: Sendable {
    case volatile(speaker: String, text: String)
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

// SHARINGAN_DEBUG=1 で診断ログを stderr に出す(音声レベル・フォーマット・認識の生結果)。
public let sharinganDebug = ProcessInfo.processInfo.environment["SHARINGAN_DEBUG"] != nil

public func debugLog(_ message: String) {
    guard sharinganDebug else { return }
    FileHandle.standardError.write(Data(("[debug] " + message + "\n").utf8))
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
    /// 音声スレッドが渡すバッファは即座に使い回される。
    /// 別スレッド(解析側)へ渡す前に深いコピーを取る。
    ///
    /// 実装メモ: AudioBufferList 経由の memcpy は罠がある。新規確保した AVAudioPCMBuffer の
    /// mutableAudioBufferList は mDataByteSize が 0 のことがあり、min(src, dst) すると 0 バイト
    /// コピー(= 無音)になる。そのため型付きチャンネルデータ(floatChannelData など)を直接使い、
    /// 該当しない稀なフォーマットは src の mDataByteSize を優先した AudioBufferList コピーで
    /// フォールバックする。
    public func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let frames = Int(frameLength)
        let channels = Int(format.channelCount)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
            return copy
        }
        if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
            return copy
        }
        if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
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
