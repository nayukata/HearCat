import AppKit

/// ファイルの選択・保存パネルの出し方を1箇所に集約する。
///
/// 単独のウィンドウとして出す(runModal をそのまま呼ぶ)と、macOS がその時々の都合で
/// 位置を決めるため、操作したウィンドウとは別のディスプレイに現れることがある。
/// 呼び出し元のウィンドウが分かるならシートとして貼り付け、分からない場合でも
/// 今フォーカスのあるスクリーンへ寄せる。
enum FilePanel {
    /// パネルを出して、閉じられるまで待つ。
    /// window にはパネルを貼り付ける親を渡す。メニューバーのパネルのように、
    /// フォーカスが移ると閉じてしまうウィンドウは親にできないため nil を渡すこと。
    @MainActor
    static func present(
        _ panel: NSSavePanel, from window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        guard let window else {
            // 親が無い場合の保険。center() は「今キーウィンドウがあるスクリーン」を
            // 基準に置くため、作業中の画面から離れたディスプレイに出るのを避けられる。
            panel.center()
            return panel.runModal()
        }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
