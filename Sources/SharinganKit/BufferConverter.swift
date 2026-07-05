@preconcurrency import AVFoundation
import Foundation
import os

/// 入力バッファを SpeechAnalyzer が要求するフォーマットへ変換する。
/// マイクとシステム音声でサンプルレート/チャンネル数が異なるため、チャンネルごとに1インスタンス持つ。
public final class BufferConverter {
    public enum ConvertError: Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    public init() {}

    public func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        // すでに目的フォーマットなら変換しない(無駄なコピーと遅延を避ける)。
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            // ストリーミングでは priming の遅延を避けたいので none。
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConvertError.failedToCreateConverter }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw ConvertError.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        let fed = OSAllocatedUnfairLock(initialState: false)
        // 入力ブロックはソースバッファを1回だけ渡し、以降は noDataNow を返す。
        let status = converter.convert(to: output, error: &nsError) { _, inputStatus in
            let already = fed.withLock { done -> Bool in
                let was = done
                done = true
                return was
            }
            inputStatus.pointee = already ? .noDataNow : .haveData
            return already ? nil : buffer
        }
        guard status != .error else { throw ConvertError.conversionFailed(nsError) }
        return output
    }
}
