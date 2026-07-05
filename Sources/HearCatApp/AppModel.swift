import AppKit
import Foundation
import Observation
import HearCatKit

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
    var lastError: String?
    /// 開始/停止処理の実行中。パネルのボタン連打で二重開始しないよう UI を無効化する。
    private(set) var busy = false

    /// 入力レベル(RMS)。メニューバーのパネルにメーターとして出す。
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0

    /// 各ウィンドウの実体。確実に前面へ出すために保持する
    /// (SwiftUI の openWindow は既に開いているウィンドウには何もしないため)。
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored weak var settingsWindow: NSWindow?
    /// メニューバーのパネル。ウィンドウを開く前に明示的に閉じるために保持する。
    @ObservationIgnored weak var panelWindow: NSWindow?
    /// openWindow は SwiftUI の Environment からしか取れないため、
    /// 常に生きているメニューバーのラベルビューから注入してもらう。
    @ObservationIgnored var openWindowAction: ((String) -> Void)?

    /// ライブ表示用。確定した発話と、話者ごとの喋りかけ(暫定)テキスト。
    private(set) var liveFinals: [TranscriptSegment] = []
    private(set) var liveVolatile: [String: String] = [:]

    private init() {
        engine.onStatusChange = { [weak self] status in
            self?.status = status
        }
        engine.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .volatile(let speaker, let text):
                liveVolatile[speaker] = text
            case .final(let segment):
                liveFinals.append(segment)
                liveVolatile[segment.speaker] = nil
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
        settings.hotkeysChanged = { [weak self] in
            guard let self else { return }
            HotkeyCenter.shared.apply(settings.hotkeys)
        }
        HotkeyCenter.shared.onAction = { [weak self] action in
            self?.handleHotkey(action)
        }
        HotkeyCenter.shared.apply(settings.hotkeys)
        SessionStore.migrateLegacyStorage()
        refreshSessions()
        startIPCServer()
    }

    // MARK: - セッション操作

    func startSession(record: Bool = true, transcribe: Bool = true) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        // 過去の無関係なエラーを引きずって「開始失敗」と誤報告しないようにする。
        lastError = nil
        do {
            liveFinals = []
            liveVolatile = [:]
            try await engine.start(record: record, transcribe: transcribe)
            refreshSessions()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopSession() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await engine.stop()
        liveVolatile = [:]
        micLevel = 0
        systemLevel = 0
        refreshSessions()
    }

    func setRecording(_ on: Bool) {
        try? engine.setRecording(on)
    }

    func setTranscribing(_ on: Bool) {
        try? engine.setTranscribing(on)
        if !on { liveVolatile = [:] }
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
        case .toggleRecording:
            guard status.active else { return }
            setRecording(!status.recording)
        case .toggleTranscribing:
            guard status.active else { return }
            setTranscribing(!status.transcribing)
        case .openHistory:
            showHistory()
        }
    }

    // MARK: - ウィンドウ表示

    func showHistory() {
        dismissPanel()
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
    }

    func delete(_ session: SessionInfo) {
        do {
            try SessionStore.delete(session)
        } catch {
            lastError = error.localizedDescription
        }
        refreshSessions()
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
                    if !transcribe { liveVolatile = [:] }
                }
                return IPCResponse(ok: true, status: status)
            } catch {
                return IPCResponse(ok: false, error: error.localizedDescription)
            }
        }
    }

    /// 終了前の後始末。進行中ならセッションを保存し、ソケットファイルを消す。
    func shutdown() async {
        if status.active {
            await stopSession()
        }
        ipcServer?.stop()
        ipcServer = nil
    }
}
