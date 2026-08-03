import Foundation
import Testing

@testable import HearCatKit

/// ストレージ管理(合計使用量・古い録音の削除)の検証。
///
/// SessionStore.rootDirectory を差し替える点で SessionPackageTests と同じ土俵を使うため、
/// 独立した @Suite にはせず SessionPackageTests の extension として定義する。
/// .serialized は同一 Suite 内の直列化しか保証せず、別 Suite にすると並列実行時に
/// rootDirectory の差し替えが競合してしまう(実測: 本物の Application Support の
/// セッション一覧が SessionPackageTests 側に混ざって失敗した)。
extension SessionPackageTests {
    private var storageTestDay: TimeInterval { 24 * 60 * 60 }

    private func makeStorageTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearCatTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 保存先を一時ディレクトリへ差し替えて body を実行し、必ず元へ戻す。
    /// withTemporaryStore(SessionPackageTests 側)と同じ役割を、可視性の都合で
    /// このファイル内に独自に持つ。
    private func withTemporaryStorageStore(_ body: (URL) throws -> Void) throws {
        let temp = try makeStorageTempDirectory()
        SessionStore.rootDirectory = temp
        defer {
            SessionStore.rootDirectory = SessionStore.defaultRootDirectory
            try? FileManager.default.removeItem(at: temp)
        }
        try body(temp)
    }

    /// 指定した開始日時のセッションを1件作り、録音・文字起こしを指定サイズで置く。
    @discardableResult
    private func makeStorageSession(
        startDate: Date, name: String, audioBytes: Int, transcriptBytes: Int = 32
    ) throws -> SessionInfo {
        let dir = try SessionStore.createSessionDirectory(startDate: startDate, name: name)
        let dirName = dir.lastPathComponent
        try Data(repeating: 0xAB, count: transcriptBytes)
            .write(to: dir.appendingPathComponent("\(dirName).md"))
        if audioBytes > 0 {
            try Data(repeating: 0xCD, count: audioBytes)
                .write(to: dir.appendingPathComponent("\(dirName).m4a"))
        }
        return SessionInfo(
            id: dirName, directory: dir, startDate: startDate, name: name, folder: nil)
    }

    // MARK: - storageUsage

    @Test func 合計使用量が録音とそれ以外に分かれて集計される() throws {
        try withTemporaryStorageStore { _ in
            try makeStorageSession(
                startDate: Date(), name: "会議A", audioBytes: 1000, transcriptBytes: 100)
            try makeStorageSession(
                startDate: Date(), name: "会議B", audioBytes: 2000, transcriptBytes: 50)

            let usage = SessionStore.storageUsage()

            #expect(usage.audioBytes == 3000)
            #expect(usage.otherBytes == 150)
            #expect(usage.totalBytes == 3150)
        }
    }

    @Test func セッションが無ければ使用量はゼロ() throws {
        try withTemporaryStorageStore { _ in
            let usage = SessionStore.storageUsage()
            #expect(usage.totalBytes == 0)
        }
    }

    // MARK: - oldRecordingsSummary / deleteOldRecordings

    @Test func 指定日数より古い録音だけが削除対象として集計される() throws {
        try withTemporaryStorageStore { _ in
            // 90日より古い(対象)。
            try makeStorageSession(
                startDate: Date().addingTimeInterval(-100 * storageTestDay), name: "古い会議",
                audioBytes: 5000)
            // 90日以内(対象外)。
            try makeStorageSession(
                startDate: Date().addingTimeInterval(-10 * storageTestDay), name: "最近の会議",
                audioBytes: 3000)

            let summary = SessionStore.oldRecordingsSummary(olderThanDays: 90)

            #expect(summary.sessionCount == 1)
            #expect(summary.bytes == 5000)
        }
    }

    @Test func 録音の無い古いセッションは削除対象件数に数えない() throws {
        try withTemporaryStorageStore { _ in
            try makeStorageSession(
                startDate: Date().addingTimeInterval(-100 * storageTestDay), name: "録音なし",
                audioBytes: 0)

            let summary = SessionStore.oldRecordingsSummary(olderThanDays: 90)

            #expect(summary.sessionCount == 0)
            #expect(summary.bytes == 0)
        }
    }

    @Test func 古い録音を削除すると文字起こしは残り新しい録音は消えない() throws {
        try withTemporaryStorageStore { _ in
            let old = try makeStorageSession(
                startDate: Date().addingTimeInterval(-100 * storageTestDay), name: "古い会議",
                audioBytes: 5000, transcriptBytes: 40)
            let recent = try makeStorageSession(
                startDate: Date().addingTimeInterval(-10 * storageTestDay), name: "最近の会議",
                audioBytes: 3000, transcriptBytes: 40)

            let freed = SessionStore.deleteOldRecordings(olderThanDays: 90)

            #expect(freed == 5000)
            // 古いセッション: 録音は消え、文字起こしは残る。
            #expect(old.audioURL == nil)
            #expect(
                FileManager.default.fileExists(
                    atPath: old.directory.appendingPathComponent(
                        "\(old.directory.lastPathComponent).md"
                    ).path))
            // 最近のセッション: 録音はそのまま。
            #expect(
                FileManager.default.fileExists(
                    atPath: recent.directory.appendingPathComponent(
                        "\(recent.directory.lastPathComponent).m4a"
                    ).path))
        }
    }

    // MARK: - フォルダの並び順(folder-order.json)

    @Test func 並び順を指定するとその通りにlistFoldersが返す() throws {
        try withTemporaryStorageStore { _ in
            try SessionStore.createFolder("A")
            try SessionStore.createFolder("B")
            try SessionStore.createFolder("C")

            SessionStore.setFolderOrder(["C", "A", "B"])

            #expect(SessionStore.listFolders() == ["C", "A", "B"])
        }
    }

    @Test func 並び順に無い新規フォルダはアルファベット順で末尾に付く() throws {
        try withTemporaryStorageStore { _ in
            try SessionStore.createFolder("A")
            try SessionStore.createFolder("B")
            SessionStore.setFolderOrder(["B", "A"])

            // 並び順を決めた後で新規フォルダを作る。
            try SessionStore.createFolder("D")
            try SessionStore.createFolder("C")

            #expect(SessionStore.listFolders() == ["B", "A", "C", "D"])
        }
    }

    @Test func 並び順に実体の無いフォルダ名が残っていても無視される() throws {
        try withTemporaryStorageStore { _ in
            try SessionStore.createFolder("A")
            try SessionStore.createFolder("B")

            SessionStore.setFolderOrder(["幽霊", "B", "A"])

            #expect(SessionStore.listFolders() == ["B", "A"])
        }
    }

    @Test func フォルダ改名後も並び順の位置が保たれる() throws {
        try withTemporaryStorageStore { _ in
            try SessionStore.createFolder("A")
            try SessionStore.createFolder("B")
            try SessionStore.createFolder("C")
            SessionStore.setFolderOrder(["C", "A", "B"])

            _ = try SessionStore.renameFolder("A", to: "Z")

            #expect(SessionStore.listFolders() == ["C", "Z", "B"])
        }
    }

    @Test func フォルダ削除で並び順から消える() throws {
        try withTemporaryStorageStore { _ in
            try SessionStore.createFolder("A")
            try SessionStore.createFolder("B")
            try SessionStore.createFolder("C")
            SessionStore.setFolderOrder(["C", "A", "B"])

            try SessionStore.deleteFolder("A")

            #expect(SessionStore.listFolders() == ["C", "B"])
        }
    }
}
