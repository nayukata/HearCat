import AppKit
import HearCatKit
import UniformTypeIdentifiers

/// セッション受け渡しファイル(.hearcat)の保存/選択パネル。
/// 呼び出しと文言を1箇所に集約する(ReferenceFolderPicker と同じ役割)。
enum SessionPackagePicker {
    /// Info.plist(UTExportedTypeDeclarations)で宣言した書類型。
    /// 拡張子から引き直す(UTType(filenameExtension:))と、同じ拡張子を主張する別アプリの
    /// 宣言を掴む余地があるため、必ず自分の識別子から引く。まだ Launch Services へ
    /// 登録されていない場合(署名前のビルド等)に備えて、動的な型で受ける。
    static let contentType = UTType(SessionPackage.typeIdentifier)
        ?? UTType(exportedAs: SessionPackage.typeIdentifier, conformingTo: .data)

    /// 書き出し先を選ばせる。取りやめたら nil。
    @MainActor
    static func chooseDestination(for session: SessionInfo, from window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "セッションを書き出す"
        panel.message = "HearCat を使っている相手が、このファイルを開くとそのまま取り込めます。"
        panel.nameFieldStringValue =
            "\(SessionPackage.suggestedFileName(for: session)).\(SessionPackage.fileExtension)"
        panel.allowedContentTypes = [contentType]
        // Finder のタグ欄は出さない。相手へ渡したら役目が終わる一時的なファイルで、
        // 手元で分類する対象ではない(既定では保存パネルに必ず出てくる)。
        panel.showsTagField = false
        return await FilePanel.present(panel, from: window) == .OK ? panel.url : nil
    }

    /// 取り込むファイルを選ばせる。取りやめたら空。
    @MainActor
    static func chooseFiles(from window: NSWindow?) async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "セッションを取り込む"
        panel.message = "HearCat から書き出したファイル (.hearcat) を選んでください。"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [contentType]
        return await FilePanel.present(panel, from: window) == .OK ? panel.urls : []
    }

    /// 受け取った URL のうち、取り込みの対象になるものだけ。
    /// Finder から渡される URL は拡張子しか手がかりが無いことがあるため、型と拡張子の
    /// どちらかが一致すれば受け入れる。
    static func packages(in urls: [URL]) -> [URL] {
        urls.filter { url in
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                type.conforms(to: contentType) {
                return true
            }
            return url.pathExtension.lowercased() == SessionPackage.fileExtension
        }
    }
}
