import AppKit
import HearCatKit

/// グループ(セッション整理のプロジェクトフォルダ)の関連フォルダ(エージェント要約が
/// 用語・固有名詞の確認のために読み取り参照するディレクトリ)を選ばせる共通処理。
/// MainWindow(グループの右クリックメニュー)、SessionDetailView(要約メニュー)、
/// MenuPanel(録音開始前のグループ選択)の3箇所から同じ動きで呼べるよう、NSOpenPanel の
/// 呼び出しと保存をここに集約する。「紐付けるとどう良くなるか」の説明もこの1箇所に
/// 集約し、呼び出し側ごとに文言を重複させない。
enum ReferenceFolderPicker {
    /// 既に選択済みのグループへ紐付ける版(MainWindow のグループ右クリック、
    /// SessionDetailView の要約メニュー、MenuPanel でグループ選択中の場合)。
    @MainActor
    static func pick(forGroup folder: String) {
        let panel = makePanel(
            message: "「\(folder)」に紐付ける資料やコードのフォルダを選んでください。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.shared.referenceFolders[folder] = url.path
    }

    /// 未分類から呼ぶ版。選んだフォルダの lastPathComponent をグループ名にして新しい
    /// グループを作り(同名の未紐付けグループがあれば新規に作らず流用する。名前の
    /// 衝突回避は SessionStore.resolveFolderName 参照)、そのフォルダを紐付けてから
    /// 確定したグループ名を onCreate へ渡す。作ったグループを既定にするか(MenuPanel)、
    /// 今のセッションをそこへ移すか(SessionDetailView)は呼び出し側に委ね、ここでは
    /// 「フォルダを選んだらグループが副産物としてできる」ところまでだけを担う。
    @MainActor
    static func pickForNewGroup(onCreate: @escaping (String) -> Void) {
        let panel = makePanel(
            message: "資料やコードのフォルダを選んでください。選んだ名前でグループを作成します。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let settings = AppSettings.shared
        let existingFolders = SessionStore.listFolders()
        let name = SessionStore.resolveFolderName(
            candidate: url.lastPathComponent, selectedPath: url.path,
            existingFolders: existingFolders, referenceFolders: settings.referenceFolders)
        if !existingFolders.contains(name) {
            // 候補名が(接尾辞込みで)未使用な場合だけ新規に作る。名前が日時形式と
            // 衝突する等、稀にグループ名として使えず作成に失敗することがあるが、
            // その場合は紐付け自体を諦める(中途半端な状態を残さない)。
            guard (try? SessionStore.createFolder(name)) != nil else { return }
        }
        settings.referenceFolders[name] = url.path
        onCreate(name)
    }

    @MainActor
    private static func makePanel(message: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        panel.message = message
        return panel
    }
}
