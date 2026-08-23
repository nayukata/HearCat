import AppKit
import AVFoundation
import EventKit
import HearCatKit
import HearCatSummarize
import Speech
import SwiftUI

/// 初回起動時に一度だけ出すオンボーディング。「何をするアプリか → 始め方 → 会議中にできること →
/// あとから引き出せること → 使う準備 → AI の準備」の順で使い方を伝え、権限と AI の準備をしてもらう。
/// 設定の「使い方と権限を確認」からも同じ画面を再表示できるので、権限・AI の準備状態を
/// 見直す画面としても機能する。各ページの絵は WelcomeIllustrations.swift にまとめている。
struct WelcomeView: View {
    /// Window("ようこそ", id: windowID) の id。設定画面から再表示させる際の契約になる。
    static let windowID = "welcome"
    private static let hasShownWelcomeKey = "hasShownWelcome"

    /// 自動オープン時に前面化するための参照。WindowAccessor が解決した直後に入る。
    /// LSUIElement アプリはウィンドウを開いただけでは前面に来ない
    /// (AppModel.bringToFrontLater と同じ事情)ため、自分で activate を打つ必要がある。
    private static weak var openedWindow: NSWindow?

    /// Apple Intelligence の SF Symbol が使えない macOS では sparkles に落とす。
    /// NSImage の解決可否で確かめる(存在しないシンボル名を Image に渡しても
    /// クラッシュはしないが、意図せず空アイコンになるため事前に確認する)。
    private static let appleIntelligenceSymbol: String = {
        NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil) != nil
            ? "apple.intelligence" : "sparkles"
    }()

    /// オンボーディングのページ。宣言順に進む。
    private enum Page: Int, CaseIterable {
        case welcome, start, during, after, permissions, ai
    }

    /// ロゴの色をウィンドウの外観に合わせるために見る。
    @Environment(\.colorScheme) private var colorScheme
    /// 「はじめる」で自分のウィンドウを閉じるのに使う。NSWindow 参照 (WindowAccessor) は
    /// 解決前に押されると空振りするため、閉じる操作はこちらを正とする。
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var window: NSWindow?
    @State private var page: Page = .welcome
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var calendarStatus = EKEventStore.authorizationStatus(for: .event)
    /// AI ページの CLI 検出結果。nil は未検出。
    @State private var cliAvailability: [AgentCLI: Bool] = [:]
    @State private var detectingCLIs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch page {
                case .welcome: welcomePage
                case .start: startPage
                case .during: duringPage
                case .after: afterPage
                case .permissions: permissionsPage
                case .ai: aiPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(page)
            .transition(.opacity)
            footer
        }
        .padding(28)
        .frame(width: 480, height: 520)
        .background(WindowAccessor { resolved in
            window = resolved
            Self.openedWindow = resolved
        })
        // ウィンドウが再びキーになった (例: システム設定で許可してから戻ってきた) タイミングで
        // 状態を読み直す。scenePhase ではなく NSWindow の通知を使うのは、
        // このウィンドウ自体のフォーカス復帰だけを確実に拾いたいため。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window, (note.object as? NSWindow) === window else { return }
            reloadStatuses()
        }
    }

    // MARK: - ページ1: ようこそ

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                // アプリアイコンの猫と同じ白系にする(シナモンだと「アイコンと違う色」になる)。
                // ライトモードでは白が地に沈むので、アイコンの地と同じネイビーに落とす。
                HCLogoShape()
                    .fill(colorScheme == .dark ? HCColor.mistWhite : HCColor.navy)
                    .frame(width: 36, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("HearCat へようこそ")
                        .font(HCFont.style(.title2, weight: .semibold))
                    Text("メニューバーに住む、会話の記録係です。")
                        .font(HCFont.callout)
                        .foregroundStyle(.secondary)
                }
            }
            WelcomeTranscriptIllustration()
            pageBody("会議や通話の音声を録音しながら、リアルタイムで文字起こしします。自分の発言も相手の発言も、あとから読み返せます。")
        }
    }

    // MARK: - ページ2: 始め方はこれだけ

    private var startPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageTitle("始め方はこれだけ")
            WelcomeStartIllustration()
            pageBody("メニューバーの猫のアイコンをクリックし、オレンジのボタンを押すと記録が始まります。会議が終わったら、同じ場所にある停止ボタンを押します。")
            pageNote("右隣のボタンで、録音だけ・文字起こしだけに切り替えられます。")
        }
    }

    // MARK: - ページ3: 会議中にできること

    private var duringPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageTitle("会議中にできること")
            WelcomeDuringIllustration()
            pageBody("話した内容はリアルタイムで文字起こしされます。聞き逃したことや、ここまでの要点は、会議の途中でも AI に質問できます。回答に付いた時刻をクリックすると、元の発言へ移動できます。")
            pageNote("AI への質問は Claude Code か Codex が必要です。あとのページで確認します。")
        }
    }

    // MARK: - ページ4: 終わったあとは、AI が要約を作る

    private var afterPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageTitle("終わったあとは、AI が要約を作る")
            WelcomeAfterIllustration()
            pageBody("セッションを停止すると、HearCat が会議全体の要約を作ります。会議で決まったことは要約とは別に議題ごとに記録され、あとの会議で変わったときも経緯を辿れます。履歴から開いて、文字検索をしたり、文字起こしの時刻をクリックしてその場面の録音を再生したりできます。")
        }
    }

    // MARK: - ページ5: 使う準備

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            pageTitle("使う準備")
            pageBody("文字起こしには、3 つの許可が必要です。")
            VStack(spacing: 10) {
                permissionRow(
                    icon: "mic.fill",
                    title: "マイク",
                    required: true,
                    detail: "自分の声を録音・文字起こしするために使います。",
                    state: rowState(for: micStatus),
                    onRequest: requestMic,
                    onOpenSettings: { openSystemSettings(pane: "Privacy_Microphone") })
                permissionRow(
                    icon: "waveform",
                    title: "音声認識",
                    required: true,
                    detail: "録音した音声を文字に変換する macOS の機能です。",
                    state: rowState(for: speechStatus),
                    onRequest: requestSpeech,
                    onOpenSettings: { openSystemSettings(pane: "Privacy_SpeechRecognition") })
                staticPermissionRow(
                    icon: "speaker.wave.2",
                    title: "システム音声",
                    required: true,
                    detail: "通話相手など、Mac から出る音を録音するために使います。初めて記録を始めるときに macOS が確認するので「許可」を選んでください。",
                    onOpenSettings: { openSystemSettings(pane: "Privacy_AudioCapture") })
                permissionRow(
                    icon: "calendar",
                    title: "カレンダー",
                    required: false,
                    detail: "予定の名前をセッション名に付けたり、会議の時間に自動で記録を始めたりするために使います。",
                    state: rowState(for: calendarStatus),
                    onRequest: requestCalendar,
                    onOpenSettings: { openSystemSettings(pane: "Privacy_Calendars") })
            }
            pageNote("許可はあとからシステム設定でいつでも変えられます。")
        }
    }

    // MARK: - ページ6: AI の準備

    private var aiPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            pageTitle("AI の準備")
            pageBody("要約は Apple Intelligence・Claude Code・Codex のどれかが作ります。AI への質問は Claude Code か Codex が必要です。")
            VStack(spacing: 10) {
                aiRow(
                    icon: Self.appleIntelligenceSymbol,
                    title: "Apple Intelligence",
                    detail: "要約をこの Mac の中だけで作ります。",
                    status: appleIntelligenceStatus)
                aiRow(
                    icon: "terminal",
                    title: "Claude Code",
                    detail: "要約と、AI への質問に使えます。",
                    status: cliStatus(for: .claude))
                aiRow(
                    icon: "terminal",
                    title: "Codex",
                    detail: "要約と、AI への質問に使えます。",
                    status: cliStatus(for: .codex))
            }
            pageNote("どれも無くても、録音と文字起こしは使えます。あとから入れたときは「もう一度探す」を押してください。")
            HStack(spacing: 8) {
                Button("もう一度探す") { Task { await detectCLIs() } }
                    .buttonStyle(.hcSecondaryCompact)
                Button("設定を開く") { AppModel.shared.showSettings(page: .ai) }
                    .buttonStyle(.hcSecondaryCompact)
            }
        }
        // ページ切替でこの View が作り直されるたび(body の .id(page))に1回だけ検出する。
        .task { await detectCLIs() }
    }

    private var appleIntelligenceStatus: AIStatus {
        if let reason = OnDeviceModel.unavailableReason() {
            return .unavailable(reason: reason)
        }
        return .ok
    }

    private func cliStatus(for cli: AgentCLI) -> AIStatus {
        guard let available = cliAvailability[cli] else {
            return detectingCLIs ? .checking : .unavailable(reason: nil)
        }
        return available ? .ok : .unavailable(reason: nil)
    }

    private func detectCLIs() async {
        // 検出中に「もう一度探す」を押す・AI ページへ戻るなどで多重に呼ばれても、
        // AgentCLIResolver.resolve が並走してスピナーが点滅しないようにする。
        guard !detectingCLIs else { return }
        detectingCLIs = true
        var found: [AgentCLI: Bool] = [:]
        for cli in AgentCLI.allCases {
            found[cli] = await AgentCLIResolver.resolve(cli) != nil
        }
        cliAvailability = found
        detectingCLIs = false
        // パネルの「AI に質問」ボタンの出現を早める(見つからなければ何もしない)。
        AgentCLIDetector.shared.detectIfNeeded()
    }

    // MARK: - 共通のページ文言

    private func pageTitle(_ text: String) -> some View {
        Text(text)
            .font(HCFont.style(.title3, weight: .semibold))
    }

    /// ページ本文の1〜2段落。
    private func pageBody(_ text: String) -> some View {
        Text(text)
            .font(HCFont.callout)
            .foregroundStyle(HCColor.textDim)
            .lineSpacing(3)
    }

    /// 本文より一段控えめな注記。
    private func pageNote(_ text: String) -> some View {
        Text(text)
            .font(HCFont.caption)
            .foregroundStyle(HCColor.textDeeper)
    }

    // MARK: - footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { dot in
                    Circle()
                        .fill(dot == page ? HCColor.cinnamon : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                if page != .welcome {
                    Button("戻る") { move(by: -1) }
                        .buttonStyle(.hcSecondary)
                }
                if page == .ai {
                    Button("はじめる") { beginFromMenuBar() }
                        .buttonStyle(.hcPrimary)
                } else {
                    Button("次へ") { move(by: 1) }
                        .buttonStyle(.hcPrimary)
                }
            }
        }
    }

    private func move(by offset: Int) {
        guard let next = Page(rawValue: page.rawValue + offset) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            page = next
        }
    }

    // MARK: - 権限行

    private enum RowState { case granted, notDetermined, denied }

    /// AI 行の状態。checking は検出中、unavailable の reason はオンデバイスの不可理由
    /// (説明の下に表示)。CLI 側は理由文を持たないため nil で「見つかりません」を出す。
    private enum AIStatus {
        case checking
        case ok
        case unavailable(reason: String?)
    }

    private func rowState(for status: AVAuthorizationStatus) -> RowState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private func rowState(for status: SFSpeechRecognizerAuthorizationStatus) -> RowState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// .writeOnly (書き込みはできるが予定を読めない) も denied と同じ扱いにする。
    /// 予定名の自動付与・自動開始のどちらも予定の読み取りが要るため、
    /// CalendarAccess.authorizedStore が nil を返すのと基準を揃える。
    private func rowState(for status: EKAuthorizationStatus) -> RowState {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// 必須/任意のバッジ。必須はアクセント色で目立たせ、任意はグレーで控えめにする。
    private func requirementBadge(required: Bool) -> some View {
        Text(required ? "必須" : "任意")
            .font(HCFont.badge)
            .foregroundStyle(required ? HCColor.cinnamon : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(
                required ? HCColor.cinnamon.opacity(0.16) : Color.secondary.opacity(0.12)))
    }

    private func permissionRow(
        icon: String, title: String, required: Bool, detail: String, state: RowState,
        onRequest: @escaping () -> Void, onOpenSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(HCFont.callout)
                        .foregroundStyle(HCColor.cinnamon)
                        .frame(width: 20)
                    Text(title)
                        .font(HCFont.callout)
                        .fontWeight(.semibold)
                    requirementBadge(required: required)
                }
                Text(detail)
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
            }
            Spacer(minLength: 12)
            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notDetermined:
                Button("許可を求める", action: onRequest)
                    .buttonStyle(.hcSecondaryCompact)
            case .denied:
                Button("システム設定を開く", action: onOpenSettings)
                    .buttonStyle(.hcSecondaryCompact)
            }
        }
    }

    /// 状態を問い合わせる API が無い権限(システム音声)用の行。permissionRow と見た目を
    /// 揃えつつ、チェックマークや「許可を求める」は出さず、設定を開くボタンだけを置く。
    private func staticPermissionRow(
        icon: String, title: String, required: Bool, detail: String,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(HCFont.callout)
                        .foregroundStyle(HCColor.cinnamon)
                        .frame(width: 20)
                    Text(title)
                        .font(HCFont.callout)
                        .fontWeight(.semibold)
                    requirementBadge(required: required)
                }
                Text(detail)
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
            }
            Spacer(minLength: 12)
            Button("システム設定を開く", action: onOpenSettings)
                .buttonStyle(.hcSecondaryCompact)
        }
    }

    /// AI ページの1行。理由文はタイトルの説明の下、状態(チェック/検出中/未検出)は右側に出す。
    private func aiRow(icon: String, title: String, detail: String, status: AIStatus) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(HCFont.callout)
                        .foregroundStyle(HCColor.cinnamon)
                        .frame(width: 20)
                    Text(title)
                        .font(HCFont.callout)
                        .fontWeight(.semibold)
                }
                Text(detail)
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
                if case .unavailable(let reason?) = status {
                    Text(reason)
                        .font(HCFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }
            }
            Spacer(minLength: 12)
            aiStatusIndicator(status)
        }
    }

    @ViewBuilder
    private func aiStatusIndicator(_ status: AIStatus) -> some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unavailable(let reason):
            if reason == nil {
                Text("見つかりません")
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reloadStatuses() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    private func requestSpeech() {
        SFSpeechRecognizer.requestAuthorization { _ in
            DispatchQueue.main.async {
                speechStatus = SFSpeechRecognizer.authorizationStatus()
            }
        }
    }

    private func requestCalendar() {
        Task {
            _ = await CalendarAccess.authorizedStore()
            await MainActor.run {
                calendarStatus = EKEventStore.authorizationStatus(for: .event)
            }
        }
    }

    /// 「はじめる」。ようこそを閉じ、メニューバーの猫を実際にクリックしてパネルを開く
    /// (「始め方はこれだけ」で案内した操作をそのまま代わりにやってあげる)。
    /// SwiftUI の MenuBarExtra にはプログラムから開く口が無いため、ステータスバーの
    /// ボタンを探して performClick する。見つからなければ従来どおり閉じるだけ。
    private func beginFromMenuBar() {
        dismissWindow(id: Self.windowID)
        // ようこそが閉じ切る前にパネルを開くと、フォーカス移動で即閉じされ得るため1サイクル待つ。
        DispatchQueue.main.async {
            for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
                guard let button = Self.statusButton(in: window.contentView) else { continue }
                button.performClick(nil)
                return
            }
        }
    }

    /// ステータスバーのウィンドウから NSStatusBarButton を探す。
    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = statusButton(in: sub) { return found }
        }
        return nil
    }

}

extension WelcomeView {
    /// 初回起動なら準備画面を開いて前面化する。二度目以降は何もしない
    /// (フラグを先に立ててから開くので、開いている途中に何度呼ばれても再オープンしない)。
    /// メニューバーの猫アイコンが最初に描画されるタイミング (openWindowAction の注入と同じ) から呼ぶ。
    static func presentIfFirstLaunch(openWindow: OpenWindowAction) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: hasShownWelcomeKey) else { return }
        defaults.set(true, forKey: hasShownWelcomeKey)
        openWindow(id: windowID)
        // WindowAccessor がウィンドウを解決するまで数サイクルかかるため、
        // AppModel.bringToFrontLater と同じく時間差で2回 activate を打って確実に前面へ出す。
        for delay in [0.15, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.activate()
                openedWindow?.makeKeyAndOrderFront(nil)
                openedWindow?.orderFrontRegardless()
            }
        }
    }
}
