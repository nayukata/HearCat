import AppKit
import SwiftUI

@main
struct HearCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("HearCat", id: "main") {
            MainWindow(model: model)
                .tint(HCColor.blue)
        }
        .defaultSize(width: 960, height: 640)

        Window("HearCat の設定", id: "settings") {
            SettingsView(model: model, settings: AppSettings.shared)
                .tint(HCColor.blue)
                .background(WindowAccessor { window in
                    model.settingsWindow = window
                })
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
        Image(nsImage: model.menuIcon)
            .onAppear {
                model.openWindowAction = { id in openWindow(id: id) }
            }
    }
}

/// 終了時にセッションを保存し切るためのフック。
/// 録音ファイル(m4a)は途中で殺されるとヘッダが確定せず壊れるため、必ず stop を通す。
final class AppDelegate: NSObject, NSApplicationDelegate {
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
