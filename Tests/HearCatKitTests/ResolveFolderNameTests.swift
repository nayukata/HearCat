import Foundation
import Testing

@testable import HearCatKit

/// 資料フォルダ紐付け(未分類からの新規グループ作成)で使うグループ名衝突回避ロジックの検証。
/// 「フォルダを選んだらグループが副産物としてできる」導線で、同名グループが既にある場合に
/// 意図しない上書きや無意味な重複グループを作らないことを保証する。
struct ResolveFolderNameTests {
    @Test func 同名グループが無ければ候補名をそのまま使う() {
        let name = SessionStore.resolveFolderName(
            candidate: "プロジェクトA", selectedPath: "/Users/x/docs",
            existingFolders: [], referenceFolders: [:])
        #expect(name == "プロジェクトA")
    }

    @Test func 同名グループはあるが未紐付けなら候補名のまま流用する() {
        let name = SessionStore.resolveFolderName(
            candidate: "プロジェクトA", selectedPath: "/Users/x/docs",
            existingFolders: ["プロジェクトA"], referenceFolders: [:])
        #expect(name == "プロジェクトA")
    }

    @Test func 同名グループが同じパスへ紐付け済みなら候補名のまま再利用する() {
        let name = SessionStore.resolveFolderName(
            candidate: "プロジェクトA", selectedPath: "/Users/x/docs",
            existingFolders: ["プロジェクトA"],
            referenceFolders: ["プロジェクトA": "/Users/x/docs"])
        #expect(name == "プロジェクトA")
    }

    @Test func 同名グループが別パスへ紐付け済みなら接尾辞を振って避ける() {
        let name = SessionStore.resolveFolderName(
            candidate: "プロジェクトA", selectedPath: "/Users/x/docs-new",
            existingFolders: ["プロジェクトA"],
            referenceFolders: ["プロジェクトA": "/Users/x/docs-old"])
        #expect(name == "プロジェクトA-2")
    }

    @Test func 接尾辞候補も埋まっていれば空いている番号まで進める() {
        let name = SessionStore.resolveFolderName(
            candidate: "プロジェクトA", selectedPath: "/Users/x/docs-new",
            existingFolders: ["プロジェクトA", "プロジェクトA-2", "プロジェクトA-3"],
            referenceFolders: ["プロジェクトA": "/Users/x/docs-old"])
        #expect(name == "プロジェクトA-4")
    }

    @Test func 接尾辞候補が同じ資料フォルダに紐付いていれば再利用する() {
        // 過去に別 path のせいで作られた「プロジェクトA-2」がまさに今選んだ path に
        // 紐付いていれば、新規に「プロジェクトA-3」を作らず既存の A-2 を返す。
        // 選び直すたびに Foo-2, Foo-3, Foo-4 … と増え続けるのを避ける。
        let name = SessionStore.resolveFolderName(
            candidate: "プロジェクトA", selectedPath: "/Users/x/docs-new",
            existingFolders: ["プロジェクトA", "プロジェクトA-2"],
            referenceFolders: [
                "プロジェクトA": "/Users/x/docs-old",
                "プロジェクトA-2": "/Users/x/docs-new",
            ])
        #expect(name == "プロジェクトA-2")
    }
}
