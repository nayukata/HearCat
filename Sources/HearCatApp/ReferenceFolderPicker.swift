import AppKit

/// グループ(セッション整理のプロジェクトフォルダ)の関連フォルダ(エージェント要約が
/// 用語・固有名詞の確認のために読み取り参照するディレクトリ)を選ばせる共通処理。
/// MainWindow(グループの右クリックメニュー)、SessionDetailView(要約メニュー)、
/// MenuPanel(録音開始前のグループ選択)の3箇所から同じ動きで呼べるよう、NSOpenPanel の
/// 呼び出しと保存をここに集約する。「紐付けるとどう良くなるか」の説明もこの1箇所に
/// 集約し、呼び出し側ごとに文言を重複させない。
enum ReferenceFolderPicker {
    @MainActor
    static func pick(forGroup folder: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        panel.message = "「\(folder)」に資料やコードのフォルダを紐付けます。"
            + "次回以降、Claude / Codex による要約が用語・固有名詞や参加者の前提を踏まえた内容になり、精度が上がります。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.shared.referenceFolders[folder] = url.path
    }
}
