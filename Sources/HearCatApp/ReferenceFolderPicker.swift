import AppKit

/// グループ(セッション整理のプロジェクトフォルダ)の関連フォルダ(エージェント要約が
/// 用語・固有名詞の確認のために読み取り参照するディレクトリ)を選ばせる共通処理。
/// MainWindow(グループの右クリックメニュー)と SessionDetailView(要約メニュー)の
/// 両方から同じ動きで呼べるよう、NSOpenPanel の呼び出しと保存をここに集約する。
enum ReferenceFolderPicker {
    @MainActor
    static func pick(forGroup folder: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        panel.message = "「\(folder)」の関連フォルダを選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.shared.referenceFolders[folder] = url.path
    }
}
