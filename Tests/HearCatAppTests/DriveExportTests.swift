import Foundation
import HearCatKit
import Testing

@testable import HearCatApp

/// 開くまで await を止める扉。
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if opened {
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// Drive 呼び出しの偽物。作成と更新の呼ばれ方を記録し、失敗や消失を差し込める。
final class FakeDriveAPI: DriveAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 1
    private(set) var folders: [String: String] = [:]  // "親/名前" -> id
    private(set) var files: [String: (name: String, parent: String)] = [:]  // id -> 名前と親
    private(set) var createdUploads: [String] = []  // 名前
    private(set) var updatedIDs: [String] = []
    /// ここに入れた ID の更新は notFound になる(Drive 上で消された)。
    var missingFileIDs: Set<String> = []
    /// ここに入れた ID の更新は成功するが trashed で返る。
    var trashedFileIDs: Set<String> = []
    /// ここに入れた名前の作成 / 更新は失敗する。
    var failingNames: Set<String> = []
    var failure: DriveError = .network("切断")
    /// 作成が「失敗と返したが実は届いていた」状態にする名前。
    var createLandsButFailsNames: Set<String> = []
    /// 次の createFolder だけ、作成は届いたのに失敗と返す。
    var folderCreateLandsButFailsOnce = false
    /// ここに入れた名前の作成は 1 回だけ失敗し、次からは通る。
    var failOnceNames: Set<String> = []
    /// 作成の直前で待たせる。転送の最中の状態を観察するのに使う。
    var gate: TestGate?

    private func newID(_ prefix: String) -> String {
        defer { nextID += 1 }
        return "\(prefix)\(nextID)"
    }

    func accountEmail() async throws -> String { "me@example.com" }

    func findFolder(name: String, parentID: String?) async throws -> String? {
        lock.withLock { folders["\(parentID ?? "root")/\(name)"] }
    }

    func createFolder(name: String, parentID: String?) async throws -> String {
        try lock.withLock {
            let id = newID("folder")
            folders["\(parentID ?? "root")/\(name)"] = id
            if folderCreateLandsButFailsOnce {
                folderCreateLandsButFailsOnce = false
                throw failure
            }
            return id
        }
    }

    func findFile(name: String, parentID: String) async throws -> String? {
        // 実物の検索と同じく、消された・ごみ箱に入ったものは見つからない。
        lock.withLock {
            files.first {
                $0.value.name == name && $0.value.parent == parentID
                    && !missingFileIDs.contains($0.key) && !trashedFileIDs.contains($0.key)
            }?.key
        }
    }

    func create(_ upload: DriveUpload, parentID: String) async throws -> DriveFileRef {
        await gate?.wait()
        return try lock.withLock {
            if failOnceNames.remove(upload.name) != nil { throw failure }
            if failingNames.contains(upload.name) { throw failure }
            let id = newID("file")
            files[id] = (upload.name, parentID)
            createdUploads.append(upload.name)
            if createLandsButFailsNames.remove(upload.name) != nil { throw failure }
            return DriveFileRef(id: id, trashed: false)
        }
    }

    /// 本文を送った更新(contentChanged が true)の ID。
    private(set) var bodyUpdatedIDs: [String] = []
    /// 本文なしで親だけ付け替えた ID。
    private(set) var moveOnlyIDs: [String] = []
    /// 本文も親も触らず、名前だけ直した ID。
    private(set) var renameOnlyIDs: [String] = []
    private(set) var trashedIDs: [String] = []
    /// true なら親の付け替えが権限で断られる(元の親のまま)。
    var moveForbidden = false

    func update(
        fileID: String, with upload: DriveUpload, parentID: String, contentChanged: Bool
    ) async throws -> DriveFileRef {
        try lock.withLock {
            if failingNames.contains(upload.name) { throw failure }
            if missingFileIDs.contains(fileID) { throw DriveError.notFound }
            updatedIDs.append(fileID)
            let trashed = trashedFileIDs.contains(fileID)
            if trashed { return DriveFileRef(id: fileID, trashed: true) }
            let oldParent = files[fileID]?.parent
            let needsMove = oldParent != parentID
            let moved = needsMove && !moveForbidden
            if contentChanged {
                bodyUpdatedIDs.append(fileID)
            } else if needsMove {
                moveOnlyIDs.append(fileID)
            } else if files[fileID]?.name != upload.name {
                renameOnlyIDs.append(fileID)
            }
            files[fileID] = (upload.name, moved ? parentID : (oldParent ?? parentID))
            return DriveFileRef(id: fileID, trashed: false, moveFailed: needsMove && moveForbidden)
        }
    }

    /// Drive 上で名前を変えられた状態にする。
    func rename(_ id: String, to name: String) {
        lock.withLock { files[id]?.name = name }
    }

    func trash(fileID: String) async throws {
        lock.withLock {
            trashedIDs.append(fileID)
            files[fileID] = nil
        }
    }
}

struct DriveExportTests {
    /// 偽のセッション(2026-01-01 00:00 UTC、名前「定例」)の書き出し名。日付はローカル時刻。
    private static func localDay(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    private static let sessionStart = Date(timeIntervalSince1970: 1_767_225_600)
    private static var summaryName: String { "\(localDay(sessionStart, "yyyy-MM-dd")) 定例 要約" }
    private static var transcriptName: String { "\(localDay(sessionStart, "yyyy-MM-dd")) 定例 文字起こし" }

    private func makeSession(folder: String? = "案件A", name: String = "定例") throws -> (SessionInfo, URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearCatDrive-\(UUID().uuidString)", isDirectory: true)
        let dirName = "2026-01-01_090000 定例"
        let dir = temp.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# 要約".write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "自分: おはよう".write(
            to: dir.appendingPathComponent("\(dirName).md"), atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 8).write(to: dir.appendingPathComponent("\(dirName).m4a"))
        let session = SessionInfo(
            id: dirName, directory: dir, startDate: Date(timeIntervalSince1970: 1_767_225_600),
            name: name, folder: folder)
        return (session, temp)
    }

    // MARK: - 純粋なロジック

    @Test func 自動書き出しの対象グループを判定する() {
        var target = DriveAutoExportTarget()
        #expect(target.includes(folder: nil))
        #expect(target.includes(folder: "案件A"))

        target.allGroups = false
        target.groups = ["案件A"]
        target.includesUnclassified = false
        #expect(target.includes(folder: "案件A"))
        #expect(!target.includes(folder: "案件B"))
        #expect(!target.includes(folder: nil))

        target.includesUnclassified = true
        #expect(target.includes(folder: nil))
    }

    @Test func グループの改名と削除に追従する() {
        var target = DriveAutoExportTarget(allGroups: false, groups: ["A", "B"], includesUnclassified: false)
        target.retarget(from: "A", to: "A2")
        #expect(target.groups == ["A2", "B"])
        target.retarget(from: "B", to: nil)
        #expect(target.groups == ["A2"])
        target.retarget(from: "未登録", to: "X")
        #expect(target.groups == ["A2"])
    }

    @Test func Drive上のパスを組み立てる() {
        #expect(
            DrivePaths.folderPath(group: "案件A", sessionDirectoryName: "2026-01-01_090000 定例")
                == ["HearCat（議事録）", "案件A", "2026-01-01_090000 定例"])
        #expect(
            DrivePaths.folderPath(group: nil, sessionDirectoryName: "2026-01-01_090000")
                == ["HearCat（議事録）", "未分類", "2026-01-01_090000"])
    }

    @Test func 書き出す中身の選択から種類を導く() {
        #expect(DriveContentSelection(summary: true, transcript: true, audio: false).kinds == [.summary, .transcript])
        #expect(
            DriveContentSelection(summary: false, transcript: false, audio: true).kinds
                == [.audio, .audioOther])
        #expect(DriveContentSelection(summary: false, transcript: false, audio: false).isEmpty)
    }

    @Test func 記録ファイルは読み書きできる() throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        #expect(DriveRecordStore.load(in: session.directory) == DriveRecord())

        var record = DriveRecord(folderID: "f1")
        record.set("a", for: .summary, fingerprint: nil)
        try DriveRecordStore.save(record, in: session.directory)
        #expect(DriveRecordStore.load(in: session.directory) == record)
        #expect(DriveRecordStore.url(in: session.directory).lastPathComponent == "drive.json")
    }

    @Test func 壊れた記録は空として読む() throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        try "{壊れた".write(to: DriveRecordStore.url(in: session.directory), atomically: true, encoding: .utf8)
        #expect(DriveRecordStore.load(in: session.directory) == DriveRecord())
    }

    @Test func PKCEの値はRFC7636の形式() {
        // RFC 7636 付録 B の例。
        #expect(
            PKCEPair.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pair = PKCEPair.generate()
        #expect((43...128).contains(pair.verifier.count))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(pair.verifier.unicodeScalars.allSatisfy(allowed.contains))
        #expect(pair.challenge == PKCEPair.challenge(for: pair.verifier))
        #expect(!pair.challenge.contains("=") && !pair.challenge.contains("+") && !pair.challenge.contains("/"))
        #expect(PKCEPair.generate().verifier != pair.verifier)
    }

    private func redirect(_ query: String) -> URL {
        URL(string: "\(GoogleOAuthConfig.redirectScheme):/oauth2redirect\(query)")!
    }

    @Test func カスタムスキームのリダイレクトURLを読む() {
        #expect(GoogleOAuthRedirect.parse(url: redirect("?state=s1&code=4%2Fabc"), expectedState: "s1") == .code("4/abc"))
        #expect(GoogleOAuthRedirect.parse(url: redirect("?state=s1&error=access_denied"), expectedState: "s1") == .denied("access_denied"))
        #expect(GoogleOAuthRedirect.parse(url: redirect("?state=s1"), expectedState: "s1") == .invalid)
    }

    @Test func stateが合わないか別のURLなら無視する() {
        #expect(GoogleOAuthRedirect.parse(url: redirect("?state=zzz&code=abc"), expectedState: "s1") == .invalid)
        #expect(GoogleOAuthRedirect.parse(url: redirect("?code=abc"), expectedState: "s1") == .invalid)
        // 別のスキーム・別のパスは、ログインの戻りとして扱わない。
        #expect(GoogleOAuthRedirect.parse(url: URL(string: "https://example.com/oauth2redirect?state=s1&code=abc")!, expectedState: "s1") == .invalid)
        #expect(GoogleOAuthRedirect.parse(url: URL(string: "\(GoogleOAuthConfig.redirectScheme):/other?state=s1&code=abc")!, expectedState: "s1") == .invalid)
    }

    @Test func リダイレクト窓口はログイン中だけ受け付ける() async throws {
        let center = GoogleLoginRedirectCenter()
        // 待っていないときに届いた URL は捨てる。
        #expect(!center.deliver(redirect("?state=s1&code=abc")))

        let waiting = Task { try await center.wait(state: "s1", timeout: 5) }
        for _ in 0..<20 { await Task.yield() }
        // state が違う URL は受け付けず、待ち続ける。
        #expect(!center.deliver(redirect("?state=other&code=bad")))
        #expect(center.deliver(redirect("?state=s1&code=good")))
        #expect(try await waiting.value == .code("good"))
        // 受け取った後に同じ URL が重ねて届いても無視する。
        #expect(!center.deliver(redirect("?state=s1&code=good")))
    }

    @Test func リダイレクト待ちは時間切れとキャンセルで終わる() async throws {
        let center = GoogleLoginRedirectCenter()
        await #expect(throws: GoogleOAuthError.self) {
            _ = try await center.wait(state: "s1", timeout: 0.05)
        }
        let waiting = Task { try await center.wait(state: "s2", timeout: 5) }
        for _ in 0..<20 { await Task.yield() }
        waiting.cancel()
        await #expect(throws: GoogleOAuthError.self) { _ = try await waiting.value }
        #expect(!center.deliver(redirect("?state=s2&code=late")))
    }

    @Test func 認可URLはPKCEと最小スコープを含みシークレットを含まない() {
        let url = GoogleLoginFlow.authorizationURL(state: "st", challenge: "ch")
        let items = Dictionary(
            uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(items["scope"] == "https://www.googleapis.com/auth/drive.file")
        #expect(items["code_challenge"] == "ch")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["redirect_uri"] == GoogleOAuthConfig.redirectURI)
        #expect(items["client_id"] == GoogleOAuthConfig.clientID)
        #expect(items["client_secret"] == nil)
        #expect(GoogleOAuthConfig.redirectScheme == "com.googleusercontent.apps." + GoogleOAuthConfig.clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: ""))
    }

    @Test func トークン要求にクライアントシークレットを含めない() {
        let fields = GoogleURLSessionTokenEndpoint.requestFields(
            ["grant_type": "refresh_token", "refresh_token": "r"], clientID: "id")
        #expect(fields["client_id"] == "id")
        #expect(fields["client_secret"] == nil)
        #expect(fields.count == 3)
    }

    @Test func InfoPlistにURLスキームが登録されている() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let plist = try Data(contentsOf: url.appendingPathComponent("Sources/HearCatApp/Info.plist"))
        let dict = try #require(try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        let types = try #require(dict["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(GoogleOAuthConfig.redirectScheme))
    }

    @Test func 受け渡しパッケージに書き出し記録は含めない() {
        #expect(SessionInfo.Artifact.driveRecord.isLocalOnly)
        #expect(SessionInfo.Artifact.allCases.filter(\.isLocalOnly) == [.driveRecord])
    }

    // MARK: - 書き出しの流れ(偽の Drive)

    @Test func 初回は新規作成し二回目は更新になる() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)

        let first = try await exporter.export(session: session, kinds: [.summary, .transcript])
        #expect(first.created == [.summary, .transcript])
        #expect(first.updated.isEmpty)
        #expect(api.createdUploads == [Self.summaryName, Self.transcriptName])

        let second = try await exporter.export(session: session, kinds: [.summary, .transcript])
        #expect(second.created.isEmpty)
        #expect(second.updated == [.summary, .transcript])
        // 新規作成は増えていない。
        #expect(api.createdUploads.count == 2)
        #expect(api.updatedIDs.count == 2)
    }

    @Test func ドキュメント名は日付とセッション名を前に付ける() throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let day = Self.localDay(Self.sessionStart, "yyyy-MM-dd")
        #expect(DriveContentKind.summary.driveName(fileName: "a.md", session: session) == "\(day) 定例 要約")
        #expect(DriveContentKind.transcript.driveName(fileName: "b.md", session: session) == "\(day) 定例 文字起こし")
        #expect(DriveContentKind.audio.driveName(fileName: "c.m4a", session: session) == "c.m4a")
    }

    @Test func セッション名が空なら日付のあとに開始時刻を入れる() throws {
        let (session, temp) = try makeSession(name: "")
        defer { try? FileManager.default.removeItem(at: temp) }
        let stamp = "\(Self.localDay(Self.sessionStart, "yyyy-MM-dd")) \(Self.localDay(Self.sessionStart, "HH:mm"))"
        #expect(DriveContentKind.summary.driveName(fileName: "", session: session) == "\(stamp) 要約")
        #expect(DriveContentKind.transcript.driveName(fileName: "", session: session) == "\(stamp) 文字起こし")
    }

    @Test func 古い名前のファイルは更新時に新しい名前になる() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary])
        let record = DriveRecordStore.load(in: session.directory)
        let id = try #require(record.fileID(for: .summary))
        api.rename(id, to: "要約")

        // 本文が同じでも、名前だけ直す。
        let outcome = try await exporter.export(session: session, kinds: [.summary])
        #expect(outcome.updated == [.summary])
        #expect(api.files[id]?.name == Self.summaryName)
        #expect(api.renameOnlyIDs == [id])
        #expect(api.bodyUpdatedIDs.isEmpty)
        #expect(api.createdUploads.count == 1)

        // 名前が合っていれば何も送らない。
        _ = try await exporter.export(session: session, kinds: [.summary])
        #expect(api.renameOnlyIDs == [id])
    }

    @Test func セッションの改名にも名前が追従する() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.transcript])
        let id = try #require(DriveRecordStore.load(in: session.directory).fileID(for: .transcript))
        let renamed = SessionInfo(
            id: session.id, directory: session.directory, startDate: session.startDate,
            name: "朝会", folder: session.folder)
        _ = try await exporter.export(session: renamed, kinds: [.transcript])
        #expect(api.files[id]?.name == "\(Self.localDay(Self.sessionStart, "yyyy-MM-dd")) 朝会 文字起こし")
        #expect(api.createdUploads.count == 1)
    }

    @Test func 記録が無くても古い名前の同名ファイルを再利用して名前を直す() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary])
        let id = try #require(DriveRecordStore.load(in: session.directory).fileID(for: .summary))
        api.rename(id, to: "要約")
        try FileManager.default.removeItem(at: DriveRecordStore.url(in: session.directory))

        let outcome = try await exporter.export(session: session, kinds: [.summary])
        #expect(outcome.updated == [.summary])
        #expect(outcome.created.isEmpty)
        #expect(api.createdUploads.count == 1)
        #expect(api.files[id]?.name == Self.summaryName)
    }

    // MARK: - 書き出し済みの判定

    private func exportedFixture(kinds: [DriveContentKind] = [.summary, .transcript]) async throws
        -> (SessionInfo, URL)
    {
        let (session, temp) = try makeSession()
        _ = try await DriveExporter(api: FakeDriveAPI()).export(session: session, kinds: kinds)
        return (session, temp)
    }

    private func upToDate(_ session: SessionInfo, kinds: [DriveContentKind] = [.summary, .transcript]) -> Bool {
        DriveExportedCheck.isUpToDate(
            record: DriveRecordStore.load(in: session.directory), kinds: kinds, session: session)
    }

    @Test func 書き出した直後は書き出し済みになる() async throws {
        let (session, temp) = try await exportedFixture()
        defer { try? FileManager.default.removeItem(at: temp) }
        #expect(upToDate(session))
        // 選ばれていない種類の記録が無くても関係しない。
        #expect(upToDate(session, kinds: [.summary]))
    }

    @Test func 書き出していなければ書き出し済みにならない() throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        #expect(!upToDate(session))
    }

    @Test func 選んだ中身に記録の無いものがあれば書き出し済みにならない() async throws {
        let (session, temp) = try await exportedFixture(kinds: [.summary])
        defer { try? FileManager.default.removeItem(at: temp) }
        #expect(!upToDate(session, kinds: [.summary, .transcript]))
    }

    @Test func 手元に実体の無い種類は判定から外す() async throws {
        let (session, temp) = try await exportedFixture(kinds: [.summary, .transcript])
        defer { try? FileManager.default.removeItem(at: temp) }
        // 録音は元から無い扱い(書き出していない)。実体の無い種類は記録が無くてもよい。
        try FileManager.default.removeItem(
            at: session.directory.appendingPathComponent("\(session.directory.lastPathComponent).m4a"))
        #expect(upToDate(session, kinds: [.summary, .transcript, .audio]))
    }

    @Test func 中身が変わったら書き出し済みにならない() async throws {
        let (session, temp) = try await exportedFixture()
        defer { try? FileManager.default.removeItem(at: temp) }
        try "# 変えた".write(
            to: session.directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        #expect(!upToDate(session))
    }

    @Test func グループかセッション名が変わったら書き出し済みにならない() async throws {
        let (session, temp) = try await exportedFixture()
        defer { try? FileManager.default.removeItem(at: temp) }
        let moved = SessionInfo(
            id: session.id, directory: session.directory, startDate: session.startDate,
            name: session.name, folder: "案件B")
        #expect(!upToDate(moved))
        let renamed = SessionInfo(
            id: session.id, directory: session.directory, startDate: session.startDate,
            name: "朝会", folder: session.folder)
        #expect(!upToDate(renamed))
    }

    @Test func 場所の記録が無い古い記録は書き出し済みにならない() async throws {
        let (session, temp) = try await exportedFixture()
        defer { try? FileManager.default.removeItem(at: temp) }
        var record = DriveRecordStore.load(in: session.directory)
        record.locations = nil
        try DriveRecordStore.save(record, in: session.directory)
        #expect(!upToDate(session))
    }

    @Test func 親の付け替えを断られたら書き出し済みにならない() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary])
        let moved = SessionInfo(
            id: session.id, directory: session.directory, startDate: session.startDate,
            name: session.name, folder: "案件B")
        api.moveForbidden = true
        _ = try await exporter.export(session: moved, kinds: [.summary])
        #expect(!DriveExportedCheck.isUpToDate(
            record: DriveRecordStore.load(in: session.directory), kinds: [.summary], session: moved))
    }

    @Test func フォルダは階層どおりに作り再利用する() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        _ = try await DriveExporter(api: api).export(session: session, kinds: [.summary])
        #expect(api.folders.count == 3)
        #expect(api.folders["root/\(DrivePaths.rootName)"] != nil)

        // 記録を消して別セッションとして出しても、HearCat と グループのフォルダは作り直さない。
        try? FileManager.default.removeItem(at: DriveRecordStore.url(in: session.directory))
        _ = try await DriveExporter(api: api).export(session: session, kinds: [.transcript])
        #expect(api.folders.count == 3)
    }

    @Test func 途中で失敗しても成功した種類だけ記録される() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        api.failingNames = [Self.transcriptName]

        let outcome = try await DriveExporter(api: api).export(
            session: session, kinds: [.summary, .transcript, .audio])
        #expect(outcome.created == [.summary, .audio])
        #expect(outcome.failures.keys.contains(.transcript))
        #expect(outcome.hasFailure)

        let record = DriveRecordStore.load(in: session.directory)
        #expect(record.fileID(for: .summary) != nil)
        #expect(record.fileID(for: .audio) != nil)
        #expect(record.fileID(for: .transcript) == nil)

        // 直ったあとの再実行で、失敗した分だけ新規になり、成功済みは更新になる。
        api.failingNames = []
        let retry = try await DriveExporter(api: api).export(
            session: session, kinds: [.summary, .transcript, .audio])
        #expect(retry.created == [.transcript])
        #expect(retry.updated == [.summary, .audio])
    }

    @Test func Drive上で消された更新先は作り直す() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary, .transcript])
        let before = DriveRecordStore.load(in: session.directory)
        api.missingFileIDs = [before.fileID(for: .summary)!]
        api.trashedFileIDs = [before.fileID(for: .transcript)!]

        let outcome = try await exporter.export(session: session, kinds: [.summary, .transcript])
        #expect(outcome.created == [.summary, .transcript])
        #expect(outcome.updated.isEmpty)
        let after = DriveRecordStore.load(in: session.directory)
        #expect(after.fileID(for: .summary) != before.fileID(for: .summary))
        #expect(after.fileID(for: .transcript) != before.fileID(for: .transcript))
    }

    @Test func 実体が無い中身は見送り失敗にはしない() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        // 相手側の録音は用意していない。
        let outcome = try await DriveExporter(api: FakeDriveAPI()).export(
            session: session, kinds: [.audio, .audioOther])
        #expect(outcome.created == [.audio])
        #expect(outcome.missing == [.audioOther])
        #expect(!outcome.hasFailure)
    }

    @Test func ログイン切れは残りを試さず止める() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        api.failingNames = [Self.summaryName]
        api.failure = .notSignedIn
        await #expect(throws: DriveError.notSignedIn) {
            _ = try await DriveExporter(api: api).export(session: session, kinds: [.summary, .transcript])
        }
        #expect(api.createdUploads.isEmpty)
    }

    @MainActor
    @Test func 同じセッションの同時実行は一本にまとまる() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let coordinator = DriveExportCoordinator { DriveExporter(api: api) }

        async let a = coordinator.export(session: session, kinds: [.summary])
        async let b = coordinator.export(session: session, kinds: [.summary])
        let results = await [a, b]
        #expect(results.allSatisfy { $0?.created == [.summary] })
        #expect(api.createdUploads == [Self.summaryName])
        #expect(!coordinator.isRunning(session))
        if case .finished = coordinator.state(for: session) {} else { Issue.record("完了状態になっていない") }
    }

    @MainActor
    @Test func 未ログインなら失敗として残る() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let coordinator = DriveExportCoordinator { nil }
        let outcome = await coordinator.export(session: session, kinds: [.summary])
        #expect(outcome == nil)
        #expect(coordinator.state(for: session) == .failed("Google Drive にログインし直してください"))
    }

    // MARK: - レビュー対応

    @Test func グループが変わったら既存ファイルを現在のフォルダへ移す() async throws {
        let (session, temp) = try makeSession(folder: "案件A")
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary])
        let id = DriveRecordStore.load(in: session.directory).fileID(for: .summary)!

        let moved = SessionInfo(
            id: session.id, directory: session.directory, startDate: session.startDate,
            name: session.name, folder: "案件B")
        let outcome = try await exporter.export(session: moved, kinds: [.summary])
        #expect(outcome.updated == [.summary])
        #expect(api.files[id]?.parent == outcome.folderID)
        #expect(DriveRecordStore.load(in: session.directory).folderID == outcome.folderID)
        // 同じファイルのまま。複製はされていない。
        #expect(api.createdUploads.count == 1)
    }

    @Test func 失敗しても作れたフォルダは記録に残る() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        api.failingNames = [Self.summaryName]
        let outcome = try await DriveExporter(api: api).export(session: session, kinds: [.summary])
        #expect(outcome.hasFailure)
        let record = DriveRecordStore.load(in: session.directory)
        #expect(record.folderID != nil)
        #expect(record.files.isEmpty)
    }

    @Test func 記録が無くても同名のファイルがあれば作らず使う() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary])
        try FileManager.default.removeItem(at: DriveRecordStore.url(in: session.directory))

        let outcome = try await exporter.export(session: session, kinds: [.summary])
        #expect(outcome.created.isEmpty)
        #expect(outcome.updated == [.summary])
        #expect(api.createdUploads == [Self.summaryName])
    }

    @Test func 作成が通信断で失敗しても届いていれば二重に作らない() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        api.createLandsButFailsNames = [Self.summaryName]
        let outcome = try await DriveExporter(api: api).export(session: session, kinds: [.summary])
        #expect(!outcome.hasFailure)
        #expect(api.createdUploads == [Self.summaryName])
        #expect(DriveRecordStore.load(in: session.directory).fileID(for: .summary) != nil)
    }

    @Test func フォルダ作成が通信断で失敗しても届いていれば二重に作らない() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        api.folderCreateLandsButFailsOnce = true
        _ = try await DriveExporter(api: api).export(session: session, kinds: [.summary])
        #expect(api.folders.count == 3)
    }

    @Test func 検索クエリは加算記号をエンコードする() {
        let query = GoogleDriveAPI.searchQuery(name: "C++ 定例", parentID: "p1", folder: true)
        #expect(query.contains("name = 'C++ 定例'"))
        let url = GoogleDriveAPI.searchURL(name: "C++ 定例", parentID: "p1", folder: true)
        let raw = url.absoluteString
        #expect(raw.contains("C%2B%2B"))
        #expect(!raw.contains("C++"))
        // 空白は + ではなく %20 にする。
        #expect(raw.contains("%20"))
        #expect(!raw.contains("+"))
        // 引用符はクエリ内でエスケープされる。
        #expect(GoogleDriveAPI.searchQuery(name: "O'Neil", parentID: nil, folder: false).contains("O\\'Neil"))
    }

    @Test func 利用制限の403は再試行対象になる() {
        let rate = Data(#"{"error":{"message":"Rate Limit Exceeded","errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8)
        let forbidden = Data(#"{"error":{"message":"no","errors":[{"reason":"insufficientFilePermissions"}]}}"#.utf8)
        #expect(GoogleDriveAPI.error(status: 403, data: rate).isTransient)
        #expect(!GoogleDriveAPI.error(status: 403, data: forbidden).isTransient)
        #expect(GoogleDriveAPI.error(status: 429, data: Data()).isTransient)
        #expect(GoogleDriveAPI.error(status: 503, data: Data()).isTransient)
        #expect(!GoogleDriveAPI.error(status: 400, data: Data()).isTransient)
        #expect(GoogleDriveAPI.error(status: 401, data: Data()) == .notSignedIn)
    }

    @MainActor
    @Test func 実行中に別の中身で呼ばれたら不足分だけ続けて実行する() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let coordinator = DriveExportCoordinator { DriveExporter(api: api) }

        async let a = coordinator.export(session: session, kinds: [.summary])
        async let b = coordinator.export(session: session, kinds: [.summary, .transcript])
        _ = await [a, b]
        // どちらの順で始まっても、各中身は 1 回ずつだけ作られる。
        #expect(Set(api.createdUploads) == [Self.summaryName, Self.transcriptName])
        #expect(api.createdUploads.count == 2)
        let record = DriveRecordStore.load(in: session.directory)
        #expect(record.fileID(for: .summary) != nil && record.fileID(for: .transcript) != nil)
    }

    @MainActor
    @Test func 終わったら実行中の表示が解ける() async throws {
        let (session, temp) = try makeSession(folder: "案件A")
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let coordinator = DriveExportCoordinator { DriveExporter(api: api) }
        #expect(!coordinator.isRunning(inFolder: "案件A"))
        _ = await coordinator.export(session: session, kinds: [.summary])
        #expect(!coordinator.isRunning(inFolder: "案件A"))
        #expect(!coordinator.isRunning(session))
    }

    private func moved(_ session: SessionInfo, to folder: String?) -> SessionInfo {
        SessionInfo(
            id: session.id, directory: session.directory, startDate: session.startDate,
            name: session.name, folder: folder)
    }

    @Test func 本文が変わらず親だけ違うときは本文を送らず移すだけにする() async throws {
        let (session, temp) = try makeSession(folder: "案件A")
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary, .audio])
        let ids = DriveRecordStore.load(in: session.directory)

        let outcome = try await exporter.export(session: moved(session, to: "案件B"), kinds: [.summary, .audio])
        #expect(outcome.updated == [.summary, .audio])
        #expect(Set(api.moveOnlyIDs) == [ids.fileID(for: .summary)!, ids.fileID(for: .audio)!])
        #expect(api.bodyUpdatedIDs.isEmpty)
        #expect(api.files[ids.fileID(for: .summary)!]?.parent == outcome.folderID)

        // 本文が変わったら、親が同じでも本文を送る。
        try "# 更新".write(
            to: session.directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        _ = try await exporter.export(session: moved(session, to: "案件B"), kinds: [.summary])
        #expect(api.bodyUpdatedIDs == [ids.fileID(for: .summary)!])
    }

    @Test func 古い記録に指紋が無ければ本文を送る() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary])
        var record = DriveRecordStore.load(in: session.directory)
        record.fingerprints = nil
        try DriveRecordStore.save(record, in: session.directory)
        _ = try await exporter.export(session: session, kinds: [.summary])
        #expect(api.bodyUpdatedIDs.count == 1)
        // 指紋の無い JSON もそのまま読める。
        let legacy = Data(#"{"files":{"summary":"x"},"folderID":"f"}"#.utf8)
        let decoded = try JSONDecoder().decode(DriveRecord.self, from: legacy)
        #expect(decoded.fileID(for: .summary) == "x" && decoded.fingerprints == nil)
    }

    @Test func 親の付け替えを権限で断られたら元のフォルダを指したままにする() async throws {
        let (session, temp) = try makeSession(folder: "案件A")
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        let first = try await exporter.export(session: session, kinds: [.summary])
        api.moveForbidden = true
        let outcome = try await exporter.export(session: moved(session, to: "案件B"), kinds: [.summary])
        #expect(outcome.folderID == first.folderID)
        #expect(DriveRecordStore.load(in: session.directory).folderID == first.folderID)
    }

    @Test func 記録のファイルをごみ箱へ移して記録を消す() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary, .transcript])
        let folderCount = api.folders.count
        let ids = DriveRecordStore.load(in: session.directory).files.values

        try await exporter.trashRecorded(session: moved(session, to: "対象外"))
        #expect(Set(api.trashedIDs) == Set(ids))
        #expect(!FileManager.default.fileExists(atPath: DriveRecordStore.url(in: session.directory).path))
        // 対象外のグループ名のフォルダは作らない。
        #expect(api.folders.count == folderCount)
        #expect(DriveRecordStore.load(in: session.directory).recordedKinds.isEmpty)
    }

    @Test func 記録のある種類を並べる() {
        var record = DriveRecord()
        record.set("a", for: .transcript, fingerprint: "x")
        record.set("b", for: .audio, fingerprint: nil)
        #expect(record.recordedKinds == [.transcript, .audio])
    }

    @Test func 権限系の403は移動だけ諦められ容量超過は諦められない() {
        let denied = Data(#"{"error":{"message":"no","errors":[{"reason":"insufficientFilePermissions"}]}}"#.utf8)
        let error = GoogleDriveAPI.error(status: 403, data: denied)
        #expect(error == .forbidden(reasons: ["insufficientFilePermissions"], message: "no"))
        #expect(GoogleDriveAPI.isPermissionFailure(["insufficientFilePermissions"]))
        #expect(!GoogleDriveAPI.isPermissionFailure(["storageQuotaExceeded"]))
        // 先頭が権限系でなくても、どれかが権限系なら対象。全部が対象外なら失敗として扱う。
        #expect(GoogleDriveAPI.isPermissionFailure(["storageQuotaExceeded", "cannotAddParent"]))
        #expect(!GoogleDriveAPI.isPermissionFailure([]))
        #expect(!GoogleDriveAPI.isPermissionFailure(["somethingElse"]))
    }

    @Test func 書き出しの印は自動か手動かを種類ごとに持ち手動が優先される() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary, .transcript], automatic: true)
        var record = DriveRecordStore.load(in: session.directory)
        #expect(record.isAutomatic(.summary) && record.isAutomatic(.transcript))

        // 手動で一度書いた種類は、あとで自動が書き直しても手動のまま。
        _ = try await exporter.export(session: session, kinds: [.summary], automatic: false)
        _ = try await exporter.export(session: session, kinds: [.summary, .transcript], automatic: true)
        record = DriveRecordStore.load(in: session.directory)
        #expect(!record.isAutomatic(.summary))
        #expect(record.isAutomatic(.transcript))

        // 印の無い古い記録は手動扱い。
        let legacy = Data(#"{"files":{"summary":"x"}}"#.utf8)
        #expect(!(try JSONDecoder().decode(DriveRecord.self, from: legacy)).isAutomatic(.summary))
    }

    @Test func 自動で書いた種類だけをごみ箱へ移す() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let exporter = DriveExporter(api: api)
        _ = try await exporter.export(session: session, kinds: [.summary], automatic: false)
        _ = try await exporter.export(session: session, kinds: [.transcript], automatic: true)
        let record = DriveRecordStore.load(in: session.directory)
        let autoKinds = record.recordedKinds.filter(record.isAutomatic)
        #expect(autoKinds == [.transcript])

        try await exporter.trashRecorded(session: session, kinds: autoKinds)
        #expect(api.trashedIDs == [record.fileID(for: .transcript)!])
        let after = DriveRecordStore.load(in: session.directory)
        #expect(after.recordedKinds == [.summary])
        #expect(FileManager.default.fileExists(atPath: DriveRecordStore.url(in: session.directory).path))
    }

    @MainActor
    @Test func 往復移動でIDの付け替えが輪にならない() {
        let coordinator = DriveExportCoordinator { nil }
        coordinator.retarget(from: "A/x", to: "B/x")
        coordinator.retarget(from: "B/x", to: "A/x")
        #expect(coordinator.currentID(following: "A/x") == "A/x")
        #expect(coordinator.currentID(following: "B/x") == "A/x")
        coordinator.retarget(from: "A/x", to: "C/x")
        #expect(coordinator.currentID(following: "B/x") == "C/x")
    }

    @MainActor
    @Test func 合流した側は完了直後に変わったIDで続きを実行する() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let renamed = SessionInfo(
            id: "新ID", directory: session.directory, startDate: session.startDate,
            name: session.name, folder: session.folder)
        let api = FakeDriveAPI()
        let coordinator = DriveExportCoordinator(
            lookup: { $0 == "新ID" ? renamed : nil }, makeExporter: { DriveExporter(api: api) })
        coordinator.onTransferFinished = { id, _, _, _ in
            coordinator.retarget(from: id, to: "新ID")
        }
        let first = Task { await coordinator.export(session: session, kinds: [.summary], automatic: true) }
        await Task.yield()
        let second = Task { await coordinator.export(session: session, kinds: [.summary, .transcript]) }
        _ = await first.value
        let merged = await second.value
        #expect(merged?.succeededCount == 2)
        #expect(coordinator.states["新ID"] != nil)
        #expect(coordinator.currentID(following: session.id) == "新ID")
        if case .finished = coordinator.state(forID: session.id) {} else { Issue.record("今のIDの状態を引けていない") }
    }

    @MainActor
    @Test func 自動の転送は手動の呼び出しが合流すると手動として終わる() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        let gate = TestGate()
        api.gate = gate
        let coordinator = DriveExportCoordinator { DriveExporter(api: api) }
        let log = FinishedLog()
        coordinator.onTransferFinished = { _, _, _, automatic in log.append("\(automatic)") }
        let first = Task { await coordinator.export(session: session, kinds: [.summary], automatic: true) }
        for _ in 0..<10 { await Task.yield() }
        let second = Task { await coordinator.export(session: session, kinds: [.summary]) }
        for _ in 0..<10 { await Task.yield() }
        gate.open()
        _ = await first.value
        _ = await second.value
        #expect(log.items == ["false"])
    }

    @MainActor
    @Test func 先の実行で失敗した中身は合流した呼び出しがやり直し結果は合わさる() async throws {
        let (session, temp) = try makeSession()
        defer { try? FileManager.default.removeItem(at: temp) }
        let api = FakeDriveAPI()
        api.failOnceNames = [Self.transcriptName]
        let coordinator = DriveExportCoordinator { DriveExporter(api: api) }

        async let a = coordinator.export(session: session, kinds: [.summary, .transcript])
        async let b = coordinator.export(session: session, kinds: [.transcript])
        let results = await [a, b]
        // 合流した側の結果は、先の失敗を取り下げた合算になる。
        #expect(results.contains { $0 != nil && $0?.hasFailure == false && $0?.succeededCount == 2 })
        #expect(Set(api.createdUploads) == [Self.summaryName, Self.transcriptName])
        if case .finished = coordinator.state(for: session) {} else { Issue.record("合算後は完了状態のはず") }
        let record = DriveRecordStore.load(in: session.directory)
        #expect(record.fileID(for: .summary) != nil && record.fileID(for: .transcript) != nil)
    }

    @Test func 結果の合算は後の成功が先の失敗を取り下げる() {
        let first = DriveExportOutcome(
            created: [.summary], failures: [.transcript: "切断"], folderID: "f1")
        let later = DriveExportOutcome(created: [.transcript], folderID: "f2")
        let merged = first.merging(later)
        #expect(merged.created == [.summary, .transcript])
        #expect(!merged.hasFailure)
        #expect(merged.folderID == "f2")
        let stillFailing = first.merging(DriveExportOutcome(failures: [.transcript: "また切断"]))
        #expect(stillFailing.failures[.transcript] == "また切断")
    }

    @MainActor
    @Test func 順番待ちの間は動かせず扱いにならず転送を始めたら扱いになる() async throws {
        let (a, tempA) = try makeSession()
        let (bBase, tempB) = try makeSession(folder: "案件B")
        defer {
            try? FileManager.default.removeItem(at: tempA)
            try? FileManager.default.removeItem(at: tempB)
        }
        let b = SessionInfo(
            id: "別の会議", directory: bBase.directory, startDate: bBase.startDate, name: "別", folder: "案件B")
        let api = FakeDriveAPI()
        let gate = TestGate()
        api.gate = gate
        let finished = FinishedLog()
        let coordinator = DriveExportCoordinator { DriveExporter(api: api) }
        coordinator.onTransferFinished = { id, kinds, completed, _ in
            finished.append("\(id):\(kinds.count):\(completed)")
        }

        let taskA = Task { await coordinator.export(session: a, kinds: [.summary]) }
        let taskB = Task { await coordinator.export(session: b, kinds: [.summary]) }
        for _ in 0..<20 { await Task.yield() }
        #expect(coordinator.isRunning(a))
        #expect(!coordinator.isRunning(b))
        #expect(coordinator.isActive(b))
        #expect(coordinator.isRunning(inFolder: "案件A"))
        #expect(!coordinator.isRunning(inFolder: "案件B"))
        #expect(coordinator.activeSessionIDs == [a.id, b.id])

        gate.open()
        _ = await taskA.value
        _ = await taskB.value
        #expect(coordinator.activeSessionIDs.isEmpty)
        #expect(finished.items == ["\(a.id):1:true", "別の会議:1:true"])
    }

    @MainActor
    @Test func 順番待ちの間にIDが変わっても結果は新しいIDに出る() async throws {
        let (a, tempA) = try makeSession()
        let (bBase, tempB) = try makeSession(folder: "案件B")
        defer {
            try? FileManager.default.removeItem(at: tempA)
            try? FileManager.default.removeItem(at: tempB)
        }
        let b = SessionInfo(
            id: "旧ID", directory: bBase.directory, startDate: bBase.startDate, name: "別", folder: "案件B")
        let api = FakeDriveAPI()
        let gate = TestGate()
        api.gate = gate
        let coordinator = DriveExportCoordinator { DriveExporter(api: api) }
        let taskA = Task { await coordinator.export(session: a, kinds: [.summary]) }
        let taskB = Task { await coordinator.export(session: b, kinds: [.summary]) }
        for _ in 0..<20 { await Task.yield() }
        coordinator.retarget(from: "旧ID", to: "新ID")
        gate.open()
        _ = await taskA.value
        _ = await taskB.value
        #expect(coordinator.states["新ID"] != nil)
        #expect(coordinator.states["旧ID"] == nil)
    }

    @Test func 書き出し待ちの移動は理由を添えて表示する() {
        #expect(
            SessionGroupMenuLogic.label(for: "A", pending: PendingMove(folder: "B"))
                == "グループ: B (要約のあとに移します)")
        #expect(
            SessionGroupMenuLogic.label(for: "A", pending: PendingMove(folder: nil), waitingForDrive: true)
                == "グループ: 未分類 (書き出しのあとに移します)")
        #expect(SessionGroupMenuLogic.label(for: "A", waitingForDrive: true) == "グループ: A")
    }
}

final class FinishedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ item: String) { lock.withLock { storage.append(item) } }
    var items: [String] { lock.withLock { storage } }
}
