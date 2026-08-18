import CSpeexDSP
import os

/// speexdsp (mdf.c) を使ったエコーキャンセラ。
/// マイク音声(近端)から、通話相手の音声(参照/遠端)由来の回り込みを除去する。
///
/// マイク側とシステム音声側は別々の音声ポンプタスクが独立に動かしており、
/// 「マイクは先に動き出すのにシステム音声は遅れて届く」「届くタイミングに毎回ジッタがある」
/// という前提を置く必要がある。これに対処するため、単純なフレーム処理に加えて
/// アンカー(基準合わせ)と自己修復の仕組みを持つ。詳細は各メソッドのコメントを参照。
///
/// 適応フィルタ(mdf)だけでは打ち消しきれない残渣が数〜十数dB残ることがあるため、
/// speexdsp の標準構成に合わせて後段に preprocess(残渣エコー抑制)を通す。
/// echo state と結合させることで、フィルタが処理しきれなかった分をスペクトル領域で追加減衰する。
///
/// 内部状態は単一のロックで直列化する(マイク側/システム音声側の2タスクから同時に呼ばれる前提)。
public final class EchoCanceller: @unchecked Sendable {
    // OpaquePointer(preprocessState)自体はSendableでないが、外へ漏らさずlockの内側でしか
    // 触らないため@unchecked Sendableとする(クラス全体の方針と同じ)。
    private struct State: @unchecked Sendable {
        /// pushReference が一度でも来たか。来るまで process() は素通しにする(アンカー方式)。
        var isAnchored = false
        /// 近端遅延線: 直近 nearDelaySamples 分は「まだ実時間が浅い」として保持し、
        /// それより前に受け取った分だけをフレーム形成へ回す。
        var nearDelayHold: [Float] = []
        /// 遅延線から解放された近端のうち、まだ 1 フレーム分に満たない端数。
        var pendingNear: [Float] = []
        /// pushReference() で溜めた参照音声。readIndex より前は消費済み。
        var referenceStorage: [Float] = []
        var referenceReadIndex = 0
        /// 計算済みだが process() の呼び出し元にまだ返していない出力。
        var pendingOutput: [Float] = []
        /// 現在のアンカー区間で発生した参照ゼロ埋めの累積サンプル数(自己修復の判定に使う)。
        var cumulativeZeroFillSamples = 0
        /// 通算の再アンカー回数(診断用。reset() 以外では引き継ぐ)。
        var reAnchorCount = 0
        /// 残渣エコー抑制(後段)。アンカーごとに echo state と結合して作り直す。
        /// nil は speexdsp 側の初期化失敗を意味し、その場合は echo cancellation の出力をそのまま使う。
        var preprocessState: OpaquePointer?
        /// runFrame が毎フレーム使い回すスクラッチバッファ(frameSize 固定長)。
        /// 同サイズの配列を毎フレーム確保しないために、init 時(と reset 後)に1回だけ用意する。
        var scratchRefFrame: [Float] = []
        var scratchNearInt16: [Int16] = []
        var scratchRefInt16: [Int16] = []
        var scratchOutInt16: [Int16] = []
        var scratchOutputFloat: [Float] = []
    }

    private let speexState: OpaquePointer
    private let sampleRate: Double
    private let frameSize: Int
    /// 近端遅延線の長さ(200ms)。物理的な回り込み遅延(実測40〜60ms)を補正するためではなく、
    /// マイク側/システム音声側2タスクの起動・到着タイミングのずれを吸収するための余裕。
    private let nearDelaySamples: Int
    /// pendingOutput の起動時プライマー。近端遅延線の分(nearDelaySamples)に加えて
    /// フレーム端数のジッタ(最大 frameSize-1)も吸収できる大きさにする。
    private let outputPrimerSamples: Int
    /// 参照の未消費深さがこれを超えたら「溜めすぎ」とみなし再アンカーする。フィルタ長と揃える。
    private let maxReferenceDepthSamples: Int
    /// 参照ゼロ埋めの累積がこれを超えたら「参照が届かなくなった」とみなし再アンカーする。
    private let zeroFillReAnchorThresholdSamples: Int
    private let lock: OSAllocatedUnfairLock<State>

    /// - Parameter sampleRate: マイク/参照音声のサンプルレート(HearCat では 48000 を想定)。
    public init?(sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let frameSize = Int((sampleRate * 0.02).rounded())
        // 実測で回り込み遅延は40〜60msだったが、フレーム同期のジッタ吸収分(近端遅延線200ms)を
        // 中央に収めてなお両側に余裕を持たせるため、フィルタ長は600msに拡張する。
        let filterLength = Int((sampleRate * 0.6).rounded())
        guard frameSize > 0, filterLength > 0,
              let rawState = speex_echo_state_init(Int32(frameSize), Int32(filterLength)) else {
            return nil
        }
        var rate = Int32(sampleRate)
        withUnsafeMutablePointer(to: &rate) { ptr in
            _ = speex_echo_ctl(rawState, SPEEX_ECHO_SET_SAMPLING_RATE, ptr)
        }
        self.speexState = rawState
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.nearDelaySamples = Int((sampleRate * 0.2).rounded())
        self.outputPrimerSamples = self.nearDelaySamples + frameSize
        self.maxReferenceDepthSamples = filterLength
        self.zeroFillReAnchorThresholdSamples = Int((sampleRate * 0.1).rounded())
        var initialState = State()
        Self.resetScratch(&initialState, frameSize: frameSize)
        self.lock = OSAllocatedUnfairLock(initialState: initialState)
    }

    deinit {
        lock.withLock { state in
            if let preprocessState = state.preprocessState {
                speex_preprocess_state_destroy(preprocessState)
            }
        }
        speex_echo_state_destroy(speexState)
    }

    /// 現在の参照バッファの未消費深さ(ミリ秒)。アンカー前は 0。
    public var referenceDepthMilliseconds: Double {
        lock.withLock { state in
            guard state.isAnchored else { return 0 }
            let depth = state.referenceStorage.count - state.referenceReadIndex
            return Double(depth) / sampleRate * 1000
        }
    }

    /// 現在のアンカー区間で累積した参照ゼロ埋め量(ミリ秒)。100ms超で再アンカーする。
    public var cumulativeZeroFillMilliseconds: Double {
        lock.withLock { Double($0.cumulativeZeroFillSamples) / sampleRate * 1000 }
    }

    /// 通算の再アンカー回数。0 なら一度も自己修復が発生していない。
    public var reAnchorCount: Int {
        lock.withLock { $0.reAnchorCount }
    }

    /// 相手音声(モノラル・近端と同レート)を参照バッファへ追記する。
    ///
    /// アンカー方式: これがアンカー前(まだ一度も呼ばれていない、または直近で再アンカーした)
    /// 最初の呼び出しなら、この瞬間を基準点として近端との対応づけを始める。
    /// 参照の未消費深さがフィルタ長(600ms)を超えたら、打ち消しようがないほど溜めすぎたと判断し、
    /// 直近に届いたこの呼び出し分を新しい基準点として再アンカーする。
    public func pushReference(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.withLock { state in
            if !state.isAnchored {
                beginEpoch(&state)
                state.isAnchored = true
            }
            state.referenceStorage.append(contentsOf: samples)
            let depth = state.referenceStorage.count - state.referenceReadIndex
            if depth > maxReferenceDepthSamples {
                state.reAnchorCount += 1
                beginEpoch(&state)
                state.referenceStorage = samples
                state.isAnchored = true
            }
            compactReference(&state)
        }
    }

    /// マイク音声(モノラル・同レート)にエコーキャンセルを掛けて返す。
    /// 入力長は任意。出力は常に入力と同じ長さを返す。
    ///
    /// アンカー前(pushReference が一度も来ていない)は素通し。何も溜めず、speex にも掛けない
    /// (マイクだけ数秒先に動き出しても、その間ゼロ埋めで自己修復カウンタを消費させないため)。
    ///
    /// アンカー後は近端遅延線を通す: 受け取った近端は直近 200ms 分をまず保持し、
    /// それより前に受け取った分だけをフレーム形成へ回す。これにより実処理の開始が実時間で
    /// 200ms 遅れ、参照側にも同じだけ溜める猶予ができる(結果、出力の中身も200ms遅れるが、
    /// 文字起こし用途では無視できる)。
    ///
    /// フレーム処理のたびに参照ゼロ埋めの累積を確認し、100ms を超えたら「参照が届かなくなった」
    /// と判断して再アンカーする(自己修復)。再アンカー直後の近端はそのまま素通しで返す。
    public func process(_ near: [Float]) -> [Float] {
        guard !near.isEmpty else { return [] }
        return lock.withLock { state in
            guard state.isAnchored else { return near }

            state.nearDelayHold.append(contentsOf: near)
            if state.nearDelayHold.count > nearDelaySamples {
                let releasable = state.nearDelayHold.count - nearDelaySamples
                state.pendingNear.append(contentsOf: state.nearDelayHold.prefix(releasable))
                state.nearDelayHold.removeFirst(releasable)
            }

            while state.pendingNear.count >= frameSize {
                let frame = Array(state.pendingNear.prefix(frameSize))
                state.pendingNear.removeFirst(frameSize)
                state.pendingOutput.append(contentsOf: runFrame(frame, state: &state))

                if state.cumulativeZeroFillSamples > zeroFillReAnchorThresholdSamples {
                    state.reAnchorCount += 1
                    beginEpoch(&state)
                    state.isAnchored = false
                    break
                }
            }

            guard state.isAnchored else { return near }

            let need = near.count
            if state.pendingOutput.count >= need {
                let result = Array(state.pendingOutput.prefix(need))
                state.pendingOutput.removeFirst(need)
                return result
            }
            // primer が nearDelaySamples+frameSize あるため理論上は到達しない保険。
            var result = state.pendingOutput
            result.append(contentsOf: [Float](repeating: 0, count: need - result.count))
            state.pendingOutput.removeAll()
            return result
        }
    }

    /// 状態を完全にリセットする(フィルタ係数・アンカー・持ち越しバッファ・診断カウンタをすべて破棄)。
    public func reset() {
        lock.withLock { state in
            speex_echo_state_reset(speexState)
            if let preprocessState = state.preprocessState {
                speex_preprocess_state_destroy(preprocessState)
            }
            state = State()
            Self.resetScratch(&state, frameSize: frameSize)
        }
    }

    /// runFrame のスクラッチバッファを frameSize 固定長で作り直す。
    /// State() の既定値は空配列なので、init と reset の両方で呼ぶ必要がある。
    private static func resetScratch(_ state: inout State, frameSize: Int) {
        state.scratchRefFrame = [Float](repeating: 0, count: frameSize)
        state.scratchNearInt16 = [Int16](repeating: 0, count: frameSize)
        state.scratchRefInt16 = [Int16](repeating: 0, count: frameSize)
        state.scratchOutInt16 = [Int16](repeating: 0, count: frameSize)
        state.scratchOutputFloat = [Float](repeating: 0, count: frameSize)
    }

    /// 新しいアンカー区間を開始する準備として、遅延線・参照・出力バッファをすべて破棄し、
    /// 出力プライマーを積み直す。preprocess も作り直す(echo state 自体はリセットせず使い回す)。
    /// isAnchored / reAnchorCount は呼び出し側の責任で設定する。
    private func beginEpoch(_ state: inout State) {
        if let oldPreprocessState = state.preprocessState {
            speex_preprocess_state_destroy(oldPreprocessState)
        }
        state.nearDelayHold.removeAll()
        state.pendingNear.removeAll()
        state.referenceStorage.removeAll()
        state.referenceReadIndex = 0
        state.pendingOutput = [Float](repeating: 0, count: outputPrimerSamples)
        state.cumulativeZeroFillSamples = 0
        state.preprocessState = makePreprocessState()
    }

    /// 残渣エコー抑制(後段)の状態を作り、echo state と結合する。frame_size は
    /// echo cancellation と揃える必要がある(speexdsp の要件)。
    ///
    /// AGC はオフにする(文字起こし用途で音量を人工的に均されると認識精度に影響しうるため)。
    /// VAD はデフォルトで既にオフ(speexdsp 側の初期値)。明示的に SET_VAD を呼ぶと
    /// ライブラリ内部から毎回 stderr に警告が出る(speexdsp 側の未整理な実装によるもの)ため、
    /// デフォルトに委ねてあえて呼ばない。denoise・echo suppress 系はデフォルト値のまま使う。
    private func makePreprocessState() -> OpaquePointer? {
        guard let preprocessState = speex_preprocess_state_init(Int32(frameSize), Int32(sampleRate)) else {
            return nil
        }
        _ = speex_preprocess_ctl(preprocessState, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(speexState))
        var agcOff: Int32 = 0
        withUnsafeMutablePointer(to: &agcOff) { ptr in
            _ = speex_preprocess_ctl(preprocessState, SPEEX_PREPROCESS_SET_AGC, ptr)
        }
        return preprocessState
    }

    /// frameSize ぶんの近端フレームを1つ処理する。参照は同数消費し、不足分はゼロで埋める。
    ///
    /// 呼び出し元(process)はフレーム処理をタイトなループで回すため、同サイズの配列を
    /// 毎フレーム確保しない。State に持たせた frameSize 固定長のスクラッチバッファへ
    /// 上書きしながら使い回す(サイズは init/reset 時に確定済み)。
    private func runFrame(_ nearFrame: [Float], state: inout State) -> [Float] {
        for i in 0..<frameSize { state.scratchRefFrame[i] = 0 }
        let available = state.referenceStorage.count - state.referenceReadIndex
        let take = min(available, frameSize)
        if take > 0 {
            let start = state.referenceReadIndex
            state.scratchRefFrame.replaceSubrange(0..<take, with: state.referenceStorage[start..<(start + take)])
            state.referenceReadIndex += take
        }
        state.cumulativeZeroFillSamples += frameSize - take
        compactReference(&state)

        for i in 0..<frameSize {
            state.scratchNearInt16[i] = Self.floatToInt16(nearFrame[i])
            state.scratchRefInt16[i] = Self.floatToInt16(state.scratchRefFrame[i])
        }
        state.scratchNearInt16.withUnsafeBufferPointer { nearPtr in
            state.scratchRefInt16.withUnsafeBufferPointer { refPtr in
                state.scratchOutInt16.withUnsafeMutableBufferPointer { outPtr in
                    speex_echo_cancellation(speexState, nearPtr.baseAddress, refPtr.baseAddress, outPtr.baseAddress)
                }
            }
        }
        // 残渣エコー抑制: echo state と結合済みの preprocess を in-place で掛ける。
        if let preprocessState = state.preprocessState {
            state.scratchOutInt16.withUnsafeMutableBufferPointer { outPtr in
                _ = speex_preprocess_run(preprocessState, outPtr.baseAddress)
            }
        }
        for i in 0..<frameSize {
            state.scratchOutputFloat[i] = Self.int16ToFloat(state.scratchOutInt16[i])
        }
        return state.scratchOutputFloat
    }

    /// 消費済み分が閾値を超えたら前方に詰め直し、配列が際限なく伸びるのを防ぐ。
    private func compactReference(_ state: inout State) {
        guard state.referenceReadIndex > maxReferenceDepthSamples * 2 else { return }
        state.referenceStorage.removeFirst(state.referenceReadIndex)
        state.referenceReadIndex = 0
    }

    private static func floatToInt16(_ sample: Float) -> Int16 {
        let scaled = (sample * 32767).rounded()
        if scaled >= Float(Int16.max) { return Int16.max }
        if scaled <= Float(Int16.min) { return Int16.min }
        return Int16(scaled)
    }

    private static func int16ToFloat(_ sample: Int16) -> Float {
        Float(sample) / 32767.0
    }
}
