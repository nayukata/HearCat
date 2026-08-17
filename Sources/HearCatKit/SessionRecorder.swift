@preconcurrency import AVFoundation
import Foundation

/// セッションの録音を audio.m4a 1本(モノラル、自分と相手のミックス)に書く。
/// 相手の音も録っている場合は、これに加えて相手だけの録音も書く。
///
/// なぜモノラルミックスか: 再生時に両者の声が左右どちらかに寄らず、
/// 両耳から自然に聞こえるようにするため。話者の区別は文字起こし側(話者ラベル)が担保する。
/// 音量設定(micGain / systemGain)は、そのままミックスバランスとして効く。
///
/// なぜ相手だけの録音を「録ったまま」ではなくここで分けるか: 2音源は開始位置合わせ・
/// 無音での穴埋め・遅配の相殺を通して初めて時間軸が揃う(下記の各処理)。素の音を別に
/// 書き出すとこの補正が乗らず、混ぜたものと再生位置が食い違って、文字起こしからの
/// ジャンプが当てにならなくなる。同じブロックから枝分かれさせることで2本の尺を揃える。
///
/// 設計メモ(なぜ AVAudioConverter を使わないか):
/// interleaved→deinterleaved の同レート変換に AVAudioConverter を使ったところ、
/// 各バッファの約半分が無音に置き換わる破損が実測で確認された(周期的なゲート状ノイズ)。
/// 録音のチャンネル取り出し・モノラル化・レート合わせはここで手書きの決定的な処理で行う。
/// (文字起こし側の 16kHz モノラル変換は実績があるためそのまま)
///
/// 設計メモ(録音中は .aac、停止時に .m4a へ変換する理由):
/// 録音中に直接 .m4a(MPEG-4 コンテナ)へ書くと、アプリが強制終了した場合コンテナの
/// 索引(moov)が確定せず、書きかけの録音がまるごと再生不能になる。この対策として
/// 「録音中は別の入れ物に書き、停止時に正常完了した場合だけ .m4a へ変換する」方式にする。
///
/// 入れ物には CAF ではなく拡張子 .aac(ADTS の AAC 生ストリーム)を選んだ。実機検証の結果、
/// CAF コンテナに AAC を書いた場合もパケット表(pakt チャンク)は close() 時にしか書かれず、
/// SIGKILL 相当の強制終了後は長さ0・変換不能になることを確認した(m4a の moov と同じ弱点を
/// 持つ)。一方 ADTS は各フレームが自己完結したヘッダを持つため索引を必要とせず、
/// 強制終了後に途中で切れたファイルでもそのまま読める・変換できることを実機で確認済み。
/// 停止時の .m4a への変換は AVAssetExportSession のパススルー(再エンコードなし)で行う。
public actor SessionRecorder {
    /// 書き出しのサンプルレート。ソースが異なるレートの場合は線形補間で合わせる。
    public static let sampleRate: Double = 48_000

    private let url: URL
    /// 相手だけの書き出し先。相手の音を録らないセッションでは分ける意味が
    /// ないため nil にして、混ぜたもの1本だけを書く。
    private let otherURL: URL?
    private let includesSystemChannel: Bool
    /// 録音中に実際に書き込む先(ADTS AAC の生ストリーム)。url/otherURL と同じ場所・
    /// 同じ基底名で拡張子だけ .aac にする。stop() の正常経路でだけ url/otherURL(.m4a)へ
    /// 変換する(型の doc comment を参照)。
    private let stagingURL: URL
    private let otherStagingURL: URL?
    private var file: AVAudioFile?
    private var otherFile: AVAudioFile?
    private var failed = false
    /// 書き込みが失敗して以後の録音を諦めた時に一度だけ呼ぶ。UI へ知らせる出口
    /// (SessionEngine が setOnFailure で設定し、SessionEngine.SessionHealthEvent へ変換して流す)。
    /// actor の外から設定・actor の外の文脈(呼び出し元のスレッド)で呼ばれ得るため
    /// @Sendable クロージャとして持つ。
    private var onFailureHandler: (@Sendable () -> Void)?

    /// 各音源の待ち行列。ミックスは時間軸が揃っていないと成立しないため、
    /// 両方が揃った分だけブロック単位で合成してファイルへ書く。
    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []
    /// 録音音量(設定画面から変更)。1.0 が原音。ミックス時の重みとして掛ける。
    /// マイクの自動メイクアップゲインは撤去した。自分の声(実測 RMS -53〜-59dB)を
    /// 相手(-26dB)に揃えるには 25〜40 倍の増幅が要るが、マイク信号の SN 比が約 20dB
    /// しかないため、ノイズフロアも可聴域(-42dB 前後)まで持ち上がり録音全体にヒスが乗る
    /// (実録音で確認)。録音は無加工で残し、音量差は再生側や設定のスライダーで補う。
    private var micGain: Float = 1
    private var systemGain: Float = 1
    /// マイクはシステム音声より先に動き出すため、相手側の最初のバッファが届いた時点で
    /// 先行分を捨てて2音源の開始位置を揃える。
    private var alignedToSystemStart = false

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

    public init(url: URL, otherURL: URL? = nil, includesSystemChannel: Bool) {
        self.url = url
        self.otherURL = includesSystemChannel ? otherURL : nil
        self.includesSystemChannel = includesSystemChannel
        self.stagingURL = Self.stagingURL(for: url)
        self.otherStagingURL = self.otherURL.map(Self.stagingURL(for:))
    }

    /// 書き込み失敗の通知先を設定する。SessionEngine がセッション開始時に一度だけ呼ぶ。
    public func setOnFailure(_ handler: @escaping @Sendable () -> Void) {
        onFailureHandler = handler
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

    /// 残りを無音詰めで書き切り、生ファイル(.aac)を最終形式(.m4a)へ変換してファイルを閉じる。
    /// 何も録音していなければ(一度も writeBlock が走っていなければ)変換対象が無いので true を返す。
    /// 変換に失敗した場合は false を返し、生ファイルは削除せずそのまま残す
    /// (次回起動時に RecordingRecovery が拾えるよう、データを消さないことを最優先にする)。
    @discardableResult
    public func close() async -> Bool {
        let remaining = max(micQueue.count, includesSystemChannel ? systemQueue.count : 0)
        if remaining > 0 {
            micQueue.append(contentsOf: repeatElement(0, count: remaining - micQueue.count))
            systemQueue.append(contentsOf: repeatElement(0, count: remaining - systemQueue.count))
            writeBlock(frames: remaining)
        }
        // AVAudioFile を解放してファイルハンドルを閉じる。パススルー変換は解放後でないと
        // 正しく読めない(解放前に読むと長さ0・変換失敗になることを実機で確認済み)。
        let didOpenMain = file != nil
        let didOpenOther = otherFile != nil
        file = nil
        otherFile = nil

        guard didOpenMain else { return true }

        let mainConverted = await Self.convertRecording(from: stagingURL, to: url)
        if mainConverted {
            try? FileManager.default.removeItem(at: stagingURL)
        }

        if didOpenOther, let otherStagingURL, let otherURL {
            // 相手だけの録音が変換できなくても、混ぜた本体の成否とは分けて扱う
            // (openOtherFile と同じ方針: 選べる音が減るだけで、録音そのものは失わない)。
            if await Self.convertRecording(from: otherStagingURL, to: otherURL) {
                try? FileManager.default.removeItem(at: otherStagingURL)
            } else {
                errorLog("相手だけの録音の変換に失敗しました(\(otherStagingURL.lastPathComponent))")
            }
        }
        return mainConverted
    }

    /// 生ファイル(.aac, ADTS の AAC 生ストリーム)を最終形式(.m4a)へ、再エンコードなしの
    /// パススルーで変換する。stop() 時の変換と、RecordingRecovery の起動時回収の両方が使う
    /// 共通の入口。
    public static func convertRecording(from stagingURL: URL, to finalURL: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: stagingURL.path) else { return false }
        let asset = AVURLAsset(url: stagingURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            errorLog("録音の変換に失敗しました(\(stagingURL.lastPathComponent)): エクスポートセッションを作成できません")
            return false
        }
        // 前回の失敗などで仕掛かりの .m4a が残っていると export が上書きできず失敗するため、先に消す。
        try? FileManager.default.removeItem(at: finalURL)
        do {
            try await export.export(to: finalURL, as: .m4a)
            return true
        } catch {
            errorLog("録音の変換に失敗しました(\(stagingURL.lastPathComponent)): \(error)")
            return false
        }
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
                file = try AVAudioFile(forWriting: stagingURL, settings: Self.encoderSettings)
                openOtherFile()
            }
            guard let file else { return }
            let format = file.processingFormat
            guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = block.floatChannelData, format.channelCount == 1 else {
                failed = true
                return
            }
            block.frameLength = AVAudioFrameCount(frames)
            // 相手だけの録音は、混ぜる前の値を同じブロックから取る(尺と位置を揃えるため)。
            let otherBlock = channelBlock(format: format, frames: frames, for: otherFile)
            // 2音源を重み付きで足し込む。同時発話で振り切れると折り返しノイズになるため [-1, 1] に収める。
            let out = data[0]
            let otherOut = otherBlock?.floatChannelData?[0]
            micQueue.withUnsafeBufferPointer { mic in
                systemQueue.withUnsafeBufferPointer { system in
                    for i in 0..<frames {
                        let me = mic[i] * micGain
                        let other = system[i] * systemGain
                        out[i] = max(-1, min(1, me + other))
                        otherOut?[i] = max(-1, min(1, other))
                    }
                }
            }
            try file.write(from: block)
            // 相手だけの録音が書けなくなっても、混ぜた本体は残す(再生の選択肢が
            // 減るだけで済ませ、録音そのものを落とさない)。
            writeChannel(otherBlock, to: &otherFile)
            micQueue.removeFirst(frames)
            systemQueue.removeFirst(frames)
        } catch {
            // 録音の失敗で文字起こしまで巻き込まない。以後の書き込みは諦めてログに残し、
            // 呼び出し側(SessionEngine)へ一度だけ知らせる。
            let alreadyFailed = failed
            failed = true
            errorLog("録音エラー(\(stagingURL.lastPathComponent)): \(error)")
            if !alreadyFailed { onFailureHandler?() }
        }
    }

    /// 2本とも同じ条件で書く(尺と音質を揃えるため)。[String: Any] は Sendable でないので
    /// 保持せず、必要になるたびに組み立てる。
    private static var encoderSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
    }

    /// 相手だけの書き出し先を開く。ここで失敗しても録音本体は続ける
    /// (選べる音が減るだけで、会議の記録そのものは失われない)。
    private func openOtherFile() {
        guard let otherStagingURL else { return }
        otherFile = try? AVAudioFile(forWriting: otherStagingURL, settings: Self.encoderSettings)
        if otherFile == nil { errorLog("相手だけの録音を開けません(\(otherStagingURL.lastPathComponent))") }
    }

    /// 録音中の生ファイルの場所。最終ファイル(.m4a)と同じディレクトリ・同じ基底名で
    /// 拡張子だけ .aac にする(ファイル名の規則自体は SessionInfo.Artifact が正本のため、
    /// ここでは拡張子の付け替えだけにとどめる)。
    static func stagingURL(for finalURL: URL) -> URL {
        finalURL.deletingPathExtension().appendingPathExtension("aac")
    }

    private func channelBlock(
        format: AVAudioFormat, frames: Int, for file: AVAudioFile?
    ) -> AVAudioPCMBuffer? {
        guard file != nil,
            let block = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        block.frameLength = AVAudioFrameCount(frames)
        return block
    }

    /// 相手だけの録音を書く。書けなくなったらそのファイルだけ諦める。
    private func writeChannel(_ block: AVAudioPCMBuffer?, to file: inout AVAudioFile?) {
        guard let block, let target = file else { return }
        do {
            try target.write(from: block)
        } catch {
            errorLog("片側だけの録音を中止します: \(error)")
            file = nil
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
