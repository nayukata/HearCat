import AppKit
import AVFoundation
import EventKit
import HearCatKit
import Speech
import SwiftUI

/// 初回起動時に一度だけ出すオンボーディング。数ページでアプリの姿と使い方を伝え、
/// 権限の準備をしてもらう。
struct WelcomeView: View {
    /// Window("ようこそ", id: windowID) の id。設定画面から再表示させる際の契約になる。
    static let windowID = "welcome"
    private static let hasShownWelcomeKey = "hasShownWelcome"

    /// 自動オープン時に前面化するための参照。WindowAccessor が解決した直後に入る。
    /// LSUIElement アプリはウィンドウを開いただけでは前面に来ない
    /// (AppModel.bringToFrontLater と同じ事情)ため、自分で activate を打つ必要がある。
    private static weak var openedWindow: NSWindow?

    /// オンボーディングのページ。宣言順に進む。
    private enum Page: Int, CaseIterable {
        case welcome, features, permissions, firstStep
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch page {
                case .welcome: welcomePage
                case .features: featuresPage
                case .permissions: permissionsPage
                case .firstStep: firstStepPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(page)
            .transition(.opacity)
            footer
        }
        .padding(28)
        .frame(width: 460, height: 440)
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

    // MARK: - ページ

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
            Text("自分の声 (マイク) と相手の声 (システム音声) をその場で文字にしながら、録音として残します。オンライン会議や通話の内容を、あとから文字と音声の両方で見返せます。")
                .font(HCFont.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HearCat にできること")
                .font(HCFont.style(.title3, weight: .semibold))
            VStack(alignment: .leading, spacing: 14) {
                featureRow(
                    icon: "waveform",
                    title: "リアルタイム文字起こし",
                    detail: "自分と相手の発言を、話者付きでその場で文字にします。")
                featureRow(
                    icon: "clock.arrow.circlepath",
                    title: "録音と履歴",
                    detail: "会話は録音ごと保存。あとから全文検索して聞き直せます。")
                featureRow(
                    icon: "folder",
                    title: "グループで整理",
                    detail: "会議や案件ごとにグループへ分けて保存。同じ予定の会議は、次から自動で同じグループに入ります。")
                featureRow(
                    icon: "sparkles",
                    title: "AI 要約",
                    detail: "終わった会話の要点を AI にまとめて、短く見返せます。")
                featureRow(
                    icon: "calendar.badge.clock",
                    title: "会議の自動開始",
                    detail: "カレンダーの会議の予定に合わせて、自動で記録を始められます。")
            }
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("使う準備")
                .font(HCFont.style(.title3, weight: .semibold))
            VStack(spacing: 10) {
                permissionRow(
                    icon: "mic.fill",
                    title: "マイク",
                    required: true,
                    detail: "自分の声を文字にするために使います。",
                    state: rowState(for: micStatus),
                    onRequest: requestMic,
                    onOpenSettings: { openSystemSettings(pane: "Privacy_Microphone") })
                permissionRow(
                    icon: "waveform",
                    title: "音声認識",
                    required: true,
                    detail: "話した内容を文字に変換するために使います。",
                    state: rowState(for: speechStatus),
                    onRequest: requestSpeech,
                    onOpenSettings: { openSystemSettings(pane: "Privacy_SpeechRecognition") })
                permissionRow(
                    icon: "calendar",
                    title: "カレンダー",
                    required: false,
                    detail: "会議の予定名を自動で付けたり、開始時刻に録音を始めたりするために使います。",
                    state: rowState(for: calendarStatus),
                    onRequest: requestCalendar,
                    onOpenSettings: { openSystemSettings(pane: "Privacy_Calendars") })
            }
            Text("権限はあとからシステム設定でいつでも変更できます。")
                .font(HCFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var firstStepPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最初の一歩")
                .font(HCFont.style(.title3, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                stepRow(number: 1, text: "メニューバーの猫のアイコンをクリックします。")
                stepRow(number: 2, text: "「録音 ＋ 文字起こしを開始」を押すと記録が始まります。")
                stepRow(number: 3, text: "記録した会話は、メニューの「履歴」からいつでも見返せます。")
            }
            if let hotkey = AppSettings.shared.hotkeys[.toggleSession] {
                Text("ショートカットキー (\(hotkey.display)) でも開始できます。")
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        // ベースライン揃えは記号ごとの微妙なベースライン差で揃わなかったため、
        // アイコンはタイトル行と中央揃えにし、説明はインデントで下に置く。
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
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(HCFont.style(.callout, weight: .semibold))
                .foregroundStyle(HCColor.cinnamon)
                .frame(width: 20)
            Text(text)
                .font(HCFont.callout)
                .foregroundStyle(.secondary)
        }
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
                if page == .firstStep {
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
    /// (「最初の一歩」で案内した操作をそのまま代わりにやってあげる)。
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
