@preconcurrency import AVFoundation
import Foundation

/// セッションの録音を audio.m4a 1本(モノラル、自分と相手のミックス)に書く。
///
/// なぜモノラルミックスか: 再生時に両者の声が左右どちらかに寄らず、
/// 両耳から自然に聞こえるようにするため。話者の区別は文字起こし側(話者ラベル)が担保する。
/// 音量設定(micGain / systemGain)は、そのままミックスバランスとして効く。
///
/// 設計メモ(なぜ AVAudioConverter を使わないか):
/// interleaved→deinterleaved の同レート変換に AVAudioConverter を使ったところ、
/// 各バッファの約半分が無音に置き換わる破損が実測で確認された(周期的なゲート状ノイズ)。
/// 録音のチャンネル取り出し・モノラル化・レート合わせはここで手書きの決定的な処理で行う。
/// (文字起こし側の 16kHz モノラル変換は実績があるためそのまま)
public actor SessionRecorder {
    /// 書き出しのサンプルレート。ソースが異なるレートの場合は線形補間で合わせる。
    public static let sampleRate: Double = 48_000

    private let url: URL
    private let includesSystemChannel: Bool
    private var file: AVAudioFile?
    private var failed = false

    /// 各音源の待ち行列。ミックスは時間軸が揃っていないと成立しないため、
    /// 両方が揃った分だけブロック単位で合成してファイルへ書く。
    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []
    /// 録音音量(設定画面から変更)。1.0 が原音。ミックス時の重みとして掛ける。
    private var micGain: Float = 1
    private var systemGain: Float = 1
    /// マイクはシステム音声より先に動き出すため、相手側の最初のバッファが届いた時点で
    /// 先行分を捨てて2音源の開始位置を揃える。
    private var alignedToSystemStart = false

    /// 0.1秒ぶんずつ書く。小さすぎる書き込みはエンコーダに優しくない。
    private let blockFrames = 4800
    /// 片側だけが延々と溜まる異常時(相手側の停止など)に、無音で埋めて書き続ける閾値。
    private let starvationFrames = 5 * 48_000

    public init(url: URL, includesSystemChannel: Bool) {
        self.url = url
        self.includesSystemChannel = includesSystemChannel
    }

    public func appendMic(_ buffer: AVAudioPCMBuffer) {
        micQueue.append(contentsOf: Self.monoSamples(buffer, targetRate: Self.sampleRate))
        drain()
    }

    public func appendSystem(_ buffer: AVAudioPCMBuffer) {
        if !alignedToSystemStart {
            micQueue.removeAll()
            alignedToSystemStart = true
        }
        systemQueue.append(contentsOf: Self.monoSamples(buffer, targetRate: Self.sampleRate))
        drain()
    }

    /// 録音音量(ミックスバランス)を変える。セッション中でも即座に(次のブロックから)反映される。
    public func setGains(mic: Float, system: Float) {
        micGain = mic
        systemGain = system
    }

    /// 録音トグルをオフにした時に呼ぶ。中途半端に残った分は捨てて、
    /// 再開時に両音源が揃った状態から始める(音源間のずれを溜めないため)。
    public func pause() {
        micQueue.removeAll()
        systemQueue.removeAll()
    }

    /// 残りを無音詰めで書き切ってファイルを閉じる。
    public func close() {
        let remaining = max(micQueue.count, includesSystemChannel ? systemQueue.count : 0)
        if remaining > 0 {
            micQueue.append(contentsOf: repeatElement(0, count: remaining - micQueue.count))
            systemQueue.append(contentsOf: repeatElement(0, count: remaining - systemQueue.count))
            writeBlock(frames: remaining)
        }
        file = nil
    }

    // MARK: - 書き込み

    private func drain() {
        if includesSystemChannel {
            // 異常時の保険: 片側だけ溜まり続けたら、足りない側を無音で埋めて前へ進む。
            if micQueue.count - systemQueue.count > starvationFrames {
                systemQueue.append(contentsOf: repeatElement(0, count: micQueue.count - systemQueue.count))
            } else if systemQueue.count - micQueue.count > starvationFrames {
                micQueue.append(contentsOf: repeatElement(0, count: systemQueue.count - micQueue.count))
            }
        } else {
            systemQueue.append(contentsOf: repeatElement(0, count: micQueue.count - systemQueue.count))
        }
        while min(micQueue.count, systemQueue.count) >= blockFrames {
            writeBlock(frames: blockFrames)
        }
    }

    private func writeBlock(frames: Int) {
        guard !failed else {
            micQueue.removeFirst(min(frames, micQueue.count))
            systemQueue.removeFirst(min(frames, systemQueue.count))
            return
        }
        do {
            if file == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 96_000,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings)
            }
            guard let file else { return }
            let format = file.processingFormat
            guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = block.floatChannelData, format.channelCount == 1 else {
                failed = true
                return
            }
            block.frameLength = AVAudioFrameCount(frames)
            // 2音源を重み付きで足し込む。同時発話で振り切れると折り返しノイズになるため [-1, 1] に収める。
            let out = data[0]
            micQueue.withUnsafeBufferPointer { mic in
                systemQueue.withUnsafeBufferPointer { system in
                    for i in 0..<frames {
                        let mixed = mic[i] * micGain + system[i] * systemGain
                        out[i] = max(-1, min(1, mixed))
                    }
                }
            }
            try file.write(from: block)
            micQueue.removeFirst(frames)
            systemQueue.removeFirst(frames)
        } catch {
            // 録音の失敗で文字起こしまで巻き込まない。以後の書き込みは諦めてログに残す。
            failed = true
            FileHandle.standardError.write(Data("録音エラー(\(url.lastPathComponent)): \(error)\n".utf8))
        }
    }

    // MARK: - モノラル化とレート合わせ(決定的な手書き処理)

    /// 任意フォーマットの PCM バッファをモノラル Float 列にし、必要なら線形補間でレートを合わせる。
    static func monoSamples(_ buffer: AVAudioPCMBuffer, targetRate: Double) -> [Float] {
        let mono = buffer.monoFloatSamples()
        let frames = mono.count
        guard frames > 0 else { return [] }

        let sourceRate = buffer.format.sampleRate
        guard sourceRate != targetRate else { return mono }
        // レートが違う場合のみ線形補間で合わせる(音声用途では十分な品質)。
        let ratio = sourceRate / targetRate
        let outFrames = Int((Double(frames) / ratio).rounded(.down))
        var resampled = [Float](repeating: 0, count: outFrames)
        for i in 0..<outFrames {
            let pos = Double(i) * ratio
            let index = Int(pos)
            let frac = Float(pos - Double(index))
            let next = min(index + 1, frames - 1)
            resampled[i] = mono[index] * (1 - frac) + mono[next] * frac
        }
        return resampled
    }
}
