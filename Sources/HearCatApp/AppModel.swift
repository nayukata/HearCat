import AppKit
import Foundation
import Observation
import HearCatKit
import HearCatSummarize

/// アプリ全体の状態。エンジンと IPC サーバーを1個ずつ持つ。
/// CLI(agent skill)からの命令も、メニューバーからの操作も、必ずここを経由する
/// (操作経路が2系統あっても状態が食い違わないようにするため)。
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let engine = SessionEngine()
    let settings = AppSettings.shared
    private var ipcServer: IPCServer?

    private(set) var status = SessionEngine.Status()
    private(set) var sessions: [SessionInfo] = []
    /// プロジェクトフォルダの一覧(空のフォルダも含む)。履歴のセクション表示に使う。
    private(set) var folders: [String] = []
    var lastError: String?
    /// 開始/停止処理の実行中。パネルのボタン連打で二重開始しないよう UI を無効化する。
    private(set) var busy = false

    /// 入力レベル(RMS)。メニューバーのパネルにメーターとして出す。
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0

    /// 設定画面のレベルメーター用に、セッション外でもマイクを一時的に拾う「プローブ」。
    /// セッション中は engine.onLevel が既に micLevel を更新しているため、プローブとして
    /// 同じマイクを二重にキャプチャしない(掴んだままのデバイスは初期化に失敗し得る)。
    @ObservationIgnored private var micProbe: MicSource?
    @ObservationIgnored private var micProbeTask: Task<Void, Never>?
    /// 設定画面のメーターが今表示されているか。updateMicProbe の判定に使う
    /// (プローブを動かすべきかは「表示中 && セッション非アクティブ」で決まる)。
    @ObservationIgnored private var micMeterVisible = false

    /// メニューバーに出す現在のフレーム。セッション中は Timer で回して動かす
    /// (MenuBarExtra のラベルは SwiftUI アニメーションが効かないため、フレーム切替方式)。
    private(set) var menuIcon = HCIcon.menuIdle[0]
    @ObservationIgnored private var menuIconTimer: Timer?
    @ObservationIgnored private var menuIconFrame = 0

    /// 各ウィンドウの実体。確実に前面へ出すために保持する
    /// (SwiftUI の openWindow は既に開いているウィンドウには何もしないため)。
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored weak var settingsWindow: NSWindow?
    /// メニューバーのパネル。ウィンドウを開く前に明示的に閉じるために保持する。
    @ObservationIgnored weak var panelWindow: NSWindow?
    /// openWindow は SwiftUI の Environment からしか取れないため、
    /// 常に生きているメニューバーのラベルビューから注入してもらう。
    @ObservationIgnored var openWindowAction: ((String) -> Void)?

    /// ライブ表示用。liveTimeline は画面の並び(行の席は固定)、liveFinals は
    /// 確定分の時系列(コピー用。ファイルと同じ発話開始時刻順)。
    private(set) var liveFinals: [TranscriptSegment] = []
    private(set) var liveTimeline = LiveTimeline()

    /// MainWindow へ「この選択にしてほしい」と伝えるための一方向リクエスト。
    /// MainWindow が受け取ったら nil に戻す(ウィンドウを開き直しても再送されないように)。
    var mainWindowSelectionRequest: String?
    /// 直前に終了したセッションの ID。停止直後、ライブ画面からその詳細へ
    /// 自然に遷移させるために MainWindow が参照する。
    private(set) var lastEndedSessionID: String?
    /// refreshSessions が呼ばれるたびに増える版数。停止直後は最終行の書き込みが
    /// 完了直前まで遅れるため、SessionDetailView が読み直すきっかけに使う。
    private(set) var sessionsVersion = 0

    private init() {
        engine.onStatusChange = { [weak self] status in
            self?.status = status
            self?.updateMenuIcon()
            // セッションが終わってメーターの表示フラグがまだ立っていれば、プローブを再開する
            // (セッション開始時に止めた分、終了時にここで元へ戻す)。
            self?.updateMicProbe()
        }
        engine.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .volatile(let speaker, let text, let startedAt):
                liveTimeline.setVolatile(speaker: speaker, text: text, startedAt: startedAt)
            case .final(let segment):
                insertLiveFinal(segment)
                liveTimeline.finalize(segment)
            }
        }
        engine.onLevel = { [weak self] speaker, level in
            Task { @MainActor in
                guard let self else { return }
                if speaker == "自分" {
                    self.micLevel = level
                } else {
                    self.systemLevel = level
                }
            }
        }
        engine.setGains(mic: Float(settings.micGain), system: Float(settings.systemGain))
        settings.gainsChanged = { [weak self] in
            guard let self else { return }
            engine.setGains(mic: Float(settings.micGain), system: Float(settings.systemGain))
        }
        applyMicGate()
        settings.micGateChanged = { [weak self] in
            self?.applyMicGate()
        }
        applyMicDevice()
        settings.micDeviceChanged = { [weak self] in
            self?.applyMicDevice()
        }
        settings.hotkeysChanged = { [weak self] in
            guard let self else { return }
            HotkeyCenter.shared.apply(settings.hotkeys)
        }
        HotkeyCenter.shared.onAction = { [weak self] action in
            self?.handleHotkey(action)
        }
        HotkeyCenter.shared.apply(settings.hotkeys)
        refreshSessions()
        startIPCServer()
        // アプリ更新で新しくなった SKILL.md / CLI を、導入済みなら起動時に反映する。
        SkillInstaller.refreshIfInstalled()
    }

    /// エコー除去/入力感度の設定をエンジンへ反映する。自動時は threshold を nil にして
    /// エンジン側の既定値(SilenceGate.defaultThreshold)に委ねる。
    private func applyMicGate() {
        let threshold = settings.micSensitivityAuto ? nil : Float(settings.micSensitivity)
        engine.setMicGate(echoRemoval: settings.echoRemoval, threshold: threshold)
    }

    /// 入力デバイスの設定をエンジンへ反映する。次にセッションを開始した時から有効になる。
    private func applyMicDevice() {
        engine.setMicDevice(uid: settings.micDeviceUID)
        // プローブが動いていればデバイス変更を即反映したいので、選び直したデバイスで作り直す。
        updateMicProbe()
    }

    // MARK: - マイクプローブ(設定画面のレベルメーター用)

    /// 設定画面のメーターが表示されているかを伝える唯一の入口。SettingsView は
    /// startMicProbe/stopMicProbe を直接呼ばず、必ずこちらを経由する。
    func setMicMeterVisible(_ visible: Bool) {
        micMeterVisible = visible
        updateMicProbe()
    }

    /// プローブが動くべきか(「メーター表示中」かつ「セッション非アクティブ」)を
    /// 一箇所で判定する。表示フラグの変化・セッション状態の変化・デバイス変更の
    /// すべてがここを経由するため、開始/終了/デバイス切り替えの分岐がここに集約される。
    private func updateMicProbe() {
        stopMicProbe()
        guard micMeterVisible, !status.active else { return }
        startMicProbe()
    }

    /// セッション中は何もしない(engine.onLevel が動いている上に、マイクを
    /// 二重に掴むと失敗するデバイスがあるため)。呼び出しは updateMicProbe に集約する。
    private func startMicProbe() {
        guard !status.active else { return }
        let probe = MicSource(deviceUID: settings.micDeviceUID)
        do {
            try probe.start()
        } catch {
            // プローブはメーター表示の補助でしかないため、失敗してもエラー表示はしない。
            return
        }
        micProbe = probe
        let buffers = probe.buffers
        micProbeTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await item in buffers {
                let level = rmsLevel(item.buffer)
                await MainActor.run {
                    self?.micLevel = level
                }
            }
        }
    }

    private func stopMicProbe() {
        micProbeTask?.cancel()
        micProbeTask = nil
        micProbe?.stop()
        micProbe = nil
        micLevel = 0
    }

    // MARK: - セッション操作

    func startSession(record: Bool = true, transcribe: Bool = true) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        // 過去の無関係なエラーを引きずって「開始失敗」と誤報告しないようにする。
        lastError = nil
        // プローブ稼働中(設定画面のメーターが動いている)にセッションを始めると、
        // 同じマイクを二重に掴んでしまうため、セッション側を優先してプローブを止める。
        stopMicProbe()
        do {
            liveFinals = []
            liveTimeline.removeAll()
            // カレンダーの今の予定名をセッション名にする(設定でオフにできる)。
            let name = settings.calendarNaming ? await CalendarNamer.currentEventTitle() ?? "" : ""
            try await engine.start(record: record, transcribe: transcribe, name: name)
            refreshSessions()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopSession() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        // 停止完了後は status.sessionID が消えるため、遷移先として使えるよう先に控える。
        lastEndedSessionID = status.sessionID
        await engine.stop()
        liveTimeline.clearVolatiles()
        micLevel = 0
        systemLevel = 0
        refreshSessions()
        if let lastEndedSessionID {
            autoSummarize(sessionID: lastEndedSessionID)
        }
    }

    // MARK: - 要約

    /// いま要約を生成中のセッション ID(自動・手動共通)。詳細画面の
    /// ボタン表示と二重実行の防止に使う。
    private(set) var summarizingSessionID: String?

    /// 要約を生成して summary.md に保存し、履歴を読み直す。
    /// 停止直後の自動生成と詳細画面のボタンの共通経路。
    func generateSummary(for session: SessionInfo, transcript: String) async throws -> String {
        summarizingSessionID = session.id
        defer { summarizingSessionID = nil }
        let result = try await TranscriptSummarizer.summarize(transcript: transcript)
        let url = session.directory.appendingPathComponent("summary.md")
        try result.write(to: url, atomically: true, encoding: .utf8)
        refreshSessions()
        return result
    }

    /// 停止直後の自動要約。失敗しても何も出さない(履歴の手動ボタンで
    /// いつでも作り直せるため)。要約済みのセッションには手を出さない。
    private func autoSummarize(sessionID: String) {
        Task {
            // 最後の発話の確定は、停止よりファイル書き込みがわずかに遅れることがある。
            try? await Task.sleep(for: .seconds(2))
            guard summarizingSessionID == nil,
                OnDeviceModel.unavailableReason() == nil,
                let session = SessionStore.list().first(where: { $0.id == sessionID }),
                session.summaryURL == nil,
                let url = session.transcriptURL,
                let transcript = try? String(contentsOf: url, encoding: .utf8),
                !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            _ = try? await generateSummary(for: session, transcript: transcript)
        }
    }

    func setRecording(_ on: Bool) {
        try? engine.setRecording(on)
    }

    func setTranscribing(_ on: Bool) {
        try? engine.setTranscribing(on)
        if !on { liveTimeline.clearVolatiles() }
    }

    /// 確定はチャンネルごとに遅延が違い、発話順と届く順が入れ替わることがある。
    /// liveFinals はコピー用なので、ファイルと同じタイムスタンプ(発話開始時刻)順を保つ。
    /// 画面の並びは liveTimeline が持ち、こちらは席を固定する(LiveTimeline のコメント参照)。
    private func insertLiveFinal(_ segment: TranscriptSegment) {
        if let last = liveFinals.last, last.timestamp > segment.timestamp {
            let index = liveFinals.lastIndex(where: { $0.timestamp <= segment.timestamp }).map { $0 + 1 } ?? 0
            liveFinals.insert(segment, at: index)
        } else {
            liveFinals.append(segment)
        }
    }

    // MARK: - メニューバーアイコン

    /// 状態に合ったフレーム一式へ切り替える。複数フレームある(=セッション中)なら
    /// Timer で回してアニメーションさせ、待機中は止めて静止画にする。
    private func updateMenuIcon() {
        let frames: [NSImage] =
            switch (status.active, status.recording, status.transcribing) {
            case (false, _, _): HCIcon.menuIdle
            case (true, true, true): HCIcon.menuRecordingAndTranscribing
            case (true, true, false): HCIcon.menuRecording
            case (true, false, true): HCIcon.menuTranscribing
            case (true, false, false): HCIcon.menuActive
            }
        menuIconTimer?.invalidate()
        menuIconTimer = nil
        menuIconFrame = 0
        menuIcon = frames[0]
        guard frames.count > 1 else { return }
        menuIconTimer = Timer.scheduledTimer(
            withTimeInterval: HCIcon.frameInterval, repeats: true
        ) { [weak self] _ in
            // Timer はメインの RunLoop に載せているため、メインスレッド上で発火する。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuIconFrame = (self.menuIconFrame + 1) % frames.count
                self.menuIcon = frames[self.menuIconFrame]
            }
        }
    }

    // MARK: - ホットキー

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .toggleSession:
            Task {
                if status.active {
                    await stopSession()
                } else {
                    await startSession()
                }
            }
        // 録音/文字起こしのキーはセッション外では「その機能だけオンで開始」。
        // 押して何も起きないデッドゾーンを作らない。
        case .toggleRecording:
            if status.active {
                setRecording(!status.recording)
            } else {
                Task { await startSession(record: true, transcribe: false) }
            }
        case .toggleTranscribing:
            if status.active {
                setTranscribing(!status.transcribing)
            } else {
                Task { await startSession(record: false, transcribe: true) }
            }
        case .openHistory:
            showHistory()
        case .openSettings:
            showSettings()
        }
    }

    // MARK: - ウィンドウ表示

    func showHistory() {
        dismissPanel()
        // セッション中に開く場合は、既に開いたことのあるウィンドウでも必ずライブへ
        // 戻す(前回選んでいたセッションのまま止まってしまわないように)。
        if status.active {
            mainWindowSelectionRequest = MainWindow.liveID
        }
        openWindowAction?("main")
        bringToFrontLater { AppModel.shared.mainWindow }
    }

    func showSettings() {
        dismissPanel()
        openWindowAction?("settings")
        bringToFrontLater { AppModel.shared.settingsWindow }
    }

    /// パネルを開いたまま別ウィンドウを開くと、後からパネルが閉じる際の
    /// 「直前アプリの再アクティブ化」が前面化の後に走って負けてしまう。
    /// 先にパネルを閉じて、再アクティブ化を前面化より前に済ませる。
    private func dismissPanel() {
        panelWindow?.close()
    }

    /// LSUIElement アプリのため、ウィンドウを出すだけでは前面に来ないことがある。
    /// さらにパネルやメニューが閉じる際に macOS が直前のアプリを再アクティブ化するため、
    /// その処理が終わった後に前面化しないと一瞬だけ前面に出て背面に戻される。
    /// 再アクティブ化のタイミングは一定でないため、2回撃って確実に勝つ。
    private func bringToFrontLater(_ window: @escaping @MainActor () -> NSWindow?) {
        for delay in [0.15, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.activate()
                if let window = window() {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    // orderFrontRegardless はアプリのアクティブ化に失敗しても最前面に出せる。
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }

    // MARK: - 履歴

    func refreshSessions() {
        sessions = SessionStore.list()
        folders = SessionStore.listFolders()
        sessionsVersion += 1
    }

    func delete(_ session: SessionInfo) {
        do {
            try SessionStore.delete(session)
        } catch {
            lastError = error.localizedDescription
        }
        refreshSessions()
    }

    /// セッション名を変更し、変更後の ID を返す(履歴の選択の維持に使う)。失敗時は nil。
    func rename(_ session: SessionInfo, to name: String) -> String? {
        mutateSession(session) { try SessionStore.rename($0, to: name) }
    }

    /// セッションをプロジェクトフォルダへ移動し、移動後の ID を返す。nil で未分類へ戻す。
    func move(_ session: SessionInfo, toFolder folder: String?) -> String? {
        mutateSession(session) { try SessionStore.move($0, toFolder: folder) }
    }

    /// 空のプロジェクトフォルダを作る。
    func createFolder(_ name: String) {
        defer { refreshSessions() }
        do {
            try SessionStore.createFolder(name)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// フォルダ名を変更し、新しい名前を返す。失敗時は nil。
    func renameFolder(_ folder: String, to newName: String) -> String? {
        defer { refreshSessions() }
        do {
            return try SessionStore.renameFolder(folder, to: newName)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// フォルダを削除する(中のセッションは未分類へ戻る)。
    @discardableResult
    func deleteFolder(_ folder: String) -> Bool {
        defer { refreshSessions() }
        do {
            try SessionStore.deleteFolder(folder)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func mutateSession(
        _ session: SessionInfo, _ operation: (SessionInfo) throws -> SessionInfo
    ) -> String? {
        // 進行中のセッションはファイルを開いたまま書いているため動かせない。
        guard session.directory.lastPathComponent != status.sessionID else {
            lastError = "進行中のセッションは変更できません"
            return nil
        }
        defer { refreshSessions() }
        do {
            return try operation(session).id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - IPC (CLI / agent skill からの命令)

    private func startIPCServer() {
        let server = IPCServer(socketPath: SessionStore.socketPath) { [weak self] request in
            guard let self else { return IPCResponse(ok: false, error: "アプリが終了処理中です") }
            return await self.handleIPC(request)
        }
        do {
            try server.start()
            ipcServer = server
        } catch {
            lastError = "IPC サーバーを開始できません: \(error.localizedDescription)"
        }
    }

    private func handleIPC(_ request: IPCRequest) async -> IPCResponse {
        switch request.command {
        case .status:
            return IPCResponse(ok: true, status: status)

        case .start:
            guard !status.active else {
                return IPCResponse(ok: false, error: EngineError.alreadyActive.localizedDescription)
            }
            await startSession(record: request.record ?? true, transcribe: request.transcribe ?? true)
            if let lastError {
                self.lastError = nil
                return IPCResponse(ok: false, error: lastError)
            }
            return IPCResponse(ok: true, status: status)

        case .stop:
            guard status.active else {
                return IPCResponse(ok: false, error: EngineError.notActive.localizedDescription)
            }
            let transcriptPath = status.transcriptPath
            await stopSession()
            return IPCResponse(ok: true, status: status, latestTranscript: transcriptPath)

        case .latest:
            let path = status.transcriptPath ?? SessionStore.latest()?.transcriptURL?.path
            guard let path else {
                return IPCResponse(ok: false, error: "文字起こしファイルがまだありません")
            }
            return IPCResponse(ok: true, latestTranscript: path)

        case .set:
            do {
                if let record = request.record { try engine.setRecording(record) }
                if let transcribe = request.transcribe {
                    try engine.setTranscribing(transcribe)
                    if !transcribe { liveTimeline.clearVolatiles() }
                }
                if let autostart = request.autostart { try LoginItem.setEnabled(autostart) }
                return IPCResponse(ok: true, status: status)
            } catch {
                return IPCResponse(ok: false, error: error.localizedDescription)
            }
        }
    }

    /// 終了前の後始末。進行中ならセッションを保存し、ソケットファイルを消す。
    func shutdown() async {
        stopMicProbe()
        if status.active {
            await stopSession()
        }
        ipcServer?.stop()
        ipcServer = nil
    }
}
