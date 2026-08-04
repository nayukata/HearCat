import AppKit

/// ファイルの選択・保存パネルの出し方を1箇所に集約する。
///
/// 単独のウィンドウとして出す(runModal をそのまま呼ぶ)と、macOS がその時々の都合で
/// 位置を決めるため、操作したウィンドウとは別のディスプレイに現れることがある。
/// 呼び出し元のウィンドウが分かるならシートとして貼り付け、分からない場合でも
/// 今フォーカスのあるスクリーンへ寄せる。
enum FilePanel {
    /// パネルを出して、閉じられるまで待つ。
    /// window にはパネルを貼り付ける親を渡す。メニューバーのパネルや、質問応答パネル
    /// (CodeImpactOverlayController、会議アプリの手前に出す非アクティブパネル)のように、
    /// フォーカスが移ると閉じてしまう・シートを貼るのに適さないウィンドウは親にできないため
    /// nil を渡すこと。
    @MainActor
    static func present(
        _ panel: NSSavePanel, from window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        guard let window else {
            // 親が無い場合の保険。panel.center() はまだ画面に出したことのないウィンドウに
            // 対しては「メイン画面(メニューバーのある画面)」を基準に置くため、作業中の
            // ディスプレイがそれと異なるマルチディスプレイ環境では、呼び出し元から離れた
            // 画面にパネルが現れてしまう(質問応答パネルからの資料フォルダ紐付けで実際に
            // 再発した不具合)。マウスカーソルのある画面(取得できなければメイン画面)を
            // 基準に明示配置する(CodeImpactOverlayController.positionNearTopRight() と
            // 同じ考え方)。
            positionOnMouseScreen(panel)
            return panel.runModal()
        }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    /// マウスカーソルのある画面の visibleFrame の中央へパネルを置く。
    /// 対象の画面が取れない場合だけ、従来どおり center() (メイン画面基準)に任せる。
    @MainActor
    private static func positionOnMouseScreen(_ panel: NSSavePanel) {
        guard let screen = NSScreen.hcScreenWithMouse else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }
}
