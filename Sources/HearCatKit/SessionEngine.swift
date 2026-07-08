@preconcurrency import AVFoundation
import Foundation
import Speech
import os

public enum EngineError: LocalizedError {
    case alreadyActive
    case notActive

    public var errorDescription: String? {
        switch self {
        case .alreadyActive: return "すでにセッションが進行中です"
        case .notActive: return "進行中のセッションがありません"
        }
    }
}

/// item.buffer と同じフォーマット・フレーム長の無音バッファを作る(SilenceGate.Action.silence 用)。
/// 実バッファは録音側にも渡る共有オブジェクトのため書き換えず、都度新しく確保する。
/// 新規確保したメモリの内容は未定義(ゼロ初期化される保証はない)なため、明示的にゼロ埋めする。
private func makeSilentBuffer(matching buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let silent = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return nil }
    silent.frameLength = buffer.frameLength
    let channels = Int(buffer.format.channelCount)
    let frames = Int(silent.frameLength)
    if let data = silent.floatChannelData {
        for c in 0..<channels { memset(data[c], 0, frames * MemoryLayout<Float>.size) }
    } else if let data = silent.int16ChannelData {
        for c in 0..<channels { memset(data[c], 0, frames * MemoryLayout<Int16>.size) }
    }
    return silent
}

/// 録音と文字起こしのセッション全体を束ねるエンジン。アプリが1個だけ保持する。
/// 「録音」と「文字起こし」は独立トグルで、セッション中いつでも切り替えられる。
@MainActor
public final class SessionEngine {
    public struct Status: Codable, Sendable {
        public var active = false
        public var recording = false
        public var transcribing = false
        public var sessionID: String?
        public var sessionDirectory: String?
        public var transcriptPath: String?
        public var startedAt: Date?
        /// システム音声(相手)の取得に失敗した場合の理由。署名なしビルド等で起きる。
        public var systemAudioError: String?

        public init() {}
    }

    /// 無音区間を文字起こしに流さないゲート。
    /// 無音でも音声認識は架空の文を生成することがある(幻覚)ため、音量が閾値を
    /// 下回るバッファは実音声のまま解析へ渡さない。発話の間の短い沈黙でブツ切りに
    /// ならないよう、無音が一定時間続くまでは開いたままにする。pump タスク内でだけ使う
    /// (排他不要)。
    ///
    /// なぜ3状態か: 当初は「開いていれば渡す/閉じていれば何も渡さない」の2状態だったが、
    /// SpeechAnalyzer は発話後の無音そのものを見て文末(発話終了)を検出する。閉じている間
    /// 何も渡さないと認識器に無音が届かず、「認識中」のまま20秒以上確定しない事例が
    /// 実測された。そこで閉じた直後(hangover 以内)はゼロ埋めの無音バッファを送って
    /// 確定を促し、hangover を超えて無音が続く場合だけ本当に何も送らない(省電力)。
    /// これにより hangover 中に実音声(エコーを含む)を送っていた問題も同時に解消する。
    private struct SilenceGate {
        enum Action {
            /// 実バッファをそのまま解析へ渡す。
            case open
            /// 無音だが hangover 以内。ゼロ埋めバッファを渡して文末検出を促す。
            case silence
            /// 無音が hangover を超えた。何も渡さない。
            case skip
        }

        /// これ未満を無音とみなす既定 RMS。システム音声の「何も再生していない」区間(ほぼ0)を
        /// 主な標的にした控えめな値。通常の発話は 0.01 前後なので発話を削ることはない。
        /// マイク側はユーザーが設定した入力感度をしきい値として渡すことがある。
        static let defaultThreshold: Float = 0.001
        /// 無音がこの秒数続いたら閉じる。文中の間(ポーズ)より長く取る。
        ///
        /// 当初は2秒だったが、認識器は音声を数秒分のチャンクで溜めてから処理するため、
        /// 2秒で止めると発話の末尾が未処理のまま残り、次の発話まで確定も暫定も出ない
        /// (実測で一言の確定が40秒以上遅れた)。強制確定(finalize)の要求では未処理の
        /// 音声は救えないことも実測済みで、無音を流し続けて消化させるしかない。
        /// 長めに取ることで、チャンクの消化と自然な文末検出(無音)の両方を成立させる。
        private static let hangover: TimeInterval = 12.0
        /// 開始直後は「最初の音が鳴るまで閉じたまま」にするため、無音継続扱いで始める。
        private var silentSeconds: TimeInterval = .greatestFiniteMagnitude

        mutating func action(for buffer: AVAudioPCMBuffer, level: Float, threshold: Float = Self.defaultThreshold) -> Action {
            if level >= threshold {
                silentSeconds = 0
                return .open
            }
            silentSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            return silentSeconds < Self.hangover ? .silence : .skip
        }
    }

    /// 相手の発言をそのまま復唱したような自分の発言(エコー)を、テキストの一致で弾く。
    /// エコー除去(設定の echoRemoval)の唯一の仕組み。イベント処理の合流点(自分と相手の
    /// 両方のイベントが見える eventTask)でだけ使う(単一タスクが順に消費するため排他不要)。
    ///
    /// なぜ音量ベースのゲートを使わないか: スピーカーからマイクへの回り込みは
    /// RMS ≈0.002、実ユーザーの声はマイク位置で 0.001〜0.004 と同じ帯域にあり、
    /// しきい値をどう選んでも「漏れる」か「声を殺す」のどちらかになる。固定しきい値
    /// (0.006)・EMA学習・システム音量×伝達率の瞬間予測の3方式を順に実装したが、
    /// いずれも実環境で自分の声を殺す側に倒れた(最終形でも実測: 21分のゲームセッションで
    /// 相手114行に対し自分3行、確定も大幅に遅延)。さらに見えないゲートがしきい値を
    /// 動かすと、設定画面のメーターで「声がしきい値を超えている」のに文字起こしされない
    /// という UI と実動作の矛盾も生む。そのため音量側は SilenceGate(ユーザーが設定した
    /// 入力感度そのまま)だけにし、エコーは内容の性質——「直近の相手の発言とほぼ同じ」——で
    /// 最終段のテキスト一致により除去する。
    /// 副作用としてユーザーが相手の言葉をそのまま復唱した場合も弾かれるが、
    /// エコー混入より稀かつ無害なので許容する。
    private struct EchoTextFilter {
        private var recent: [(text: String, at: Date)] = []

        /// エコー疑いと判定する対象の保持時間。エコーの確定が相手の確定より先に届く
        /// ことがあるため、確定文だけでなく volatile(暫定)も記録・保持する。
        private static let retentionWindow: TimeInterval = 12.0
        /// これ未満の短い発話は偶然の一致が起きやすいため判定対象にしない。
        private static let minLength = 4
        /// 最長共通部分文字列が自分のテキスト長に対してこの割合以上ならエコーとみなす。
        private static let substringRatio: Float = 0.6

        /// 相手の発言(確定/暫定どちらも)を記録する。
        mutating func noteOther(_ text: String, at: Date = Date()) {
            let normalized = Self.normalize(text)
            guard !normalized.isEmpty else { return }
            recent.append((normalized, at))
            recent.removeAll { at.timeIntervalSince($0.at) > Self.retentionWindow }
        }

        /// 自分の発言が、直近の相手の発言とほぼ同じ内容(エコー)かどうかを判定する。
        mutating func isEcho(_ text: String, at: Date = Date()) -> Bool {
            recent.removeAll { at.timeIntervalSince($0.at) > Self.retentionWindow }
            let normalized = Self.normalize(text)
            guard normalized.count >= Self.minLength else { return false }
            for other in recent {
                if other.text.contains(normalized) { return true }
                let common = Self.longestCommonSubstringLength(normalized, other.text)
                if Float(common) >= Float(normalized.count) * Self.substringRatio { return true }
            }
            return false
        }

        /// 空白・句読点・記号を除去した正規化テキスト。話者や認識器の違いによる
        /// 句読点の有無・空白の入り方のゆらぎを吸収する。
        private static func normalize(_ text: String) -> String {
            let dropped = CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters)
                .union(.symbols)
            return String(text.unicodeScalars.filter { !dropped.contains($0) })
        }

        /// 最長共通部分文字列(連続する部分文字列)の長さ。短文同士の比較なので
        /// O(n*m) の素朴な DP で十分。
        private static func longestCommonSubstringLength(_ lhs: String, _ rhs: String) -> Int {
            let a = Array(lhs)
            let b = Array(rhs)
            guard !a.isEmpty, !b.isEmpty else { return 0 }
            var previous = [Int](repeating: 0, count: b.count + 1)
            var longest = 0
            for i in 1...a.count {
                var current = [Int](repeating: 0, count: b.count + 1)
                for j in 1...b.count where a[i - 1] == b[j - 1] {
                    current[j] = previous[j - 1] + 1
                    longest = max(longest, current[j])
                }
                previous = current
            }
            return longest
        }
    }

    /// エコー除去のオン/オフと入力感度しきい値。setMicGate でセッション外からも更新でき、
    /// 次のセッションにも引き継がれる(setGains と同じ方針)。pump タスクが都度参照するため
    /// ロックで共有する。
    private final class MicGateSettings: Sendable {
        private struct State {
            var echoRemoval: Bool
            var micThreshold: Float?
        }
        private let lock: OSAllocatedUnfairLock<State>

        init(echoRemoval: Bool, micThreshold: Float?) {
            lock = OSAllocatedUnfairLock(initialState: State(echoRemoval: echoRemoval, micThreshold: micThreshold))
        }

        func update(echoRemoval: Bool, micThreshold: Float?) {
            lock.withLock {
                $0.echoRemoval = echoRemoval
                $0.micThreshold = micThreshold
            }
        }

        func snapshot() -> (echoRemoval: Bool, micThreshold: Float?) {
            lock.withLock { ($0.echoRemoval, $0.micThreshold) }
        }
    }

    /// 音声バッファごとに参照するオンオフ状態。
    /// pump(音声転送タスク)は MainActor の外で回るため、actor 越しでなくロックで読む。
    private final class Toggles: Sendable {
        let recording: OSAllocatedUnfairLock<Bool>
        let transcribing: OSAllocatedUnfairLock<Bool>

        init(recording: Bool, transcribing: Bool) {
            self.recording = OSAllocatedUnfairLock(initialState: recording)
            self.transcribing = OSAllocatedUnfairLock(initialState: transcribing)
        }
    }

    public private(set) var status = Status() {
        didSet { onStatusChange?(status) }
    }

    /// 確定/暫定の文字起こしイベント。UI のライブ表示用。MainActor 上で呼ばれる。
    public var onEvent: ((TranscriberEvent) -> Void)?
    public var onStatusChange: ((Status) -> Void)?
    /// 入力レベル(RMS)の通知。UI のメーター表示用。
    /// pump(音声転送タスク)から MainActor の外で呼ばれるため Sendable であること。
    public var onLevel: (@Sendable (_ speaker: String, _ level: Float) -> Void)?

    private let locale: Locale
    private var toggles: Toggles?
    private var mic: MicSource?
    private var system: SystemAudioSource?
    private var mine: ChannelTranscriber?
    private var theirs: ChannelTranscriber?
    private var recorder: SessionRecorder?
    private var writer: TranscriptWriter?
    private var pumps: [Task<Void, Never>] = []
    private var eventTask: Task<Void, Never>?
    private var eventSink: AsyncStream<TranscriberEvent>.Continuation?
    /// 進行中の teardown。@MainActor 上の async 関数は await のたびに他のタスクへ
    /// 制御を譲る(reentrancy)ため、teardown が資源(mic/system/recorder)を片付けている
    /// 最中に start() が割り込むと同じ資源を同時に触って壊れる。start() の先頭で
    /// このタスクの完了を待つことで割り込みを防ぐ。
    private var teardownTask: Task<Void, Never>?
    /// 録音音量。セッション開始前に設定された値も、開始時に recorder へ引き継ぐ。
    private var micGain: Float = 1
    private var systemGain: Float = 1
    /// マイクのエコー除去設定。セッション開始前に設定された値も次のセッションへ引き継ぐ。
    private let micGateSettings = MicGateSettings(echoRemoval: true, micThreshold: nil)
    /// 使う入力デバイスの UID(nil はシステム標準)。セッション中の切り替えはスコープ外で、
    /// 次にセッションを開始した時に反映される。
    private var micDeviceUID: String?

    public init(locale: Locale = Locale(identifier: "ja-JP")) {
        self.locale = locale
    }

    public func start(record: Bool, transcribe: Bool, name: String = "") async throws {
        // 直前の stop() の teardown がまだ進行中なら完了を待つ。待たずに進むと、
        // teardown が片付けている最中の mic/system/recorder を新しいセッションが
        // 同時に初期化してしまい、状態が壊れる。
        if let teardownTask {
            await teardownTask.value
        }
        guard !status.active else { throw EngineError.alreadyActive }

        // 許可が下りなくても止めない(マイクだけ・システム音声だけでも価値があるため)。
        // 失敗はその経路が無音になる形で現れるので、stderr に手がかりを残す。
        let speechAuth = await Self.requestSpeechAuthorization()
        if speechAuth != .authorized {
            errorLog("音声認識が許可されていません (status: \(speechAuth.rawValue))")
        }
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        if !micGranted {
            errorLog("マイクが許可されていません")
        }

        let startedAt = Date()
        let sessionDir = try SessionStore.createSessionDirectory(startDate: startedAt, name: name)
        do {
            try await startResources(
                sessionDir: sessionDir, startedAt: startedAt,
                record: record, transcribe: transcribe)
        } catch {
            // 途中失敗(マイク初期化エラーなど)で取得済みリソースを残さない。
            // 中身は空の transcript なので、空セッションごと消す。
            await runTeardown()
            try? FileManager.default.removeItem(at: sessionDir)
            throw error
        }
    }

    private func startResources(
        sessionDir: URL, startedAt: Date, record: Bool, transcribe: Bool
    ) async throws {
        // 成果物のファイル名はディレクトリ名(日時)と同じ基底名にする。
        // Finder で1ファイルだけ取り出しても、どのセッションのものか分かるように。
        let transcriptURL = sessionDir.appendingPathComponent(
            "\(sessionDir.lastPathComponent).md")
        let writer = try TranscriptWriter(fileURL: transcriptURL)
        self.writer = writer

        let toggles = Toggles(recording: record, transcribing: transcribe)
        self.toggles = toggles

        let (events, eventSink) = AsyncStream<TranscriberEvent>.makeStream()
        self.eventSink = eventSink

        // 確定文はファイルへ、確定/暫定の両方を UI へ。消費は1本のタスクに直列化して行を守る。
        // 自分と相手の両方のイベントがここで合流するため、EchoTextFilter(テキスト一致による
        // エコー除去)もこの1本のタスク内で完結させる。設定のエコー除去オフは判定側だけ
        // 止める(相手の発言の記録は続け、セッション中にオンへ戻しても即座に効くように)。
        let gateSettings = self.micGateSettings
        eventTask = Task { [weak self] in
            var echoTextFilter = EchoTextFilter()
            for await event in events {
                switch event {
                case .final(let segment) where segment.speaker == "相手":
                    // 記録時刻は「今」を使う(segment.timestamp は発話開始時刻で、確定が
                    // 遅れた長い発話では保持期間の判定上すでに古すぎることがある)。
                    echoTextFilter.noteOther(segment.text)
                    await writer.append(segment)
                    self?.onEvent?(event)
                case .final(let segment):
                    if gateSettings.snapshot().echoRemoval, echoTextFilter.isEcho(segment.text) {
                        debugLog("echoTextFilter: 自分の確定文をエコーとして破棄 text='\(segment.text)'")
                        // 画面の暫定(認識中)行はその話者の確定で消える仕組みのため、
                        // 確定を破棄したら空の暫定を流して行を確実に消す
                        // (流さないと「認識中」が画面に残り続ける)。
                        self?.onEvent?(.volatile(speaker: segment.speaker, text: "", startedAt: segment.timestamp))
                    } else {
                        await writer.append(segment)
                        self?.onEvent?(event)
                    }
                case .volatile(let speaker, let text, _) where speaker == "相手":
                    echoTextFilter.noteOther(text)
                    self?.onEvent?(event)
                case .volatile(let speaker, let text, let startedAt):
                    if gateSettings.snapshot().echoRemoval, echoTextFilter.isEcho(text) {
                        debugLog("echoTextFilter: 自分の暫定文をエコーとして抑制 text='\(text)'")
                        self?.onEvent?(.volatile(speaker: speaker, text: "", startedAt: startedAt))
                    } else {
                        self?.onEvent?(event)
                    }
                }
            }
        }

        var systemAudioError: String?

        // --- 音源と文字起こしの用意 ---
        let mine = ChannelTranscriber(speaker: "自分", locale: locale, sink: eventSink)
        try await mine.start()
        self.mine = mine
        let mic = MicSource(deviceUID: micDeviceUID)
        try mic.start()
        self.mic = mic

        // 相手(システム音声)は署名なしビルドなどで失敗しても、自分のマイクだけで継続する。
        var theirs: ChannelTranscriber?
        var system: SystemAudioSource?
        do {
            let transcriber = ChannelTranscriber(speaker: "相手", locale: locale, sink: eventSink)
            try await transcriber.start()
            let source = SystemAudioSource()
            try source.start()
            theirs = transcriber
            system = source
            self.theirs = transcriber
            self.system = source
        } catch {
            systemAudioError = "システム音声を取得できません: \(error)"
            errorLog(systemAudioError!)
        }

        // --- 録音(1本のモノラルミックス。自分と相手を重ねて書く) ---
        let recorder = SessionRecorder(
            url: sessionDir.appendingPathComponent("\(sessionDir.lastPathComponent).m4a"),
            includesSystemChannel: system != nil)
        await recorder.setGains(mic: micGain, system: systemGain)
        self.recorder = recorder

        // --- pump: 音源 → 文字起こし/録音への分岐 ---
        let onLevel = self.onLevel
        let micBuffers = mic.buffers
        let micGateSettings = self.micGateSettings
        pumps.append(Task.detached(priority: .userInitiated) {
            var gate = SilenceGate()
            for await item in micBuffers {
                let level = rmsLevel(item.buffer)
                onLevel?("自分", level)
                // しきい値はユーザーが設定した入力感度(自動なら既定値)をそのまま使う。
                // エコー除去のためにここでしきい値を動かすことはしない
                // (理由は EchoTextFilter のコメントを参照)。
                let threshold = micGateSettings.snapshot().micThreshold ?? SilenceGate.defaultThreshold
                // ゲートは文字起こしにだけ効かせる。録音は無音も含めて忠実に残す。
                if toggles.transcribing.withLock({ $0 }) {
                    switch gate.action(for: item.buffer, level: level, threshold: threshold) {
                    case .open:
                        await mine.feed(item.buffer)
                    case .silence:
                        // 実音声(エコー含む)でなく無音そのものを送ることで、SpeechAnalyzer に
                        // 文末を検出させて確定を早める(実測: 送らないと「認識中」が
                        // 20秒以上張り付く)。
                        if let silent = makeSilentBuffer(matching: item.buffer) {
                            await mine.feed(silent)
                        }
                    case .skip:
                        break
                    }
                }
                if toggles.recording.withLock({ $0 }) { await recorder.appendMic(item.buffer) }
            }
        })
        if let theirs, let system {
            let systemBuffers = system.buffers
            pumps.append(Task.detached(priority: .userInitiated) {
                var gate = SilenceGate()
                for await item in systemBuffers {
                    let level = rmsLevel(item.buffer)
                    onLevel?("相手", level)
                    if toggles.transcribing.withLock({ $0 }) {
                        switch gate.action(for: item.buffer, level: level) {
                        case .open:
                            await theirs.feed(item.buffer)
                        case .silence:
                            if let silent = makeSilentBuffer(matching: item.buffer) {
                                await theirs.feed(silent)
                            }
                        case .skip:
                            break
                        }
                    }
                    if toggles.recording.withLock({ $0 }) { await recorder.appendSystem(item.buffer) }
                }
            })
        }

        var status = Status()
        status.active = true
        status.recording = record
        status.transcribing = transcribe
        status.sessionID = sessionDir.lastPathComponent
        status.sessionDirectory = sessionDir.path
        status.transcriptPath = transcriptURL.path
        status.startedAt = startedAt
        status.systemAudioError = systemAudioError
        self.status = status
    }

    public func stop() async {
        guard status.active else { return }
        // 音源停止→pump流し切り→SpeechAnalyzerの確定→ファイルクローズという直列処理は
        // 実測1.3秒以上かかり、UI がそれを待つと「停止ボタンを押すとフリーズする」ように
        // 見える。teardown の完了を待たずに状態だけ先に確定させ、即座に UI へ反映する。
        status = Status()
        await runTeardown()
    }

    /// teardown を他の start()/stop() から待ち合わせ可能な形で実行する。
    private func runTeardown() async {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.teardown()
        }
        teardownTask = task
        await task.value
        teardownTask = nil
    }

    private func teardown() async {
        // 1. 音源を止めてバッファストリームを finish させ、pump が末尾まで流し切るのを待つ。
        mic?.stop()
        system?.stop()
        for pump in pumps { _ = await pump.value }
        pumps = []

        // 2. 末尾の発話を確定文としてフラッシュしてから解析を閉じる。
        await mine?.stop()
        await theirs?.stop()

        // 3. イベントの消費(ファイル書き込み)を完了させる。
        eventSink?.finish()
        _ = await eventTask?.value
        eventTask = nil
        eventSink = nil

        await writer?.close()
        await recorder?.close()

        mic = nil
        system = nil
        mine = nil
        theirs = nil
        recorder = nil
        writer = nil
        toggles = nil
    }

    public func setRecording(_ on: Bool) throws {
        guard status.active, let toggles else { throw EngineError.notActive }
        toggles.recording.withLock { $0 = on }
        status.recording = on
        if !on {
            // 中途半端に残ったサンプルを捨て、再開時に左右チャンネルが揃った状態から始める。
            let recorder = self.recorder
            Task { await recorder?.pause() }
        }
    }

    public func setTranscribing(_ on: Bool) throws {
        guard status.active, let toggles else { throw EngineError.notActive }
        toggles.transcribing.withLock { $0 = on }
        status.transcribing = on
    }

    /// 録音音量を変える。セッション中でなくても呼べる(次のセッションに引き継がれる)。
    public func setGains(mic: Float, system: Float) {
        micGain = mic
        systemGain = system
        if let recorder {
            Task { await recorder.setGains(mic: mic, system: system) }
        }
    }

    /// マイクのエコー除去設定を変える。セッション中でなくても呼べる(次のセッションに引き継がれる)。
    /// threshold が nil なら自動(SilenceGate.defaultThreshold)。
    public func setMicGate(echoRemoval: Bool, threshold: Float?) {
        micGateSettings.update(echoRemoval: echoRemoval, micThreshold: threshold)
    }

    /// 使う入力デバイスを変える。セッション中でなくても呼べるが、切り替えの反映は
    /// 次にセッションを開始した時(スコープ外: セッション中のライブ切り替えは非対応)。
    public func setMicDevice(uid: String?) {
        micDeviceUID = uid
    }

    // SFSpeechRecognizer.requestAuthorization の完了ハンドラは TCC が背景スレッドで呼ぶ。
    // MainActor 分離のまま継続を受けるとランタイムが trap するため、nonisolated に切り出す。
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
