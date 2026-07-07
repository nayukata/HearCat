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

    /// マイク自動メイクアップゲイン。実録音で自分の声が RMS -53〜-59dB、
    /// システム音声(相手)が -26dB と、素の信号のままでは自分の声がほぼ聞こえない
    /// (Zoom 等は自前のマイク AGC でこの差を補正している)。ここではマイク側だけに
    /// 自動ゲインを掛けて、システム音声に対して聞き取れる音量まで底上げする。
    private var autoMicGain: Float = 1
    /// 発話レベルの指数移動平均(EMA)。無音・環境ノイズのブロックでは更新しないことで、
    /// 目標ゲインが無音側に引きずられないようにする。未確定の間はゲインを 1 のまま保つ。
    private var speechLevelEMA: Float?
    /// これ未満は無音・環境ノイズとみなし EMA を更新しない。
    private static let speechEMAThreshold: Float = 0.0015
    /// EMA の更新係数。大きいほど直近のブロックに素早く追従する。
    private static let speechEMAAlpha: Float = 0.2
    /// 発話の目標 RMS。システム音声側の実測 -26dB(≈0.05)に揃える。
    private static let targetSpeechRMS: Float = 0.05
    /// 自動ゲインの上限。実測差 約30dB(+32dB ≈ 40倍)を超えて増幅しない。
    private static let maxAutoMicGain: Float = 40
    /// 目標ゲインへ毎ブロック追従させる割合。ブロックは 0.1 秒なので約1秒で追従し、
    /// 音量急変時のポンピング(急激な音量変化の耳障りな上下動)を防ぐ。
    private static let autoGainSmoothing: Float = 0.1

    /// 0.1秒ぶんずつ書く。小さすぎる書き込みはエンコーダに優しくない。
    private let blockFrames = 4800
    /// 片側だけが延々と溜まる異常時(相手側の停止など)に、無音で埋めて書き続ける閾値。
    /// 認識器の重い処理でポンプが数秒詰まる(実測4〜5秒)ことがあるため、
    /// 一時的な遅配では発火しないよう余裕を取る。
    private let starvationFrames = 15 * 48_000

    /// 穴埋めの「借り」(フレーム数)。無音で埋めた時間帯の音声が遅れて届いた場合、
    /// そのまま足すと同じ時間帯が二重に書かれ、録音が実時間より長くなる
    /// (実測で12〜24%伸び、再生位置が後半ほどズレた)。埋めた分を借りとして持ち、
    /// 後から届いた音声を相殺して捨てることで時間軸を守る。
    /// 音源が本当に死んでいて遅配分が存在しない場合は、復帰後の実音声を
    /// 借りぶん捨てることになるが、時間軸の破綻よりは軽い損失として許容する。
    private var micPadDebt = 0
    private var systemPadDebt = 0

    /// 借りがあれば届いたサンプルと相殺し、残りを返す。
    private static func repayPadDebt(_ samples: [Float], debt: inout Int) -> [Float] {
        guard debt > 0, !samples.isEmpty else { return samples }
        let drop = min(debt, samples.count)
        debt -= drop
        return Array(samples.dropFirst(drop))
    }

    /// 診断用(HEARCAT_DEBUG)。録音が実時間より長くなる問題の計測に使う:
    /// 各音源の到着レートと書き込みレートを壁時計と比べ、どこで時間が水増し
    /// されているかを切り分ける。
    private var diagStartedAt: Date?
    private var diagMicInFrames = 0
    private var diagSystemInFrames = 0
    private var diagWrittenFrames = 0
    private var diagMicPadFrames = 0
    private var diagSystemPadFrames = 0
    private var diagLastReportAt = Date.distantPast

    private func diagReportIfDue() {
        guard hearcatDebug else { return }
        let now = Date()
        guard let start = diagStartedAt else {
            diagStartedAt = now
            diagLastReportAt = now
            return
        }
        guard now.timeIntervalSince(diagLastReportAt) >= 10 else { return }
        diagLastReportAt = now
        let wall = now.timeIntervalSince(start)
        let rate = Self.sampleRate
        debugLog(
            "録音診断 壁=\(String(format: "%.1f", wall))s"
                + " mic入=\(String(format: "%.1f", Double(diagMicInFrames) / rate))s"
                + " sys入=\(String(format: "%.1f", Double(diagSystemInFrames) / rate))s"
                + " 書出=\(String(format: "%.1f", Double(diagWrittenFrames) / rate))s"
                + " mic穴埋=\(String(format: "%.1f", Double(diagMicPadFrames) / rate))s"
                + " sys穴埋=\(String(format: "%.1f", Double(diagSystemPadFrames) / rate))s")
    }

    public init(url: URL, includesSystemChannel: Bool) {
        self.url = url
        self.includesSystemChannel = includesSystemChannel
    }

    public func appendMic(_ buffer: AVAudioPCMBuffer) {
        var samples = Self.monoSamples(buffer, targetRate: Self.sampleRate)
        diagMicInFrames += samples.count
        samples = Self.repayPadDebt(samples, debt: &micPadDebt)
        micQueue.append(contentsOf: samples)
        drain()
    }

    public func appendSystem(_ buffer: AVAudioPCMBuffer) {
        if !alignedToSystemStart {
            micQueue.removeAll()
            alignedToSystemStart = true
        }
        var samples = Self.monoSamples(buffer, targetRate: Self.sampleRate)
        diagSystemInFrames += samples.count
        samples = Self.repayPadDebt(samples, debt: &systemPadDebt)
        systemQueue.append(contentsOf: samples)
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
            // 埋めた分は借りとして記録し、遅れて届いた本物と相殺する(二重計上防止)。
            if micQueue.count - systemQueue.count > starvationFrames {
                let pad = micQueue.count - systemQueue.count
                diagSystemPadFrames += pad
                systemPadDebt += pad
                systemQueue.append(contentsOf: repeatElement(0, count: pad))
            } else if systemQueue.count - micQueue.count > starvationFrames {
                let pad = systemQueue.count - micQueue.count
                diagMicPadFrames += pad
                micPadDebt += pad
                micQueue.append(contentsOf: repeatElement(0, count: pad))
            }
        } else {
            systemQueue.append(contentsOf: repeatElement(0, count: micQueue.count - systemQueue.count))
        }
        while min(micQueue.count, systemQueue.count) >= blockFrames {
            writeBlock(frames: blockFrames)
            diagWrittenFrames += blockFrames
        }
        diagReportIfDue()
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
                    updateAutoMicGain(mic: mic, frames: frames)
                    for i in 0..<frames {
                        let mixed = mic[i] * micGain * autoMicGain + system[i] * systemGain
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
            errorLog("録音エラー(\(url.lastPathComponent)): \(error)")
        }
    }

    /// マイク側(ゲイン適用前の素の値)のブロック RMS から自動ゲインを更新する。
    /// micGain を掛ける直前の生サンプルを見るのは、ユーザー設定の音量スライダーと
    /// 独立に「発話の物理的な大きさ」を追跡するため(スライダーを動かすたびに
    /// 目標が変わってしまうのを避ける)。
    private func updateAutoMicGain(mic: UnsafeBufferPointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var sumSquares: Float = 0
        for i in 0..<frames { sumSquares += mic[i] * mic[i] }
        let rms = (sumSquares / Float(frames)).squareRoot()

        if rms > Self.speechEMAThreshold {
            if let ema = speechLevelEMA {
                speechLevelEMA = ema + Self.speechEMAAlpha * (rms - ema)
            } else {
                speechLevelEMA = rms
            }
        }

        guard let ema = speechLevelEMA, ema > 0 else { return }
        let target = max(1, min(Self.maxAutoMicGain, Self.targetSpeechRMS / ema))
        autoMicGain += (target - autoMicGain) * Self.autoGainSmoothing
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
