import Foundation
import Testing

@testable import HearCatKit

/// 画面録画(.mov)が SessionInfo.Artifact を回す各経路で意図どおりに扱われるかの検証。
/// 保存先を差し替えるため、SessionPackageTests と同じ Suite に置いて直列に走らせる
/// (別 Suite にすると rootDirectory の差し替えが競合する)。
extension SessionPackageTests {
    private func makeVideoTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearCatTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func withVideoTemporaryStore(_ body: (URL) throws -> Void) throws {
        let temp = try makeVideoTemporaryDirectory()
        SessionStore.rootDirectory = temp
        defer {
            SessionStore.rootDirectory = SessionStore.defaultRootDirectory
            try? FileManager.default.removeItem(at: temp)
        }
        try body(temp)
    }

    /// 文字起こし・録音(100 バイト)・画面録画(videoBytes)を持つセッションを作る。
    private func makeSessionWithVideo(
        startDate: Date, name: String, videoBytes: Int
    ) throws -> SessionInfo {
        let dir = try SessionStore.createSessionDirectory(startDate: startDate, name: name)
        let dirName = dir.lastPathComponent
        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("\(dirName).md"))
        try Data(repeating: 2, count: 100).write(to: dir.appendingPathComponent("\(dirName).m4a"))
        try Data(repeating: 3, count: videoBytes).write(to: dir.appendingPathComponent("\(dirName).mov"))
        return SessionInfo(id: dirName, directory: dir, startDate: startDate, name: name, folder: nil)
    }

    @Test func 画面録画の名前はディレクトリ名に連動し旧形式の固定名でも探せる() throws {
        #expect(SessionInfo.Artifact.video.fileName(inDirectoryNamed: "2026-01-01_090000") == "2026-01-01_090000.mov")
        #expect(SessionInfo.Artifact.video.portableFileName == "video.mov")
        #expect(SessionInfo.Artifact.video.isVideo)
        #expect(!SessionInfo.Artifact.video.isAudio)
        #expect(SessionInfo.Artifact.allCases.filter(\.isVideo) == [.video])
    }

    @Test func 容量集計は録音側に画面録画を含める() throws {
        try withVideoTemporaryStore { _ in
            try makeSessionWithVideo(startDate: Date(), name: "会議", videoBytes: 5000)
            let usage = SessionStore.storageUsage()
            #expect(usage.audioBytes == 5100)
            #expect(usage.otherBytes == 10)
        }
    }

    @Test func 古い録音の削除は画面録画も対象にし文字起こしは残す() throws {
        try withVideoTemporaryStore { _ in
            let old = try makeSessionWithVideo(
                startDate: Date().addingTimeInterval(-100 * 86_400), name: "古い会議", videoBytes: 5000)
            let recent = try makeSessionWithVideo(
                startDate: Date().addingTimeInterval(-10 * 86_400), name: "最近の会議", videoBytes: 7000)

            let summary = SessionStore.oldRecordingsSummary(olderThanDays: 90)
            #expect(summary.sessionCount == 1)
            #expect(summary.bytes == 5100)

            let freed = SessionStore.deleteOldRecordings(olderThanDays: 90)
            #expect(freed == 5100)
            #expect(old.videoURL == nil)
            #expect(old.audioURL == nil)
            #expect(old.transcriptURL != nil)
            #expect(recent.videoURL != nil)
            #expect(recent.audioURL != nil)
        }
    }

    @Test func 画面録画だけのセッションも古い録音として数える() throws {
        try withVideoTemporaryStore { _ in
            let dir = try SessionStore.createSessionDirectory(
                startDate: Date().addingTimeInterval(-100 * 86_400), name: "録画のみ")
            try Data(repeating: 3, count: 4000)
                .write(to: dir.appendingPathComponent("\(dir.lastPathComponent).mov"))

            let summary = SessionStore.oldRecordingsSummary(olderThanDays: 90)
            #expect(summary.sessionCount == 1)
            #expect(summary.bytes == 4000)
        }
    }

    @Test func リネームは画面録画も新しい名前へ移す() throws {
        try withVideoTemporaryStore { _ in
            let session = try makeSessionWithVideo(startDate: Date(), name: "旧名", videoBytes: 50)
            let renamed = try SessionStore.rename(session, to: "新名")

            let video = try #require(renamed.videoURL)
            #expect(video.lastPathComponent == "\(renamed.directory.lastPathComponent).mov")
            #expect(renamed.audioURL != nil)
        }
    }

    @Test func 受け渡しパッケージには画面録画を含めず取り込みでも受け付けない() throws {
        try withVideoTemporaryStore { temp in
            let session = try makeSessionWithVideo(startDate: Date(), name: "会議", videoBytes: 50)
            let package = temp.appendingPathComponent("out.hearcat")

            try SessionPackage.export(session, includeAudio: true, to: package)
            let opened = try SessionPackage.open(package)
            #expect(opened.session.audioURL != nil)
            #expect(opened.session.videoURL == nil)

            // 細工されたパッケージに画面録画が入っていても、取り込み先には置かない。
            try Data(repeating: 9, count: 20)
                .write(to: opened.session.directory.appendingPathComponent("video.mov"))
            let installed = try SessionPackage.install(opened, intoFolder: nil)
            #expect(installed.videoURL == nil)
            #expect(installed.audioURL != nil)
        }
    }
}
