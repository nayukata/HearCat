import Foundation
import HearCatKit
import Observation

/// Google アカウントのログイン状態。設定画面が表示し、書き出しが認証の供給元として使う。
@MainActor
@Observable
final class GoogleDriveAccount {
    /// このビルドに資格情報が注入されているか。無ければ連携そのものを無効にする。
    let config: GoogleOAuthConfig?
    private(set) var isSignedIn: Bool
    private(set) var email: String?
    private(set) var isSigningIn = false
    private(set) var message: String?

    @ObservationIgnored private let store: GoogleTokenStore
    @ObservationIgnored private let auth: GoogleAuthSession?
    @ObservationIgnored private let endpoint: GoogleTokenEndpoint?
    @ObservationIgnored private var loginTask: Task<Void, Never>?

    private static let emailKey = "googleDriveAccountEmail"

    var isAvailable: Bool { config != nil }

    init(config: GoogleOAuthConfig? = GoogleOAuthConfig.fromBundle(), store: GoogleTokenStore = GoogleKeychainStore()) {
        self.config = config
        self.store = store
        if let config {
            let endpoint = GoogleURLSessionTokenEndpoint(config: config)
            self.endpoint = endpoint
            auth = GoogleAuthSession(endpoint: endpoint, store: store)
        } else {
            endpoint = nil
            auth = nil
        }
        isSignedIn = config != nil && store.loadRefreshToken() != nil
        email = isSignedIn ? UserDefaults.standard.string(forKey: Self.emailKey) : nil
    }

    /// Drive の呼び出しに使う API。ログインしていない・資格情報が無いときは nil。
    func makeAPI() -> DriveAPI? {
        guard let auth else { return nil }
        return GoogleDriveAPI(tokens: auth)
    }

    func signIn() {
        guard let config, let endpoint, let auth, !isSigningIn else { return }
        isSigningIn = true
        message = nil
        loginTask = Task {
            defer {
                isSigningIn = false
                loginTask = nil
            }
            do {
                let response = try await GoogleLoginFlow(config: config, endpoint: endpoint).run()
                try await auth.adopt(response)
                isSignedIn = true
                email = (try? await GoogleDriveAPI(tokens: auth).accountEmail()).flatMap {
                    $0.isEmpty ? nil : $0
                }
                UserDefaults.standard.set(email, forKey: Self.emailKey)
            } catch is CancellationError {
                // 取りやめ。表示は出さない。
            } catch GoogleOAuthError.cancelled {
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        loginTask?.cancel()
    }

    func signOut() {
        guard let auth else { return }
        isSignedIn = false
        email = nil
        message = nil
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        Task { await auth.signOut() }
    }

    /// 書き出しがログイン切れを検知したときに、表示を実状態へ合わせる。
    func noteSignedOut() {
        guard isSignedIn, store.loadRefreshToken() == nil else { return }
        isSignedIn = false
        email = nil
        message = DriveError.notSignedIn.localizedDescription
    }
}

/// 1 セッションの書き出しの状況。詳細画面が表示する。
enum DriveExportState: Equatable {
    case running(String)
    case finished(DriveExportOutcome)
    case failed(String)
}

/// 書き出しの実行係。同じセッションへの同時実行は 1 本にまとめ、
/// 別のセッション同士は 1 本ずつ順に流す(同じフォルダを同時に作って重複させないため)。
@MainActor
@Observable
final class DriveExportCoordinator {
    private(set) var states: [String: DriveExportState] = [:]

    /// 待ち行列にいる間にセッション ID が変わっても、結果を正しい行に出せるよう ID を持ち運ぶ。
    @MainActor private final class Slot {
        var id: String
        /// 自動で始まった転送か。手動の呼び出しが合流したら手動として扱う。
        var automatic: Bool
        init(_ id: String, automatic: Bool) {
            self.id = id
            self.automatic = automatic
        }
    }

    private struct Entry {
        let task: Task<DriveExportOutcome?, Never>
        let kinds: [DriveContentKind]
        let slot: Slot
    }

    @ObservationIgnored private let makeExporter: () -> DriveExporter?
    /// ID から今のセッションを引く。待っている間に移動・改名されていても、転送を始める時点の場所から読む。
    @ObservationIgnored private let lookup: (String) -> SessionInfo?
    /// 待ち行列にいるものも含めた、書き出しの予定と実行中。
    @ObservationIgnored private var inFlight: [String: Entry] = [:]
    /// 実際に転送を始めたセッション。元のファイルを読んでいる最中なので、改名・削除・移動を止める判断に使う。
    private(set) var runningSessions: [String: SessionInfo] = [:]
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored var onSignedOut: (() -> Void)?
    /// 転送が終わった(成功・失敗とも)。待たせていた改名・移動の実行に使う。
    @ObservationIgnored var onTransferFinished:
        ((_ sessionID: String, _ kinds: [DriveContentKind], _ completed: Bool, _ automatic: Bool) -> Void)?
    /// retarget の履歴(旧 ID → 新 ID)。転送が終わった直後の改名・移動で ID が変わっても、
    /// 合流して待っていた側が今の ID を引けるようにする。
    @ObservationIgnored private var idSuccessors: [String: String] = [:]

    init(
        lookup: @escaping (String) -> SessionInfo? = { _ in nil },
        makeExporter: @escaping () -> DriveExporter?
    ) {
        self.lookup = lookup
        self.makeExporter = makeExporter
    }

    func state(for session: SessionInfo) -> DriveExportState? { states[session.id] }

    /// retarget で ID が変わっていても、今の ID の状態を返す。
    func state(forID id: String) -> DriveExportState? { states[currentID(following: id)] }

    /// retarget で ID が変わっていれば、たどり着いた今の ID を返す。
    func currentID(following id: String) -> String {
        var current = id
        var hops = 0
        while let next = idSuccessors[current], hops < 20 {
            current = next
            hops += 1
        }
        return current
    }

    /// 順番待ちを含めて、書き出しの予定があるか。
    func isActive(_ session: SessionInfo) -> Bool { inFlight[session.id] != nil }

    /// 転送の最中か(動かせない)。順番待ちの間は含めない。
    func isRunning(_ session: SessionInfo) -> Bool { runningSessions[session.id] != nil }

    /// そのグループのセッションが転送の最中か。
    func isRunning(inFolder folder: String) -> Bool {
        runningSessions.values.contains { $0.folder == folder }
    }

    /// 書き出しの予定があるセッションの ID(順番待ちを含む)。
    var activeSessionIDs: Set<String> { Set(inFlight.keys) }

    func dismiss(_ session: SessionInfo) {
        if case .running = states[session.id] { return }
        states[session.id] = nil
    }

    /// 順番待ちの間にセッションの ID が変わったとき、予定と表示の行き先を付け替える。
    func retarget(from old: String, to new: String) {
        if idSuccessors.count > 200 { idSuccessors.removeAll() }
        idSuccessors[old] = new
        // 元の ID へ戻る往復移動で、old → new → old の輪を作らない。
        idSuccessors[new] = nil
        if let entry = inFlight.removeValue(forKey: old) {
            entry.slot.id = new
            inFlight[new] = entry
        }
        if let state = states.removeValue(forKey: old) { states[new] = state }
    }

    /// 書き出す。実行中のセッションならその完了を待ち、先の実行に含まれない中身と
    /// 先の実行で失敗した中身を続けて実行する。返す結果と states は先と後を合わせたもの。
    @discardableResult
    func export(
        session: SessionInfo, kinds: [DriveContentKind], automatic: Bool = false
    ) async -> DriveExportOutcome? {
        if let running = inFlight[session.id] {
            if !automatic { running.slot.automatic = false }
            let originalID = session.id
            let first = await running.task.value
            guard let first else { return nil }
            // 自動で書かれた分も、手動の呼び出しが求めた以上は手動の書き出しとして扱う。
            if !automatic {
                DriveRecordStore.markManual(kinds, in: (lookup(currentID(following: originalID)) ?? session).directory)
            }
            let redo = kinds.filter { !running.kinds.contains($0) || first.failures[$0] != nil }
            if redo.isEmpty { return first }
            // 先の転送の完了直後に改名・移動されて ID が変わっていたら、今のセッションで続ける。
            let newID = currentID(following: originalID)
            let current = newID == originalID ? session : (lookup(newID) ?? session)
            guard let second = await export(session: current, kinds: redo, automatic: automatic) else {
                return first
            }
            let merged = first.merging(second)
            states[current.id] = Self.state(of: merged)
            return merged
        }
        guard let exporter = makeExporter() else {
            states[session.id] = .failed(DriveError.notSignedIn.localizedDescription)
            return nil
        }
        let slot = Slot(session.id, automatic: automatic)
        states[slot.id] = .running("順番を待っています")
        let previous = tail
        let report: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in
                guard let self, case .running = self.states[slot.id] else { return }
                self.states[slot.id] = .running(message)
            }
        }
        let task = Task<DriveExportOutcome?, Never> { [weak self] in
            await previous?.value
            guard let self else { return nil }
            let target = self.lookup(slot.id) ?? session
            self.runningSessions[slot.id] = target
            do {
                let outcome = try await exporter.export(
                    session: target, kinds: kinds, automatic: automatic, onProgress: report)
                self.finish(slot, outcome: outcome)
                return outcome
            } catch {
                self.fail(slot, error: error)
                return nil
            }
        }
        inFlight[slot.id] = Entry(task: task, kinds: kinds, slot: slot)
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// 記録にあるファイルを Drive のごみ箱へ移し、記録を消す。順番は書き出しの待ち行列に並ぶ。
    /// 失敗したときは理由を返す。
    func removeRecorded(session: SessionInfo, kinds: [DriveContentKind]? = nil) async -> String? {
        guard let exporter = makeExporter() else { return DriveError.notSignedIn.localizedDescription }
        let previous = tail
        let task = Task<String?, Never> {
            await previous?.value
            do {
                try await exporter.trashRecorded(session: session, kinds: kinds)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private static func state(of outcome: DriveExportOutcome) -> DriveExportState {
        outcome.failureMessage.map(DriveExportState.failed) ?? .finished(outcome)
    }

    private func finish(_ slot: Slot, outcome: DriveExportOutcome) {
        let kinds = inFlight[slot.id]?.kinds ?? []
        inFlight[slot.id] = nil
        runningSessions[slot.id] = nil
        states[slot.id] = Self.state(of: outcome)
        onTransferFinished?(slot.id, kinds, true, slot.automatic)
    }

    private func fail(_ slot: Slot, error: Error) {
        let kinds = inFlight[slot.id]?.kinds ?? []
        inFlight[slot.id] = nil
        runningSessions[slot.id] = nil
        if let drive = error as? DriveError, drive == .notSignedIn { onSignedOut?() }
        states[slot.id] = .failed(error is CancellationError ? "書き出しを中断しました" : error.localizedDescription)
        onTransferFinished?(slot.id, kinds, false, slot.automatic)
    }
}
