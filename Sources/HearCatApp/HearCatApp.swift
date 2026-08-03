import AppKit
import HearCatKit
import SwiftUI

@main
struct HearCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    init() {
        HCFont.registerBundledFonts()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
                .environment(\.font, HCFont.body)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("HearCat", id: "main") {
            MainWindow(model: model)
                .tint(HCColor.cinnamon)
                .environment(\.font, HCFont.body)
        }
        .defaultSize(width: 960, height: 640)

        Window("HearCat の設定", id: "settings") {
            SettingsView(model: model, settings: AppSettings.shared)
                .tint(HCColor.cinnamon)
                .environment(\.font, HCFont.body)
                .background(WindowAccessor { window in
                    model.settingsWindow = window
                })
        }
        .windowResizability(.contentSize)

        Window("ようこそ", id: WelcomeView.windowID) {
            WelcomeView()
                .tint(HCColor.cinnamon)
                .environment(\.font, HCFont.body)
        }
        .windowResizability(.contentSize)
    }
}

/// メニューバーに出す猫アイコン。フレームは AppModel が状態に応じて回す
/// (待機中は静止、録音/文字起こし中はそれぞれのアニメーション)。
/// openWindow は SwiftUI の Environment からしか取れないため、
/// 常に生きているこのビューからモデルへ注入する(ホットキー等、ビューの外から使うため)。
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: model.menuIcon)
            // 異常が起きている間、猫アイコンに小さいバッジを重ねる。パネルを開かなくても
            // メニューバーを見るだけで気づけるようにする(バナー自体はパネルの中)。
            if !model.healthIssues.isEmpty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: -2)
            }
        }
        .onAppear {
            reportMenuBarState()
            model.openWindowAction = { id in openWindow(id: id) }
            WelcomeView.presentIfFirstLaunch(openWindow: openWindow)
        }
    }

    /// メニューバーに実際に居場所を得られたかを HEARCAT_DEBUG 時だけ記録する。
    /// 「アプリは動いているのにアイコンが見当たらない」を切り分ける唯一の手がかりで、
    /// メニューバー項目は他プロセス(コントロールセンター)が描くため外からは観測できない。
    /// ラベルの描画直後はまだ実体が載っていないので、1サイクル待ってから測る。
    private func reportMenuBarState() {
        guard hearcatDebug else { return }
        debugLog("メニューバーのラベルが描画された icon=\(model.menuIcon.size)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let statusWindows = NSApp.windows.filter { $0.className.contains("NSStatusBarWindow") }
            debugLog("ステータス項目の数=\(statusWindows.count)")
            for window in statusWindows {
                debugLog("ステータス項目 frame=\(window.frame) visible=\(window.isVisible)")
            }
        }
    }
}

/// 終了時にセッションを保存し切るためのフック。
/// 録音ファイル(m4a)は途中で殺されるとヘッダが確定せず壊れるため、必ず stop を通す。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder で .hearcat をダブルクリックした時などに呼ばれる。
    /// ここでは取り込まず、中身を確認する画面まで持っていく(他人の会話の録音が入り得るため、
    /// 何が入っているかを見せずに保存先へ書き込むことはしない)。
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.requestImport(of: urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.status.active else {
            Task { await model.shutdown() }
            return .terminateNow
        }
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
