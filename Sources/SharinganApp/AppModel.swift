import AppKit
import Foundation
import Observation
import SharinganKit

/// アプリ全体の状態。エンジンと IPC サーバーを1個ずつ持つ。
/// CLI(agent skill)からの命令も、メニューバーからの操作も、必ずここを経由する
/// (操作経路が2系統あっても状態が食い違わないようにするため)。
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let engine = SessionEngine()
    private var ipcServer: IPCServer?

    private(set) var status = SessionEngine.Status()
    private(set) var sessions: [SessionInfo] = []
    var lastError: String?

    /// 履歴ウィンドウの実体。「履歴を開く」で確実に前面へ出すために保持する
    /// (SwiftUI の openWindow は既に開いているウィンドウには何もしないため)。
    @ObservationIgnored weak var mainWindow: NSWindow?

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
        refreshSessions()
        startIPCServer()
    }

    // MARK: - セッション操作

    func startSession(record: Bool = true, transcribe: Bool = true) async {
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
        await engine.stop()
        liveVolatile = [:]
        refreshSessions()
    }

    func setRecording(_ on: Bool) {
        try? engine.setRecording(on)
    }

    func setTranscribing(_ on: Bool) {
        try? engine.setTranscribing(on)
        if !on { liveVolatile = [:] }
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
