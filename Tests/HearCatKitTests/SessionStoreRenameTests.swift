import Foundation
import Testing

@testable import HearCatKit

/// SessionStore.rename(セッション名の変更に伴うディレクトリ・成果物のリネーム)の検証。
/// rootDirectory を差し替えず session.directory を直接渡すだけの API のため、
/// SessionPackageTests とは独立した一時ディレクトリで検証できる。
struct SessionStoreRenameTests {
    private let startDate = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 00:00:00 UTC

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearCatTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 文字起こしと録音を持つセッションを作る。ファイル名の規則は実物と同じ
    /// (ディレクトリ名と同じ基底名 + 拡張子)。
    private func makeSession(
        in parent: URL, name: String
    ) throws -> (session: SessionInfo, transcript: URL, audio: URL) {
        let dirName = "2026-01-01_090000 \(name)"
        let dir = parent.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = dir.appendingPathComponent("\(dirName).md")
        let audio = dir.appendingPathComponent("\(dirName).m4a")
        try "自分: おはよう\n".write(to: transcript, atomically: true, encoding: .utf8)
        try Data(repeating: 0xAB, count: 16).write(to: audio)
        let session = SessionInfo(
            id: dirName, directory: dir, startDate: startDate, name: name, folder: nil)
        return (session, transcript, audio)
    }

    @Test func 成果物の移動が途中で失敗すると元の名前へロールバックされる() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let (session, transcriptURL, audioURL) = try makeSession(in: temp, name: "旧名")
        let originalTranscriptData = try Data(contentsOf: transcriptURL)
        let originalAudioData = try Data(contentsOf: audioURL)

        // 2番目に移動する成果物(録音)の移動先へ、あらかじめ衝突するファイルを置いておく。
        let newDirName = "2026-01-01_090000 新名"
        let conflictingAudioDestination = session.directory.appendingPathComponent("\(newDirName).m4a")
        try Data([0x00]).write(to: conflictingAudioDestination)

        #expect(throws: (any Error).self) {
            _ = try SessionStore.rename(session, to: "新名")
        }

        // ディレクトリはリネームされず、成果物も元の名前・中身のまま残っている
        // (1番目に移動した文字起こしがロールバックで戻っていることを確認する)。
        #expect(FileManager.default.fileExists(atPath: session.directory.path))
        #expect(FileManager.default.fileExists(atPath: transcriptURL.path))
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        let transcriptDataAfter = try Data(contentsOf: transcriptURL)
        let audioDataAfter = try Data(contentsOf: audioURL)
        #expect(transcriptDataAfter == originalTranscriptData)
        #expect(audioDataAfter == originalAudioData)
    }
}
