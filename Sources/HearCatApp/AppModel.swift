import AppKit
import Foundation
import Observation
import HearCatKit
import HearCatSummarize
import UniformTypeIdentifiers

enum CodeImpactAnalysisState {
    case idle
    case requiresConsent(AgentCLI)
    case analyzing(AgentCLI)
    case completed(AgentCLI)
    case failed(String)
}

/// 「関連資料との照合」オーバーレイの Q&A 1 往復分。同じ会議のあいだの履歴として積み上げる
/// (codeImpactTurns 参照)。question が nil なのは、質問なしのダイジェスト調査。
struct CodeImpactTurn: Identifiable {
    let id = UUID()
    let question: String?
    let result: String
}

/// セッション開始時にどのグループへ入れるかの指示。
/// - auto: カレンダーの予定名と履歴から推測し、推測できなければ未分類にする。
/// - explicit: 呼び出し側(ホットキーのグループ選択画面など)が確定した値。nil は未分類。
enum SessionFolder: Sendable {
    case auto
    case explicit(String?)
}

/// 自動要約の前提が揃っていない場合の理由。手動実行では起きない
/// (ボタン側が使えないエンジンを出さない)ため、自動経路のためだけに持つ。
private enum AutoSummaryError: LocalizedError {
    case onDeviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .onDeviceUnavailable(let reason):
            return "Apple Intelligence が使えません(\(reason))"
        }
    }
}

/// 録音・文字起こしの異常の種類。同じ種類の異常が続けて起きても、パネルには
/// 常に最新の1件だけを出す(古い理由文言のまま積み上がらないようにするため)。
enum HealthIssueKind: Hashable {
    case micPermissionDenied
    case speechPermissionDenied
    case systemAudioUnavailable
    /// 相手のチャンネルだけが長く無音のまま。取得自体は動いているが中身が来ていない状態。
    case systemAudioSilent
    case recordingWriteFailed
    case recordingConversionFailed

    /// いまも続いている不調か。続いているものは、読んだだけで画面から消せないようにする。
    /// 消せてしまうと、自分の声が1文字も残らないまま見た目だけ正常に戻り、
    /// あとで気づいても録り直せない(消す代わりに、畳んで小さくできる)。
    var isOngoing: Bool {
        switch self {
        case .micPermissionDenied, .speechPermissionDenied, .systemAudioUnavailable,
            .systemAudioSilent, .recordingWriteFailed:
            return true
        // 録音ファイルの仕上げ失敗は、起きた時点で終わっている出来事。元の録音データは
        // 残っていて、以後の記録にも影響しないため、読んだら消してよい。
        case .recordingConversionFailed:
            return false
        }
    }
}

/// メニューバーのパネルに出す異常1件分。
struct HealthIssue: Identifiable, Equatable {
    let kind: HealthIssueKind
    let title: String
    let detail: String
    /// 対処として開くべきシステム設定のペイン名。nil なら対処ボタンを出さない
    /// (権限拒否以外は設定を開いても直せないため)。
    let settingsPane: String?

    var id: HealthIssueKind { kind }
    var isOngoing: Bool { kind.isOngoing }
}

private enum CodeImpactContextError: LocalizedError {
    case inactive
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .inactive:
            return "文字起こし中のセッションで使えます"
        case .sessionNotFound:
            return "進行中のセッションを読み込めませんでした"
        }
    }
}

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
    /// 現在進行中のセッションで起きている異常。複数同時にあり得るため配列で持つ。
    /// 新しいセッションを始めたらクリアする(前のセッションの異常を持ち越さない)。
    private(set) var healthIssues: [HealthIssue] = []
    /// 畳んで1行にしている異常。パネルはメニューを開くたびに作り直されるため、
    /// 畳んだかどうかはビューではなくここで覚える。
    private(set) var collapsedHealthIssues: Set<HealthIssueKind> = []
    private(set) var sessions: [SessionInfo] = []
    /// プロジェクトフォルダの一覧(空のフォルダも含む)。履歴のセクション表示に使う。
    private(set) var folders: [String] = []
    var lastError: String?
    /// 開始/停止処理の実行中。パネルのボタン連打で二重開始しないよう UI を無効化する。
    private(set) var busy = false

    /// 進行中の会議と関連コードを照合した結果。専用オーバーレイだけが表示する。
    private(set) var codeImpactAnalysisState: CodeImpactAnalysisState = .idle
    /// いま調査対象になっている質問。ホットキー・メニューからの初回調査(質問なし)なら nil、
    /// 入力欄に質問を入れて送った場合はその文字列。requiresCodeImpactAnalysis /
    /// requestFollowUpCodeImpact の開始時に更新し、以後 confirm・retry・resume の
    /// あいだはここを読むだけにする(state の enum に持たせると同じ組み立てが
    /// 呼び出し側ごとに重複するため、1 箇所に集約している)。
    private(set) var codeImpactQuestion: String?
    /// 同じ会議のあいだの Q&A 履歴。追加質問で前のやり取りが画面から消えないよう、完了した調査を積んでいく。
    private(set) var codeImpactTurns: [CodeImpactTurn] = []
    @ObservationIgnored private var codeImpactTask: Task<Void, Never>?
    @ObservationIgnored private var codeImpactRequestID: UUID?
    @ObservationIgnored private var codeImpactOverlayController: CodeImpactOverlayController?
    /// claude の会話セッション ID(--resume で継続する)。同じ会議のあいだだけ持ち回す。
    @ObservationIgnored private var codeImpactSessionID: String?
    /// codeImpactSessionID がどのセッションディレクトリのものかの記録。
    /// 会議が変わった(= セッションディレクトリが変わった)ら両方リセットする。
    @ObservationIgnored private var codeImpactSessionDirectory: String?
    /// 結果内のファイルパスをクリックで開くために、いま表示中の調査が使った資料フォルダを覚えておく。
    private(set) var codeImpactActiveReferenceFolder: String?
    /// 未分類のまま録音中のセッションは資料フォルダに紐付くグループへ動かせないため、
    /// この会議のあいだだけメモリ上で資料フォルダを覚える一時的な紐付け。
    /// アプリ再起動や別セッションでは引き継がない(sessionDirectory が変われば無効)。
    @ObservationIgnored private var codeImpactReferenceFolderOverride: (sessionDirectory: String, path: String)?
    /// ストリーミングで届いた assistant テキストの断片を蓄積したもの。
    /// completed になったら使わなくなり、次の analyzing 開始時にクリアする。
    private(set) var codeImpactPartialText: String = ""
    /// ストリーミング中の進捗行(例: "Read: AppModel.swift")。オーバーレイの上端に出す。
    private(set) var codeImpactActivity: String?
    /// 結果セクション(見出しタイトル)ごとの開閉のユーザー操作。ストリーミング表示と完了表示で
    /// ビューの実体が変わっても開閉が引き継がれるよう、ビューの @State ではなくここに持つ。
    /// 新しい調査の開始時にクリアする。
    var codeImpactSectionOverrides: [String: Bool] = [:]

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
    /// 注入より前に来た履歴ウィンドウの表示要求は、注入された時点で改めて実行する。
    @ObservationIgnored var openWindowAction: ((String) -> Void)? {
        didSet {
            guard needsHistoryWindow, openWindowAction != nil else { return }
            needsHistoryWindow = false
            showHistory()
        }
    }

    /// 履歴ウィンドウを開こうとしたが、openWindowAction がまだ注入されていなかった。
    /// Finder で .hearcat を開いてアプリ自体がそこで起動した場合、
    /// application(_:open:) はメニューバーのラベルビューが現れるより先に走る。
    /// ここで覚えておかないと、取り込みの確認画面が出ないまま終わってしまう。
    @ObservationIgnored private var needsHistoryWindow = false

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

    /// 直前に終わったセッション。停止しても画面上では何も起きず、履歴ウィンドウを
    /// 開いていなければ要約が出来たことにも気づけなかったため、次にパネルを開いた時に
    /// 「見返す」導線として出す。次のセッションを始めるまで残る。
    var recentlyEndedSession: SessionInfo? {
        guard !status.active, let id = lastEndedSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    /// そのセッションの要約が、いま作られている途中か(停止直後の待ち時間も含む)。
    func isAwaitingSummary(_ session: SessionInfo) -> Bool {
        summarizingSessionID == session.id || pendingAutoSummarySessionID == session.id
    }
    /// refreshSessions が呼ばれるたびに増える版数。停止直後は最終行の書き込みが
    /// 完了直前まで遅れるため、SessionDetailView が読み直すきっかけに使う。
    private(set) var sessionsVersion = 0

    /// 次のセッションが入るグループ(未分類なら nil)。パネルのグループ表示と、
    /// 実際の保存先はこれ1本で決める。
    ///
    /// この値は保存しない。以前は「既定グループ」として設定に残していたが、
    /// 一度どこかへ入れると以後のセッションが黙って同じグループへ吸い込まれ、
    /// ユーザーが選んでいない場所へ会議の記録が溜まっていた。グループを覚えるのは
    /// 予定名ごと(inferSessionFolder が履歴から引く)に限り、それ以外は未分類にする。
    private(set) var plannedFolder: String?
    /// plannedFolder をどの予定に合わせたか(予定が無ければ nil)。
    @ObservationIgnored private var appliedGroupCalendarTitle: String?
    /// その予定の間に、ユーザーが手でグループを選び直したか。
    /// 選び直した分は、パネルを開き直しても推測で上書きしない。
    @ObservationIgnored private var folderChosenManually = false

    /// カレンダーの会議に合わせて録音を始める見張り役。設定がオフの間は止めておく。
    @ObservationIgnored private var meetingAutoStartScheduler: MeetingAutoStartScheduler?
    /// 予告を出したあと、開始時刻まで待っているタスク。「今回はやめる」で取り消す。
    @ObservationIgnored private var pendingMeetingStart: Task<Void, Never>?
    /// いま浮遊パネルに出している確認の種類。別の用件の確認を、あとから来た
    /// 無関係な合図で消してしまわないために持つ。
    @ObservationIgnored private var activeNudge: NudgeKind?

    /// 1日1回、新しいバージョンが出ていないかを見に行く見張り役。設定がオフの間は止めておく。
    @ObservationIgnored private var updateCheckScheduler: UpdateCheckScheduler?

    private enum NudgeKind {
        /// 会議が始まるので録音を開始する、という予告。
        case meetingStart
        /// 無音が続いたので止めるか、という確認。
        case silence
        /// 新しいバージョンが出ている、という知らせ。
        case updateAvailable
    }

    /// 直前の自動要約の失敗。詳細画面で理由を出し、手動で作り直せるようにする
    /// (握りつぶすと「要約が出ない」以上のことがユーザーに何も伝わらない)。
    private(set) var autoSummaryFailure: AutoSummaryFailure?

    struct AutoSummaryFailure: Equatable {
        let sessionID: String
        let message: String
    }

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
        engine.onHealthEvent = { [weak self] event in
            self?.handleHealthEvent(event)
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
        engine.setSilenceWatch(enabled: settings.confirmStopOnSilence)
        settings.silenceWatchChanged = { [weak self] in
            guard let self else { return }
            engine.setSilenceWatch(enabled: settings.confirmStopOnSilence)
        }
        // 無音が続いても勝手には止めない。止めるかどうかを画面で確かめ、
        // 止める場合は手動停止と同じ経路(stopSession)を通す
        // (自動要約などの後処理を素通りさせないため)。
        engine.onProlongedSilence = { [weak self] in
            self?.presentSilenceNudge()
        }
        engine.onSilenceEnded = { [weak self] in
            self?.dismissNudge(.silence)
        }
        // 相手だけが無音のまま続くのは、耳では気づけない片側だけの欠落の兆候。
        // 会議中に割り込むほどではないので、パネルのバナーとしてだけ出す。
        engine.onSystemAudioSilent = { [weak self] in
            self?.presentSystemAudioSilentIssue()
        }
        engine.onSystemAudioResumed = { [weak self] in
            self?.resolveHealthIssue(.systemAudioSilent)
        }
        let meetingScheduler = MeetingAutoStartScheduler()
        meetingScheduler.onDue = { [weak self] meeting in
            self?.presentMeetingStartNudge(for: meeting)
        }
        meetingScheduler.exclusions = { [weak self] in
            guard let self else { return (ids: [], keywords: []) }
            return (
                ids: Set(settings.excludedMeetings.keys),
                keywords: settings.excludedMeetingKeywords)
        }
        meetingAutoStartScheduler = meetingScheduler
        meetingScheduler.setEnabled(settings.meetingAutoStart)
        settings.meetingAutoStartChanged = { [weak self] in
            guard let self else { return }
            meetingScheduler.setEnabled(settings.meetingAutoStart)
            if !settings.meetingAutoStart { cancelPendingMeetingStart() }
        }
        let updateScheduler = UpdateCheckScheduler()
        updateScheduler.onUpdateFound = { [weak self] latest in
            self?.presentUpdateNudge(latest: latest)
        }
        updateCheckScheduler = updateScheduler
        updateScheduler.setEnabled(settings.autoUpdateCheck)
        settings.autoUpdateCheckChanged = { [weak self] in
            guard let self else { return }
            updateScheduler.setEnabled(settings.autoUpdateCheck)
            if !settings.autoUpdateCheck { dismissNudge(.updateAvailable) }
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
        // claude/codex の検出は zsh -lc 経由で数百 ms かかり得るため、起動をブロックしない
        // バックグラウンド検出に回す(結果はキャッシュされ、以後は即座に読める)。
        AgentCLIDetector.shared.detectIfNeeded()
        // 前回の強制終了で変換されずに残った録音を拾う。起動をブロックしないよう
        // 非同期で行い、1件以上救えたら通知センターで知らせる
        // (パネルを開かない限り気づけない静かな回収のため)。
        Task { await recoverOrphanedRecordings() }
    }

    private func recoverOrphanedRecordings() async {
        let results = await RecordingRecovery.recoverAll()
        guard results.contains(where: \.succeeded) else { return }
        HealthNotifier.notify(title: "前回の録音を復旧しました", body: nil)
    }

    /// エンジンからの健全性イベントを、パネルに出す文言と対処導線に組み立てる。
    /// 録音が止まっても文字起こしは独立して続く(SessionRecorder.writeBlock 参照)ため、
    /// 録音系の異常は「録音は止まったが記録自体は続いている」ことが伝わる文言にする。
    private func handleHealthEvent(_ event: SessionHealthEvent) {
        let issue: HealthIssue
        // 権限拒否はセッション開始直後にパネルを見れば気づける想定のため通知はしない。
        // セッション中に無言で止まり得るものだけ通知センターにも出す。
        var shouldNotify = false
        switch event {
        case .micPermissionDenied:
            issue = HealthIssue(
                kind: .micPermissionDenied,
                title: "マイクが許可されていません",
                detail: "自分の声が録音・文字起こしされません。",
                settingsPane: "Privacy_Microphone")
        case .speechPermissionDenied:
            issue = HealthIssue(
                kind: .speechPermissionDenied,
                title: "音声認識が許可されていません",
                detail: "文字起こしが行われません。",
                settingsPane: "Privacy_SpeechRecognition")
        case .systemAudioUnavailable(let reason):
            issue = HealthIssue(
                kind: .systemAudioUnavailable,
                title: "相手の音声を取得できませんでした",
                detail: reason,
                settingsPane: nil)
            shouldNotify = true
        case .recordingWriteFailed:
            issue = HealthIssue(
                kind: .recordingWriteFailed,
                title: "録音が停止しました",
                detail: "文字起こしは引き続き行われます。",
                settingsPane: nil)
            shouldNotify = true
        case .recordingConversionFailed:
            issue = HealthIssue(
                kind: .recordingConversionFailed,
                title: "録音ファイルの仕上げに失敗しました",
                detail: "元の録音データは残っています。",
                settingsPane: nil)
            shouldNotify = true
        }
        present(issue, notify: shouldNotify)
    }

    /// 相手のチャンネルだけが長く無音になっている、という知らせ。取得自体は動いているため、
    /// 断定はせず「届いていない」という事実と、直し方だけを伝える。
    /// 通知センターにも出す(パネルを開かない限り気づけない静かな欠落のため)。
    private func presentSystemAudioSilentIssue() {
        present(
            HealthIssue(
                kind: .systemAudioSilent,
                title: "相手の音声が10分以上届いていません",
                detail: "相手が話しているのにこの表示が出る場合は、いったん停止して開始し直してください。",
                settingsPane: nil),
            notify: true)
    }

    /// 異常を1件出す。「同じ種類は最新の1件だけ」「再発したら畳んだ状態は引き継がない」
    /// という規則を守る唯一の場所(規則を足す時にここだけ見ればよくする)。
    private func present(_ issue: HealthIssue, notify: Bool) {
        healthIssues.removeAll { $0.kind == issue.kind }
        healthIssues.append(issue)
        collapsedHealthIssues.remove(issue.kind)
        if notify {
            HealthNotifier.notify(title: issue.title, body: issue.detail)
        }
    }

    /// 異常の原因が解消したので引っ込める。ユーザーの「了解」ではなく、状態の回復で消す経路。
    private func resolveHealthIssue(_ kind: HealthIssueKind) {
        healthIssues.removeAll { $0.kind == kind }
        collapsedHealthIssues.remove(kind)
    }

    /// パネルのバナーで「了解」を押した時に、その異常だけを引っ込める。
    /// 続いている異常は消さない(消せる導線をバナー側が出さないが、二重の歯止めとして
    /// ここでも弾く)。続いているものを引っ込めたい場合は畳む方を使う。
    func dismissHealthIssue(_ issue: HealthIssue) {
        guard !issue.isOngoing else { return }
        resolveHealthIssue(issue.kind)
    }

    /// 続いている異常の表示を、1行に畳む/元に戻す。畳んでもメニューバーの印は残るため、
    /// 「いま何かおかしい」こと自体は見えたままになる。
    func toggleHealthIssueCollapsed(_ issue: HealthIssue) {
        if collapsedHealthIssues.contains(issue.kind) {
            collapsedHealthIssues.remove(issue.kind)
        } else {
            collapsedHealthIssues.insert(issue.kind)
        }
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

    /// folder 省略時(.auto)は、カレンダーの今の予定名と履歴からグループを推測する。
    /// 同名の履歴が無ければ未分類に入れる(autoFolder 参照)。
    /// IPC(hearcat start)経由・メニューの録音ボタン・ホットキー(選択画面オフ)も
    /// folder を渡さずに呼ぶことで、同じ推測経路を通る。
    /// ホットキーの選択画面で確定した値は .explicit で渡す。
    func startSession(
        record: Bool = true, transcribe: Bool = true,
        folder: SessionFolder = .auto
    ) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        // 録音が始まる以上、会議の予告は役目を終える(手動で先に始めた場合も同じ)。
        cancelPendingMeetingStart()
        // 過去の無関係なエラーを引きずって「開始失敗」と誤報告しないようにする。
        lastError = nil
        // 前のセッションの異常を持ち越さない。
        healthIssues = []
        collapsedHealthIssues = []
        // プローブ稼働中(設定画面のメーターが動いている)にセッションを始めると、
        // 同じマイクを二重に掴んでしまうため、セッション側を優先してプローブを止める。
        stopMicProbe()
        do {
            liveFinals = []
            liveTimeline.removeAll()
            // カレンダーの今の予定名をセッション名にする(設定でオフにできる)。
            let calendarTitle = settings.calendarNaming ? await CalendarNamer.currentEventTitle() : nil
            let resolvedFolder: String?
            switch folder {
            case .explicit(let f):
                resolvedFolder = f
            case .auto:
                resolvedFolder = autoFolder(forCalendarTitle: calendarTitle)
            }
            try await engine.start(
                record: record, transcribe: transcribe,
                name: calendarTitle ?? "", folder: resolvedFolder)
            // 実際の保存先をパネルの表示にも反映する。ここを揃えないと、
            // 会議名から推測して別グループへ保存したのに、パネルは前回のグループを
            // 出したままになり「切り替わっていない」ように見える。
            plannedFolder = resolvedFolder
            appliedGroupCalendarTitle = Self.eventKey(calendarTitle)
            folderChosenManually = false
            refreshSessions()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 予定名の有無を1つの値にそろえる。空文字と nil はどちらも「予定なし」。
    private static func eventKey(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        return title
    }

    /// この予定のときの保存先。
    /// - その予定の間に手で選び直していれば、その選択を尊重する
    /// - 予定があれば、同じ名前の過去セッションが入っているグループ。無ければ未分類
    /// - 予定が無ければ未分類
    ///
    /// 推測できないものを既定のグループへ落とさないのは、無関係なグループの資料フォルダを
    /// 要約が読みにいってしまうため。分類できないものは分類しないでおく。
    private func autoFolder(forCalendarTitle rawTitle: String?) -> String? {
        let title = Self.eventKey(rawTitle)
        if folderChosenManually, title == appliedGroupCalendarTitle { return plannedFolder }
        guard let title else { return nil }
        return Self.inferSessionFolder(forCalendarTitle: title, in: sessions)
    }

    /// 待機中に、今の(またはまもなく始まる)予定に紐づくグループへ表示を寄せる。
    /// メニューバーのパネルを開くたびに呼ばれる。予定が変わったタイミングで、
    /// 手で選び直した分の記憶も一緒に捨てる(前の会議の選択を次の会議へ持ち越さない)。
    func syncGroupSelectionWithCurrentEvent() async {
        guard !status.active else { return }
        let rawTitle = settings.calendarNaming ? await CalendarNamer.currentEventTitle() : nil
        let title = Self.eventKey(rawTitle)
        if title != appliedGroupCalendarTitle {
            appliedGroupCalendarTitle = title
            folderChosenManually = false
        }
        plannedFolder = autoFolder(forCalendarTitle: title)
    }

    /// パネルでユーザーがグループを選び直した。この選択が効くのは、次に始める
    /// 1セッションだけ(正確には、今の予定が変わるかセッションが始まるまで)。
    /// 選択を既定として持ち越さないのは、覚えた先が「自分で選んでいないのに
    /// 会議の記録が溜まる場所」になるため。次からも同じグループに入れたい会議は、
    /// 予定名ごとの履歴(inferSessionFolder)が自動で拾う。
    func selectFolder(_ folder: String?) {
        plannedFolder = folder
        folderChosenManually = true
    }

    /// 進行中セッションの保存先グループ(未分類なら nil)。パネルに出して、
    /// 「今どこへ保存されているか」をセッション中でも確かめられるようにする。
    var activeSessionFolder: String? {
        guard status.active, let id = status.sessionID else { return nil }
        let parts = id.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : nil
    }

    /// カレンダーの予定名と同じ名前で過去に保存されたセッションから、最も多く入っているグループを返す。
    /// 同数なら直近のセッションのグループ(=最近の運用に寄せる)。
    /// 同名の履歴が無ければ未分類(nil)。
    /// 判定は lowercased + 前後空白トリムで揃える(半角/全角の細かい正規化まではしない。
    /// カレンダーの予定名は毎回同じ表記で入っている前提)。
    static func inferSessionFolder(
        forCalendarTitle title: String,
        in sessions: [SessionInfo]
    ) -> String? {
        let key = normalizeSessionTitle(title)
        guard !key.isEmpty else { return nil }
        let matched = sessions.filter { normalizeSessionTitle($0.name) == key }
        guard !matched.isEmpty else { return nil }
        // 未分類(nil)も「その名前でよく使われている置き場所」の1つとして数える。
        var counts: [String?: Int] = [:]
        var latest: [String?: Date] = [:]
        for s in matched {
            counts[s.folder, default: 0] += 1
            if (latest[s.folder] ?? .distantPast) < s.startDate {
                latest[s.folder] = s.startDate
            }
        }
        guard let best = counts.max(by: { a, b in
            if a.value != b.value { return a.value < b.value }
            return (latest[a.key] ?? .distantPast) < (latest[b.key] ?? .distantPast)
        }) else { return nil }
        return best.key
    }

    /// 突き合わせは「保存されるときの名前」に揃える。セッション名は保存時に
    /// 「/」「:」が「-」へ置換されるため、生の予定名のまま比べると、それらを含む
    /// 予定(「A / B 定例」など)が履歴と一致せず、常に未分類へ落ちてしまう。
    /// storedName が既に前後の空白を落としているため、ここでは小文字化だけでよい。
    private static func normalizeSessionTitle(_ s: String) -> String {
        SessionStore.storedName(for: s).lowercased()
    }

    // MARK: - 確認パネル(会議の予告 / 無音の確認)

    /// 会議が始まるので録音を始める、という予告を出す。開始時刻になるまで待ってから
    /// 始めるので、この間に「今回はやめる」を押せば録音は始まらない。
    private func presentMeetingStartNudge(for meeting: CalendarMeeting) {
        // 既に録音中なら、その会議の分はもう録れている。何も言わない。
        guard !status.active else { return }
        // 予定の開始時刻ちょうどに始める。既に始まっている会議を拾った場合でも、
        // 押す間もなく始まらないよう最低5秒は猶予を置く。
        let deadline = max(meeting.startDate, Date().addingTimeInterval(5))
        pendingMeetingStart?.cancel()
        pendingMeetingStart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
            guard !Task.isCancelled, let self, !self.status.active else { return }
            // 自分の待ち合わせは役目を終えた。ここで手放しておかないと、この先の
            // startSession が「待機中の予告を取り消す」処理で自分自身を止めてしまう。
            self.pendingMeetingStart = nil
            await self.startSession()
        }
        let name = meeting.title.isEmpty ? "会議" : meeting.title
        presentNudge(
            .meetingStart,
            prompt: NudgePrompt(
                icon: "calendar.badge.clock",
                title: "まもなく「\(name)」が始まります",
                detail: "この時間になったら、録音と文字起こしを自動で始めます。",
                deadline: deadline,
                actions: [
                    // 毎回「今回はやめる」を押させないための逃げ道。繰り返しの予定は
                    // ID が全回で共通なので、一度押せば以後この予定では予告も出ない。
                    NudgeAction(title: "今後録らない") { [weak self] in
                        guard let self else { return }
                        settings.excludedMeetings[meeting.seriesID] = name
                        cancelPendingMeetingStart()
                    },
                    NudgeAction(title: "今回はやめる") { [weak self] in
                        self?.cancelPendingMeetingStart()
                    },
                    NudgeAction(title: "今すぐ始める", isPrimary: true) { [weak self] in
                        guard let self else { return }
                        self.pendingMeetingStart?.cancel()
                        self.pendingMeetingStart = nil
                        self.dismissNudge(.meetingStart)
                        Task { await self.startSession() }
                    },
                ]))
    }

    /// 予告を取り消して、この会議では録音を始めない。
    private func cancelPendingMeetingStart() {
        pendingMeetingStart?.cancel()
        pendingMeetingStart = nil
        dismissNudge(.meetingStart)
    }

    /// 無音が続いたので止めるか確認する。返事があるまで録音は続く。
    private func presentSilenceNudge() {
        guard status.active else { return }
        presentNudge(
            .silence,
            prompt: NudgePrompt(
                icon: "moon.zzz",
                title: "5分ほど声が聞こえていません",
                detail: "録音は続いています。会議が終わっているなら、ここで止めて要約まで進めます。",
                deadline: nil,
                actions: [
                    NudgeAction(title: "録音を続ける") { [weak self] in
                        self?.dismissNudge(.silence)
                    },
                    NudgeAction(title: "停止して要約", isPrimary: true) { [weak self] in
                        guard let self else { return }
                        self.dismissNudge(.silence)
                        Task { await self.stopSession() }
                    },
                ]))
    }

    /// 新しいバージョンが出ていることを知らせる。更新はコマンドの再実行で行うため、
    /// ここではその場でコマンドを渡すところまでを引き受ける。
    private func presentUpdateNudge(latest: String) {
        // 録音中に割り込まない。更新には HearCat の終了が要るので、いま伝えても押せない。
        guard !status.active else { return }
        presentNudge(
            .updateAvailable,
            prompt: NudgePrompt(
                icon: "arrow.down.circle",
                title: "新しい \(latest) があります",
                detail: "「コマンドをコピー」を押すと、更新用のコマンドをクリップボードに入れます。ターミナルに貼り付けて実行してください。",
                deadline: nil,
                actions: [
                    NudgeAction(title: "あとで") { [weak self] in
                        self?.dismissNudge(.updateAvailable)
                    },
                    NudgeAction(title: "コマンドをコピー", isPrimary: true) { [weak self] in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(UpdateCheck.command, forType: .string)
                        self?.dismissNudge(.updateAvailable)
                    },
                ]))
    }

    private func presentNudge(_ kind: NudgeKind, prompt: NudgePrompt) {
        activeNudge = kind
        NudgeOverlayController.shared.present(prompt)
    }

    /// 指定した用件の確認だけを引っ込める。別の用件が出ている場合は触らない。
    private func dismissNudge(_ kind: NudgeKind) {
        guard activeNudge == kind else { return }
        activeNudge = nil
        NudgeOverlayController.shared.dismiss()
    }

    func stopSession() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        // 止めた以上、無音の確認は用済み。
        dismissNudge(.silence)
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

    /// 停止直後の自動要約を待っているセッション ID。生成が始まるまでに数秒の間があり、
    /// summarizingSessionID だけを見ると、その間だけ「要約なし」に見えてしまう
    /// (パネルの直前セッションの表示が「文字起こしを見る」→「作成中」と揺れる)。
    private(set) var pendingAutoSummarySessionID: String?

    /// 要約を生成して summary.md に保存し、履歴を読み直す。
    /// 停止直後の自動生成と詳細画面のボタンの共通経路。
    func generateSummary(for session: SessionInfo, transcript: String) async throws -> String {
        summarizingSessionID = session.id
        defer { summarizingSessionID = nil }
        let result = try await TranscriptSummarizer.summarize(transcript: transcript)
        let url = session.directory.appendingPathComponent("summary.md")
        try result.write(to: url, atomically: true, encoding: .utf8)
        clearAutoSummaryFailure(for: session)
        // チップ表示用にエンジン種別を固定する。失敗しても要約自体は生成できているので
        // 握りつぶす(チップが出ないだけで実害はない)。
        try? SessionStore.writeSummaryEngine(.appleIntelligence, for: session)
        refreshSessions()
        return result
    }

    /// エージェント CLI(claude/codex)で高精度要約を生成し、summary.md に保存する。
    /// 入力は cleaned.md(あれば)を優先し、無ければ生の文字起こしを使う
    /// (清書済みのほうが音声認識の誤変換が少なく、要約の質が上がるため)。
    func generateAgentSummary(for session: SessionInfo, using cli: AgentCLI) async throws -> String {
        summarizingSessionID = session.id
        defer { summarizingSessionID = nil }
        guard let sourceURL = session.cleanedURL ?? session.transcriptURL,
            let transcript = try? String(contentsOf: sourceURL, encoding: .utf8),
            !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AgentSummarizeError.noTranscript
        }
        let referenceFolder = session.folder.flatMap { settings.referenceFolders[$0] }
        let result = try await AgentSummarizer.summarize(
            using: cli,
            model: settings.summaryAgentModel(for: cli),
            transcript: transcript,
            referenceFolder: referenceFolder)
        let url = session.directory.appendingPathComponent("summary.md")
        try result.write(to: url, atomically: true, encoding: .utf8)
        try? SessionStore.writeSummaryEngine(cli.summaryEngine, for: session)
        clearAutoSummaryFailure(for: session)
        refreshSessions()
        return result
    }

    /// 手動で作り直せたセッションについては、自動要約の失敗表示を取り下げる。
    private func clearAutoSummaryFailure(for session: SessionInfo) {
        guard autoSummaryFailure?.sessionID == session.id else { return }
        autoSummaryFailure = nil
    }

    // MARK: - 進行中の会議を関連資料と照合する

    /// ホットキーとメニューバーの共通入口。オーバーレイを開くだけで、調査は開始しない
    /// (何を調べるかは入力欄からユーザーが決める。開いた瞬間に空のダイジェスト調査が
    /// 走る旧挙動は、質問ファーストの UX に変えた際に廃止した)。
    /// 調査中・結果表示中ならその画面を前面へ戻す。開いた時点で使えない状態
    /// (文字起こし停止中など)だけは先に知らせる。
    func openCodeImpactPanel() {
        showCodeImpactOverlay()
        switch codeImpactAnalysisState {
        case .idle, .failed:
            do {
                _ = try codeImpactContext()
                // 前回の失敗表示が残っていても、いま使える状態なら入力待ちへ戻す。
                codeImpactAnalysisState = .idle
            } catch {
                codeImpactAnalysisState = .failed(error.localizedDescription)
            }
        case .requiresConsent, .analyzing, .completed:
            break
        }
    }

    /// 調査の開始(オーバーレイの送信・再試行・紐付け後の再開から呼ばれる)。
    /// question を渡すと質問特化のプロンプト、nil ならダイジェスト調査で走らせる。
    func requestCodeImpactAnalysis(question: String? = nil) {
        // nil も含めて上書きする。同意待ち・失敗からの再試行など、以後の続行処理は
        // すべてこの codeImpactQuestion を読むだけにするため、他のどのチェックよりも先に確定させる。
        codeImpactQuestion = question
        showCodeImpactOverlay()
        if case .analyzing = codeImpactAnalysisState { return }

        let cli = selectedCodeImpactAgent
        do {
            _ = try codeImpactContext()
        } catch {
            codeImpactAnalysisState = .failed(error.localizedDescription)
            return
        }
        guard settings.codeImpactConsented else {
            codeImpactAnalysisState = .requiresConsent(cli)
            return
        }
        startCodeImpactAnalysis(using: cli)
    }

    /// 外部 AI へ文字起こしを送る初回確認後、そのまま同じ操作を続行する。
    /// requiresConsent の間も codeImpactQuestion は変わらないため、同意で入力が失われない。
    /// 同意は関連資料との照合に限定した codeImpactConsented を立てる。
    /// 要約側(agentSummaryConsented)には波及させない(片方の同意で
    /// もう片方が外部送信され得るプライバシー越境を防ぐため)。
    func confirmCodeImpactAnalysis(using cli: AgentCLI) {
        settings.codeImpactConsented = true
        startCodeImpactAnalysis(using: cli)
    }

    func cancelCodeImpactAnalysis() {
        codeImpactTask?.cancel()
        codeImpactTask = nil
        codeImpactRequestID = nil
        codeImpactAnalysisState = .idle
    }

    func dismissCodeImpactOverlay() {
        codeImpactOverlayController?.close()
    }

    /// 資料フォルダ未紐付けのまま調べた結果(完了表示の下の導線、または過去の失敗表示)から、
    /// その場で資料フォルダを選んで照合をやり直す。セッションがグループ所属ならそのグループへ
    /// 紐付け、未分類なら新規グループを作らずこの会議だけの一時紐付け
    /// (codeImpactReferenceFolderOverride)にする(録音中のセッションはディレクトリを
    /// 移動できないため)。question は codeImpactQuestion を読む。
    func linkReferenceFolderForCodeImpact() {
        guard status.active, status.transcribing, let sessionDirectory = status.sessionDirectory,
            let session = SessionStore.list().first(where: { $0.directory.path == sessionDirectory })
        else {
            // ここに来るはずのボタンは進行中のセッションでしか出ないが、念のため
            // 崩れていた場合は通常の調査要求に任せて、そちらのエラー表示に委ねる。
            requestCodeImpactAnalysis(question: codeImpactQuestion)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if let folder = session.folder {
                await ReferenceFolderPicker.pick(forGroup: folder, from: nil)
                // キャンセル等で紐付かなかった場合は failed 表示のまま何もしない。
                guard self.settings.referenceFolders[folder] != nil else { return }
            } else {
                guard let newFolder = await ReferenceFolderPicker.pickForNewGroup(from: nil),
                    let path = self.settings.referenceFolders[newFolder]
                else { return }
                // セッションはグループへ移さず(進行中は不可)、この会議だけ覚える。
                // 既定グループ(plannedFolder)も変更しない。
                self.codeImpactReferenceFolderOverride = (sessionDirectory, path)
            }
            // 質問を入力して失敗していた場合だけ、その質問で自動再開する。
            // 何も入力していなかった場合は、紐付けだけで調査(外部送信)を勝手に
            // 始めず、入力待ちへ戻す(何を調べるかはユーザーが決める)。
            let trimmedQuestion = self.codeImpactQuestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmedQuestion.isEmpty {
                self.codeImpactAnalysisState = .idle
            } else {
                self.requestCodeImpactAnalysis(question: trimmedQuestion)
            }
        }
    }

    private var selectedCodeImpactAgent: AgentCLI {
        let preferred = settings.codeImpactAgent
        let available = AgentCLIDetector.shared.availableCLIs
        guard !available.isEmpty, !available.contains(preferred) else { return preferred }
        return available[0]
    }

    /// 直前の結果を踏まえた追加質問を投げる。completed 状態からのみ可能で、
    /// 質問文字列が空(またはトリムで空になる)なら誤送信として無視する。
    /// 初回の consent は完了済みなので再確認しない。
    func requestFollowUpCodeImpact(question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard case .completed(let cli) = codeImpactAnalysisState else { return }
        guard let previousResult = codeImpactTurns.last?.result else { return }
        codeImpactQuestion = trimmed
        showCodeImpactOverlay()
        startCodeImpactAnalysis(using: cli, previousResult: previousResult)
    }

    /// question は引数に取らず、常に codeImpactQuestion(呼び出し側が事前に設定済み)を読む。
    private func startCodeImpactAnalysis(
        using cli: AgentCLI,
        previousResult: String? = nil
    ) {
        let context: (transcript: String, referenceFolder: String?)
        do {
            context = try codeImpactContext()
        } catch {
            codeImpactAnalysisState = .failed(error.localizedDescription)
            return
        }
        codeImpactActiveReferenceFolder = context.referenceFolder

        // 会議(セッションディレクトリ)が変わっていたら、前の会議の claude セッションを
        // 引き継がない。同じ会議のあいだは維持し、--resume で会話を続ける。
        if status.sessionDirectory != codeImpactSessionDirectory {
            codeImpactSessionID = nil
            codeImpactSessionDirectory = status.sessionDirectory
            // 会議が変われば Q&A 履歴も前の会議のものなので持ち越さない。
            codeImpactTurns = []
        }

        // ここでは settings.codeImpactAgent へは書かない。
        // selectedCodeImpactAgent は「保存された希望が使えない時に available[0] へ
        // フォールバックする」経路のため、この時の cli を保存し戻すと、フォールバック値が
        // ユーザーの選択として固定化されてしまう(希望の CLI が復帰しても Codex のまま等)。
        let model = settings.codeImpactAgentModel(for: cli)
        let question = codeImpactQuestion
        codeImpactAnalysisState = .analyzing(cli)
        codeImpactPartialText = ""
        codeImpactActivity = nil
        codeImpactSectionOverrides = [:]
        codeImpactTask?.cancel()
        let requestID = UUID()
        codeImpactRequestID = requestID
        codeImpactTask = Task { [weak self] in
            do {
                let result: String
                switch cli {
                case .claude:
                    // claude だけストリーミング + セッション継続の経路を使う。
                    let resumeSessionID = self?.codeImpactSessionID
                    let prompt = AgentCodeImpactAnalyzer.buildPrompt(
                        question: question, previousResult: previousResult,
                        isResuming: resumeSessionID != nil,
                        hasReferenceFolder: context.referenceFolder != nil)
                    let stream = try await AgentCodeImpactStream.run(
                        model: model,
                        transcript: context.transcript,
                        referenceFolder: context.referenceFolder,
                        prompt: prompt,
                        resumeSessionID: resumeSessionID
                    ) { event in
                        // readabilityHandler の背景キューから呼ばれるため、self を直接は
                        // 使わず(@Sendable クロージャに MainActor 型を捕まえないため)、
                        // MainActor 上で shared 経由で状態を更新する。
                        Task { @MainActor in
                            let model = AppModel.shared
                            guard model.codeImpactRequestID == requestID else { return }
                            switch event {
                            case .sessionID(let id):
                                model.codeImpactSessionID = id
                            case .textDelta(let text):
                                model.codeImpactPartialText += text
                            case .activity(let text):
                                model.codeImpactActivity = text
                            case .reset:
                                model.codeImpactPartialText = ""
                                model.codeImpactActivity = nil
                            }
                        }
                    }
                    result = stream.result
                    if let sessionID = stream.sessionID {
                        self?.codeImpactSessionID = sessionID
                    }
                case .codex:
                    // codex はストリーミング/セッション継続の対象外。従来どおり一括実行。
                    result = try await AgentCodeImpactAnalyzer.analyze(
                        using: cli,
                        model: model,
                        transcript: context.transcript,
                        referenceFolder: context.referenceFolder,
                        question: question,
                        previousResult: previousResult)
                }
                guard !Task.isCancelled, self?.codeImpactRequestID == requestID else { return }
                // 失敗・キャンセルでは積まない。ここに来た時点で成功が確定している。
                self?.codeImpactTurns.append(CodeImpactTurn(question: question, result: result))
                self?.codeImpactAnalysisState = .completed(cli)
            } catch {
                guard !Task.isCancelled, let self, self.codeImpactRequestID == requestID else { return }
                self.codeImpactAnalysisState = .failed(error.localizedDescription)
            }
            if self?.codeImpactRequestID == requestID {
                self?.codeImpactTask = nil
                self?.codeImpactRequestID = nil
            }
        }
    }

    private func codeImpactContext() throws -> (transcript: String, referenceFolder: String?) {
        guard status.active, status.transcribing, let sessionDirectory = status.sessionDirectory else {
            throw CodeImpactContextError.inactive
        }
        guard let session = SessionStore.list().first(where: { $0.directory.path == sessionDirectory }) else {
            throw CodeImpactContextError.sessionNotFound
        }
        let referenceFolder = resolveCodeImpactReferenceFolder(
            session: session, sessionDirectory: sessionDirectory)
        guard let transcriptURL = session.transcriptURL,
            let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
            !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AgentSummarizeError.noTranscript
        }
        return (transcript, referenceFolder)
    }

    /// 資料フォルダの解決。優先順は次のとおり:
    /// 1. セッションがグループ所属で、そのグループに資料フォルダが紐付いていればそれ。
    /// 2. なければ codeImpactReferenceFolderOverride(この会議だけの一時的な紐付け)が
    ///    同じセッションディレクトリのものであり、パスが実在すればそれ。
    /// 3. どちらも無ければ nil。資料フォルダが無くても文字起こしだけを根拠に調査できる
    ///    ため、呼び出し側はこれをエラーではなく「文字起こしのみモード」の合図として扱う。
    private func resolveCodeImpactReferenceFolder(
        session: SessionInfo, sessionDirectory: String
    ) -> String? {
        if let folder = session.folder,
            let referenceFolder = settings.referenceFolders[folder],
            FileManager.default.fileExists(atPath: referenceFolder)
        {
            return referenceFolder
        }
        if let override = codeImpactReferenceFolderOverride,
            override.sessionDirectory == sessionDirectory,
            FileManager.default.fileExists(atPath: override.path)
        {
            return override.path
        }
        return nil
    }

    private func showCodeImpactOverlay() {
        if codeImpactOverlayController == nil {
            codeImpactOverlayController = CodeImpactOverlayController(model: self)
        }
        codeImpactOverlayController?.show()
    }

    /// 停止直後の自動要約。要約済みのセッションには手を出さない。
    /// 使うエンジンは settings.autoSummaryEngine で決める(nil なら何もしない)。
    /// 失敗した場合は理由を残す(autoSummaryFailure と lastError)。以前は例外を
    /// 握りつぶしていたため、CLI のログイン切れのような直せる失敗でも
    /// 「要約が生成されない」ことしか分からなかった。
    private func autoSummarize(sessionID: String) {
        guard let engine = settings.autoSummaryEngine else { return }
        pendingAutoSummarySessionID = sessionID
        Task {
            defer { pendingAutoSummarySessionID = nil }
            // 最後の発話の確定は、停止よりファイル書き込みがわずかに遅れることがある。
            try? await Task.sleep(for: .seconds(2))
            guard summarizingSessionID == nil,
                let session = SessionStore.list().first(where: { $0.id == sessionID }),
                session.summaryURL == nil,
                let url = session.transcriptURL,
                let transcript = try? String(contentsOf: url, encoding: .utf8),
                !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            do {
                switch engine {
                case .appleIntelligence:
                    if let reason = OnDeviceModel.unavailableReason() {
                        throw AutoSummaryError.onDeviceUnavailable(reason)
                    }
                    _ = try await generateSummary(for: session, transcript: transcript)
                case .claude, .codex:
                    // エージェント要約は文字起こしを外部へ送るため、明示的に同意した人だけ動かす。
                    // 選択の同意が未取得(古い設定を持ち込んだケース)ならスキップ。
                    guard settings.agentSummaryConsented else { return }
                    guard let cli = AgentCLI(summaryEngine: engine) else { return }
                    // 検出済み一覧(起動時に1回だけ走る)で門番をしない。検出が失敗して
                    // いるだけで自動要約が黙って止まるより、実行して「見つからない」と
                    // 報告するほうが直せる。
                    _ = try await generateAgentSummary(for: session, using: cli)
                }
                autoSummaryFailure = nil
            } catch {
                autoSummaryFailure = AutoSummaryFailure(
                    sessionID: session.id, message: error.localizedDescription)
                lastError = "自動要約に失敗しました: \(error.localizedDescription)"
            }
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
                    await startSessionViaHotkey(record: true, transcribe: true)
                }
            }
        // 録音/文字起こしのキーはセッション外では「その機能だけオンで開始」。
        // 押して何も起きないデッドゾーンを作らない。
        case .toggleRecording:
            if status.active {
                setRecording(!status.recording)
            } else {
                Task { await startSessionViaHotkey(record: true, transcribe: false) }
            }
        case .toggleTranscribing:
            if status.active {
                setTranscribing(!status.transcribing)
            } else {
                Task { await startSessionViaHotkey(record: false, transcribe: true) }
            }
        case .analyzeCodeImpact:
            openCodeImpactPanel()
        case .openHistory:
            showHistory()
        case .openSettings:
            showSettings()
        }
    }

    /// ホットキーからのセッション開始。hotkeyGroupPicker が有効なら開始前に
    /// グループ選択の小さい画面を出し、ESC・キャンセルなら開始自体を中止する。
    /// 選択画面は NSAlert(モーダル)のため、この呼び出し自体は同期的にブロックする。
    private func startSessionViaHotkey(record: Bool, transcribe: Bool) async {
        guard settings.hotkeyGroupPicker else {
            await startSession(record: record, transcribe: transcribe)
            return
        }
        // 選択画面の初期選択も、カレンダーの予定名+履歴からの推測に合わせる
        // (同じ会議名を初期表示する = ユーザーはそのまま「開始」を押すだけで済む)。
        // 推測できない予定は未分類が初期選択になる。
        let calendarTitle = settings.calendarNaming ? await CalendarNamer.currentEventTitle() : nil
        let initialGroup = autoFolder(forCalendarTitle: calendarTitle)
        guard let result = HotkeyGroupPicker.choose(defaultGroup: initialGroup) else {
            return
        }
        if result.skipNextTime {
            settings.hotkeyGroupPicker = false
        }
        // 選択画面で確定した値は、ユーザーが手で選んだ既定として扱う。
        selectFolder(result.folder)
        await startSession(record: record, transcribe: transcribe, folder: .explicit(result.folder))
    }

    // MARK: - ウィンドウ表示

    /// 履歴ウィンドウを開く。selecting を渡すと、そのセッションを選んだ状態で開く
    /// (停止直後にパネルから「要約を見る」で飛ぶ経路で使う)。
    func showHistory(selecting sessionID: String? = nil) {
        dismissPanel()
        if let sessionID {
            mainWindowSelectionRequest = sessionID
        } else if status.active {
            // セッション中に開く場合は、既に開いたことのあるウィンドウでも必ずライブへ
            // 戻す(前回選んでいたセッションのまま止まってしまわないように)。
            mainWindowSelectionRequest = MainWindow.liveID
        }
        guard let openWindowAction else {
            // 起動直後でまだ注入されていない。注入された時点でここへ戻ってくる。
            needsHistoryWindow = true
            return
        }
        openWindowAction("main")
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
        SessionPreviewCache.shared.retain(ids: Set(sessions.map(\.id)))
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

    /// グループの並び順をユーザーの指定通りに固定する。サイドバーのドラッグ&ドロップ、
    /// 右クリックの「上へ移動」「下へ移動」から呼ぶ。
    func reorderFolders(_ newOrder: [String]) {
        SessionStore.setFolderOrder(newOrder)
        // 書いた直後に読み直さない。newOrder は現在の folders の並べ替えなので内容は同じ。
        folders = newOrder
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

    /// グループ名を覚えている場所すべてを、新しい名前へ差し替える(削除なら nil)。
    /// 名前を覚える場所が増えたときに追従漏れが起きないよう、更新はここ1箇所に集める。
    private func retargetFolderReferences(from folder: String, to newName: String?) {
        if let path = settings.referenceFolders.removeValue(forKey: folder), let newName {
            settings.referenceFolders[newName] = path
        }
        if plannedFolder == folder {
            plannedFolder = newName
        }
    }

    /// フォルダ名を変更し、新しい名前を返す。失敗時は nil。
    /// 古い名前を覚えている設定も一緒に追従させる(残すと宙に浮くため)。
    func renameFolder(_ folder: String, to newName: String) -> String? {
        defer { refreshSessions() }
        do {
            let renamed = try SessionStore.renameFolder(folder, to: newName)
            retargetFolderReferences(from: folder, to: renamed)
            return renamed
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// フォルダを削除する(中のセッションは未分類へ戻る)。
    /// そのフォルダを指していた設定は未分類(nil)へ戻す。
    @discardableResult
    func deleteFolder(_ folder: String) -> Bool {
        defer { refreshSessions() }
        do {
            try SessionStore.deleteFolder(folder)
            retargetFolderReferences(from: folder, to: nil)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - セッションの取り込み(.hearcat)

    /// 確認待ちの取り込み。展開済みの一時ファイルを抱えているため、
    /// 取り込むか取りやめるかのどちらかを必ず通すこと(どちらも一時ファイルを片付ける)。
    private(set) var pendingImport: PendingImport?
    /// 取り込みキュー。複数ファイルをまとめて開かれた場合、1件ずつ確認してもらう。
    @ObservationIgnored private var importQueue: [URL] = []
    /// パッケージを開けなかった理由。履歴ウィンドウがアラートで出す。
    var importError: String?

    struct PendingImport: Identifiable {
        let id = UUID()
        /// 開いた元のファイル。表示用(どのファイルの話かを画面に出す)。
        let sourceName: String
        let opened: SessionPackage.Opened
    }

    /// ファイルを選んで取り込む。Finder でのダブルクリックだけだと、
    /// 「書き出しはアプリの中、取り込みはアプリの外」と入口が非対称になるため、
    /// 履歴ウィンドウからも同じことができるようにする。
    func requestImportFromPanel() {
        Task {
            requestImport(of: await SessionPackagePicker.chooseFiles(from: mainWindow))
        }
    }

    /// Finder から渡されたファイルを、確認画面まで持っていく。
    func requestImport(of urls: [URL]) {
        let packages = SessionPackagePicker.packages(in: urls)
        guard !packages.isEmpty else { return }
        importQueue.append(contentsOf: packages)
        // 確認画面は履歴ウィンドウの上に出すため、閉じていれば開く。
        showHistory()
        openNextImport()
    }

    /// キューの先頭を展開して確認画面に載せる。展開は I/O が重いので別スレッドで行う。
    private func openNextImport() {
        guard pendingImport == nil, !importQueue.isEmpty else { return }
        let url = importQueue.removeFirst()
        Task {
            do {
                let opened = try await Task.detached(priority: .userInitiated) {
                    try SessionPackage.open(url)
                }.value
                pendingImport = PendingImport(
                    sourceName: url.lastPathComponent, opened: opened)
            } catch {
                importError = "\(url.lastPathComponent): \(error.localizedDescription)"
                // 1件失敗しても、まとめて開かれた残りは続けて確認できるようにする。
                openNextImport()
            }
        }
    }

    /// 確認画面で選ばれたグループへ取り込む。取り込んだセッションを選択状態にする。
    func confirmImport(_ pending: PendingImport, intoFolder folder: String?) {
        defer {
            pendingImport = nil
            openNextImport()
        }
        do {
            let session = try SessionPackage.install(pending.opened, intoFolder: folder)
            refreshSessions()
            mainWindowSelectionRequest = session.id
        } catch {
            importError = error.localizedDescription
        }
    }

    /// 取り込まずに閉じる。展開済みの一時ファイルはここで片付ける。
    func cancelImport(_ pending: PendingImport) {
        pending.opened.discard()
        pendingImport = nil
        openNextImport()
    }

    private func mutateSession(
        _ session: SessionInfo, _ operation: (SessionInfo) throws -> SessionInfo
    ) -> String? {
        // 進行中のセッションはファイルを開いたまま書いているため動かせない。
        // status.sessionID は SessionStore.relativeID を通した「グループ/ディレクトリ名」形式なので、
        // session.id(SessionStore.list() が同じ規則で作る)と比較する。
        // 以前は directory.lastPathComponent を比べていたが、グループ配下では両者が食い違い、
        // 「進行中」判定が素通りしてリネーム/移動が走ってしまう不具合があった。
        guard session.id != status.sessionID else {
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
