@preconcurrency import AVFoundation
import Foundation

/// 自分のマイク入力を AVAudioEngine で取得し、コピー済みバッファを stream に流す。
public final class MicSource {
    public let buffers: AsyncStream<SendableBuffer>
    private let continuation: AsyncStream<SendableBuffer>.Continuation
    private let engine = AVAudioEngine()

    public init() {
        let (stream, continuation) = AsyncStream<SendableBuffer>.makeStream()
        self.buffers = stream
        self.continuation = continuation
    }

    public func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        debugLog("mic capture format sr=\(format.sampleRate) ch=\(format.channelCount)")
        let continuation = self.continuation
        // tap のコールバックは音声スレッド。ここでは深いコピーだけ取って即 yield し、
        // 変換や解析といった重い処理は消費側(別スレッド)に任せる。
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let copy = buffer.deepCopy() else { return }
            continuation.yield(SendableBuffer(buffer: copy))
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
    }
}
