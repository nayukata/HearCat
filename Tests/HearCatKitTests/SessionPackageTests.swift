import Foundation
import Testing

@testable import HearCatKit

/// セッションの受け渡し(.hearcat)の検証。
/// 保存先(SessionStore.rootDirectory)をテスト用の一時ディレクトリへ差し替えて、
/// 実際に出荷される経路(export → open → install)をそのまま通す。
/// 差し替えは全テストで共有する1つの変数なので、直列に走らせる。
@Suite(.serialized)
struct SessionPackageTests {
    private let startDate = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 00:00:00 UTC

    // MARK: - 検証用の一時セッション

    /// テスト用の一時ディレクトリ。呼び出し側が最後に消す。
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearCatTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 保存先を一時ディレクトリへ差し替えて body を実行し、必ず元へ戻す。
    /// 本番の保存先(Application Support)には一切触れない。
    private func withTemporaryStore(_ body: (URL) throws -> Void) throws {
        let temp = try makeTempDirectory()
        SessionStore.rootDirectory = temp
        defer {
            SessionStore.rootDirectory = SessionStore.defaultRootDirectory
            try? FileManager.default.removeItem(at: temp)
        }
        try body(temp)
    }

    /// 保存済みセッションを模したディレクトリを作る。ファイル名の規則は実物と同じ
    /// (ディレクトリ名と同じ基底名 + 拡張子)。
    private func makeSession(
        in parent: URL, name: String = "定例", withAudio: Bool = true, withSummary: Bool = true
    ) throws -> SessionInfo {
        let dirName = "2026-01-01_090000 \(name)"
        let dir = parent.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "自分: おはよう\n相手: おはようございます\n"
            .write(to: dir.appendingPathComponent("\(dirName).md"), atomically: true, encoding: .utf8)
        if withAudio {
            try Data(repeating: 0xAB, count: 2048)
                .write(to: dir.appendingPathComponent("\(dirName).m4a"))
        }
        if withSummary {
            try "## 概要\n朝の挨拶をした。\n"
                .write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            try SummaryEngine.claude.rawValue
                .write(to: dir.appendingPathComponent("summary.engine"), atomically: true, encoding: .utf8)
        }
        return SessionInfo(
            id: dirName, directory: dir, startDate: startDate, name: name, folder: nil)
    }

    // MARK: - 書き出しと取り込みの往復

    @Test func 録音つきで書き出すと文字起こしと要約と録音が揃って取り込まれる() throws {
        try withTemporaryStore { temp in
            let session = try makeSession(in: temp)
            let package = temp.appendingPathComponent("out.hearcat")

            try SessionPackage.export(session, includeAudio: true, to: package)
            let opened = try SessionPackage.open(package)

            #expect(opened.manifest.sessionName == "定例")
            #expect(opened.manifest.summaryEngine == SummaryEngine.claude.rawValue)
            #expect(opened.transcriptCharacterCount > 0)
            // 開いた時点で、保存済みセッションと同じ API から中身を引ける。
            #expect(opened.session.audioURL != nil)
            #expect(opened.session.summaryURL != nil)

            let imported = try SessionPackage.install(opened, intoFolder: nil)
            #expect(imported.name == "定例")
            #expect(imported.transcriptURL != nil)
            #expect(imported.audioURL != nil)
            #expect(imported.summaryURL != nil)
            #expect(imported.summaryEngine == .claude)
            let text = try String(contentsOf: #require(imported.transcriptURL), encoding: .utf8)
            #expect(text.contains("おはようございます"))
            // 一覧からも同じ1件として見える。
            #expect(SessionStore.list().map(\.id) == [imported.id])
        }
    }

    @Test func 録音を含めない指定なら音声は入らず文字起こしだけが渡る() throws {
        try withTemporaryStore { temp in
            let session = try makeSession(in: temp)
            let package = temp.appendingPathComponent("out.hearcat")

            try SessionPackage.export(session, includeAudio: false, to: package)
            let opened = try SessionPackage.open(package)
            #expect(opened.session.audioURL == nil)
            #expect(!opened.manifest.includesAudio)
            #expect(opened.audioDuration == nil)

            let imported = try SessionPackage.install(opened, intoFolder: nil)
            #expect(imported.transcriptURL != nil)
            #expect(imported.audioURL == nil)
        }
    }

    @Test func 指定したグループへ取り込まれ一覧にもそのグループで並ぶ() throws {
        try withTemporaryStore { temp in
            var session = try makeSession(in: temp)
            session = SessionInfo(
                id: session.id, directory: session.directory, startDate: session.startDate,
                name: session.name, folder: "プロジェクトA")
            let package = temp.appendingPathComponent("out.hearcat")

            try SessionPackage.export(session, includeAudio: false, to: package)
            let opened = try SessionPackage.open(package)
            // 書き出した側のグループ名は、取り込み先の候補として残る。
            #expect(opened.manifest.folder == "プロジェクトA")

            let imported = try SessionPackage.install(opened, intoFolder: "受け取り")
            #expect(imported.folder == "受け取り")
            #expect(SessionStore.listFolders() == ["受け取り"])
            #expect(SessionStore.list().first?.folder == "受け取り")
        }
    }

    @Test func 同じセッションを二度取り込んでも既存のファイルは壊れない() throws {
        try withTemporaryStore { temp in
            let session = try makeSession(in: temp)
            let package = temp.appendingPathComponent("out.hearcat")
            try SessionPackage.export(session, includeAudio: false, to: package)

            let first = try SessionPackage.install(SessionPackage.open(package), intoFolder: nil)
            let second = try SessionPackage.install(SessionPackage.open(package), intoFolder: nil)

            #expect(first.directory != second.directory)
            #expect(second.name == "定例 (2)")
            // 2件が別のセッションとして並び、1件目の中身も残っている。
            #expect(SessionStore.list().count == 2)
            #expect(first.transcriptURL != nil)
            #expect(second.transcriptURL != nil)
        }
    }

    @Test func 日時形式のグループ名は取り込み先として受け付けない() throws {
        try withTemporaryStore { temp in
            let session = try makeSession(in: temp)
            let package = temp.appendingPathComponent("out.hearcat")
            try SessionPackage.export(session, includeAudio: false, to: package)
            let opened = try SessionPackage.open(package)
            defer { opened.discard() }

            // セッションと見分けが付かない名前でグループを作らせない
            // (作れてしまうと list() がそれをセッションとして読み、一覧が崩れる)。
            #expect(throws: SessionStore.StoreError.self) {
                _ = try SessionPackage.install(opened, intoFolder: "2026-01-01_090000")
            }
            #expect(SessionStore.list().isEmpty)
        }
    }

    // MARK: - 壊れた・細工されたパッケージ

    @Test func HearCatのファイルでなければ素性が無いとして弾く() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        // manifest.json を含まない普通の zip。
        let source = temp.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hello".write(
            to: source.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let package = temp.appendingPathComponent("other.hearcat")
        _ = try? Process.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", source.path, package.path]) { $0.waitUntilExit() }

        #expect(throws: SessionPackage.PackageError.self) {
            _ = try SessionPackage.open(package)
        }
    }

    @Test func 文字起こしも録音も無いパッケージは取り込ませない() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let session = try makeSession(in: temp, withAudio: false)
        // 文字起こしを消してから書き出すと export 自体が拒む。
        try FileManager.default.removeItem(at: #require(session.transcriptURL))

        #expect(throws: SessionPackage.PackageError.self) {
            try SessionPackage.export(
                session, includeAudio: false, to: temp.appendingPathComponent("out.hearcat"))
        }
    }

    @Test func 未知のファイルとシンボリックリンクは取り込まない() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        // 細工された展開結果を模す: 想定外のファイルと、外部を指すシンボリックリンク。
        let staging = temp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "本文".write(
            to: staging.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try "悪意".write(
            to: staging.appendingPathComponent("payload.sh"), atomically: true, encoding: .utf8)
        let secret = temp.appendingPathComponent("secret.txt")
        try "見えてはいけない".write(to: secret, atomically: true, encoding: .utf8)
        // summary.md という既知の名前でも、実体がシンボリックリンクなら受け入れない。
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("summary.md"), withDestinationURL: secret)

        let destination = temp.appendingPathComponent("2026-01-01_090000 取り込み", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try SessionPackage.moveKnownEntries(from: staging, to: destination)

        let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(contents == ["2026-01-01_090000 取り込み.md"])
        // シンボリックリンクは残ったまま(移されていない)で、リンク先も無事。
        #expect(try String(contentsOf: secret, encoding: .utf8) == "見えてはいけない")
    }

    // MARK: - 取り込み先の名前決め

    @Test func 取り込み先の名前がぶつからなければそのまま使う() {
        let resolved = SessionStore.uniqueSessionDirectoryName(
            startDate: startDate, name: "定例", existingNames: [])
        #expect(resolved.name == "定例")
        #expect(resolved.directoryName.hasSuffix(" 定例"))
    }

    @Test func 同じセッションを二度取り込んでも既存を上書きしない() {
        let first = SessionStore.uniqueSessionDirectoryName(
            startDate: startDate, name: "定例", existingNames: [])
        let second = SessionStore.uniqueSessionDirectoryName(
            startDate: startDate, name: "定例", existingNames: [first.directoryName])
        #expect(second.name == "定例 (2)")
        #expect(second.directoryName != first.directoryName)

        let third = SessionStore.uniqueSessionDirectoryName(
            startDate: startDate, name: "定例",
            existingNames: [first.directoryName, second.directoryName])
        #expect(third.name == "定例 (3)")
    }

    @Test func 名前の無いセッションが衝突したら日時に接尾辞を足す() {
        let first = SessionStore.uniqueSessionDirectoryName(
            startDate: startDate, name: "", existingNames: [])
        let second = SessionStore.uniqueSessionDirectoryName(
            startDate: startDate, name: "", existingNames: [first.directoryName])
        #expect(second.directoryName == "\(first.directoryName) (2)")
    }
}
