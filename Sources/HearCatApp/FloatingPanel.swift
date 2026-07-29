import AppKit
import SwiftUI

/// 会議中に手前へ出す非アクティブパネルの共通の作り。
///
/// 会議を邪魔しないための性質をここに集約する。
/// - 会議アプリからフォーカスを奪わない(.nonactivatingPanel)
/// - フルスクリーンの会議アプリや別の操作スペースの上にも出る
/// - 枠と背景は SwiftUI 側で描くため、AppKit 側は透過にしてタイトルバーを隠す
///
/// 閉じるボタンを付けないのは意図的。Cmd+W や × が NSPanel の close() を直接呼ぶと、
/// 各パネルが持つ後片付け(実行中の処理の取り消しなど)を素通りするため、
/// 閉じる導線は各コントローラ側に持たせる。
@MainActor
enum FloatingPanel {
    static func make(size: NSSize, title: String, content: some View) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentViewController = NSHostingController(
            rootView: content.environment(\.colorScheme, .dark))
        // contentViewController を載せるとウィンドウの大きさは中身に合わせて決まる。
        // 位置決めの前に確定させておかないと、枠(タイトルバー分)を数えそこねてずれる。
        panel.setContentSize(size)
        return panel
    }

    /// 画面の右上に置くときの原点。画面は呼び出し側が選ぶ
    /// (どの画面に出すべきかは、そのパネルが何をきっかけに出るかで変わるため)。
    static func topRightOrigin(
        of panel: NSPanel, in screen: NSScreen, margin: CGFloat
    ) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.maxX - panel.frame.width - margin,
            y: visible.maxY - panel.frame.height - margin)
    }
}
