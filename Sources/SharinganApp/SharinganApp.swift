import AppKit
import SwiftUI

@main
struct SharinganApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // 稼働中は塗りつぶしの目(写輪眼が開いている)で示す。
            Image(systemName: model.status.active ? "eye.fill" : "eye")
        }

        Window("sharingan", id: "main") {
            MainWindow(model: model)
        }
        .defaultSize(width: 960, height: 640)
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
