import CryptoKit
import Foundation
import HearCatKit

/// Drive に書き出す中身の種類。
enum DriveContentKind: String, Codable, CaseIterable, Sendable {
    case summary
    case transcript
    case audio
    case audioOther

    /// ローカルの成果物。名前の正本は SessionInfo.Artifact。
    var artifact: SessionInfo.Artifact {
        switch self {
        case .summary: .summary
        case .transcript: .transcript
        case .audio: .audio
        case .audioOther: .audioOther
        }
    }

    var label: String {
        switch self {
        case .summary: "要約"
        case .transcript: "文字起こし"
        case .audio: "録音"
        case .audioOther: "録音 (相手の声)"
        }
    }

    /// 文書は Google ドキュメントへ変換して置く。録音はそのまま。
    var isDocument: Bool { self == .summary || self == .transcript }

    /// Drive 上の名前。文書は「<日付> <セッション名> 要約」のように、フォルダの外(検索や共有)でも
    /// どの回か分かる名前にする。セッション名が空なら日付のあとに開始時刻を入れる。
    /// 録音はローカルと同じファイル名にする。
    func driveName(fileName: String, session: SessionInfo) -> String {
        switch self {
        case .summary: "\(Self.documentPrefix(of: session)) 要約"
        case .transcript: "\(Self.documentPrefix(of: session)) 文字起こし"
        case .audio, .audioOther: fileName
        }
    }

    /// 日付つきの名前にする前に使っていた名前。書き出し済みのファイルを探して直すのに使う。
    var legacyDriveName: String? {
        switch self {
        case .summary: "要約"
        case .transcript: "文字起こし"
        case .audio, .audioOther: nil
        }
    }

    private static func documentPrefix(of session: SessionInfo) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: session.startDate)
        let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return "\(day) \(name)" }
        formatter.dateFormat = "HH:mm"
        return "\(day) \(formatter.string(from: session.startDate))"
    }
}

/// 設定で選んだ「書き出す中身」。
struct DriveContentSelection: Codable, Equatable, Sendable {
    var summary = true
    var transcript = true
    var audio = false

    var kinds: [DriveContentKind] {
        var result: [DriveContentKind] = []
        if summary { result.append(.summary) }
        if transcript { result.append(.transcript) }
        if audio { result += [.audio, .audioOther] }
        return result
    }

    var isEmpty: Bool { kinds.isEmpty }
}

/// 自動書き出しの対象グループ。
struct DriveAutoExportTarget: Codable, Equatable, Sendable {
    var allGroups = true
    /// allGroups が false のときに書き出すグループ名。
    var groups: Set<String> = []
    var includesUnclassified = true

    /// folder は SessionInfo.folder(未分類は nil)。
    func includes(folder: String?) -> Bool {
        if allGroups { return true }
        guard let folder else { return includesUnclassified }
        return groups.contains(folder)
    }

    /// グループの改名・削除に追従する(削除は newName が nil)。
    mutating func retarget(from folder: String, to newName: String?) {
        guard groups.remove(folder) != nil else { return }
        if let newName { groups.insert(newName) }
    }
}

/// Drive 上の置き場所。マイドライブ直下の HearCat/<グループ名>/<セッションのディレクトリ名>。
enum DrivePaths {
    static let rootName = "HearCat（議事録）"
    static let unclassifiedName = "未分類"

    static func folderPath(group: String?, sessionDirectoryName: String) -> [String] {
        [rootName, group ?? unclassifiedName, sessionDirectoryName]
    }

    static func folderURL(id: String) -> URL {
        URL(string: "https://drive.google.com/drive/folders/\(id)")!
    }
}

/// セッションディレクトリに置く書き出し記録(drive.json)。
/// 成功した種類だけを持つ。2 回目以降は、ここにある ID のファイルを更新する。
struct DriveRecord: Codable, Equatable, Sendable {
    /// 直近に書き出したセッションの Drive フォルダ。「Drive で開く」の行き先。
    var folderID: String?
    var files: [String: String] = [:]
    /// 最後に Drive へ送った中身の指紋(種類ごと)。親の付け替えだけで済むか(本文が変わっていないか)の判定に使う。
    /// 古い記録には無い。
    var fingerprints: [String: String]?
    /// 種類ごとに、最後に書いた転送が自動だったか。手動で一度でも書いたら手動のまま。
    /// 印の無い種類(古い記録)は手動として扱い、勝手に片付けない。
    var automaticKinds: [String: Bool]?
    /// 種類ごとに、最後に書き出して実際に置かれた場所と名前。「書き出し済み」の判定に使う。
    /// 親の付け替えを断られたときは、置き場所が変わっていないので更新しない。古い記録には無い。
    var locations: [String: DriveLocation]?

    /// 記録のある種類。
    var recordedKinds: [DriveContentKind] {
        DriveContentKind.allCases.filter { files[$0.rawValue] != nil }
    }

    func fileID(for kind: DriveContentKind) -> String? { files[kind.rawValue] }

    mutating func set(
        _ id: String, for kind: DriveContentKind, fingerprint: String?, automatic: Bool = false
    ) {
        files[kind.rawValue] = id
        var marks = automaticKinds ?? [:]
        marks[kind.rawValue] = automatic && marks[kind.rawValue] != false
        automaticKinds = marks
        var all = fingerprints ?? [:]
        all[kind.rawValue] = fingerprint
        fingerprints = all
    }

    mutating func setLocation(_ location: DriveLocation, for kind: DriveContentKind) {
        var all = locations ?? [:]
        all[kind.rawValue] = location
        locations = all
    }

    func location(for kind: DriveContentKind) -> DriveLocation? { locations?[kind.rawValue] }

    func fingerprint(for kind: DriveContentKind) -> String? { fingerprints?[kind.rawValue] }

    func isAutomatic(_ kind: DriveContentKind) -> Bool { automaticKinds?[kind.rawValue] == true }

    mutating func remove(_ kind: DriveContentKind) {
        automaticKinds?[kind.rawValue] = nil
        files[kind.rawValue] = nil
        fingerprints?[kind.rawValue] = nil
        locations?[kind.rawValue] = nil
    }
}

/// Drive 上の置き場所(フォルダの階層)と名前。
struct DriveLocation: Codable, Equatable, Sendable {
    var path: [String]
    var name: String
}

/// 詳細画面で「書き出し済み」と見なしてよいかの判定。
enum DriveExportedCheck {
    /// 設定で選んだ中身のうち手元に実体があるものがすべて記録にあり、中身の指紋と
    /// Drive 上の置き場所・名前が今と同じなら true。古い記録(指紋や場所が無い)は false。
    static func isUpToDate(record: DriveRecord, kinds: [DriveContentKind], session: SessionInfo) -> Bool {
        let present = kinds.compactMap { kind in session.url(of: kind.artifact).map { (kind, $0) } }
        guard !present.isEmpty, record.folderID != nil else { return false }
        let path = DrivePaths.folderPath(
            group: session.folder, sessionDirectoryName: session.directory.lastPathComponent)
        for (kind, url) in present {
            guard record.fileID(for: kind) != nil,
                let recorded = record.fingerprint(for: kind),
                recorded == DriveFingerprint.of(kind, fileURL: url),
                record.location(for: kind)
                    == DriveLocation(
                        path: path, name: kind.driveName(fileName: url.lastPathComponent, session: session))
            else { return false }
        }
        return true
    }
}

enum DriveRecordStore {
    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(
            SessionInfo.Artifact.driveRecord.fileName(inDirectoryNamed: directory.lastPathComponent))
    }

    /// 手動で書いたものとして印を付け替える(自動の転送へ手動の呼び出しが合流したとき)。
    static func markManual(_ kinds: [DriveContentKind], in directory: URL) {
        var record = load(in: directory)
        var changed = false
        for kind in kinds where record.files[kind.rawValue] != nil && record.isAutomatic(kind) {
            record.automaticKinds?[kind.rawValue] = false
            changed = true
        }
        if changed { try? save(record, in: directory) }
    }

    /// 無い・壊れているときは空の記録を返す(壊れた記録で書き出しそのものを止めない)。
    static func load(in directory: URL) -> DriveRecord {
        guard let data = try? Data(contentsOf: url(in: directory)),
            let record = try? JSONDecoder().decode(DriveRecord.self, from: data)
        else { return DriveRecord() }
        return record
    }

    /// 原子的に書く。途中で止まっても、前の記録か新しい記録のどちらかが残る。
    static func save(_ record: DriveRecord, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url(in: directory), options: .atomic)
    }
}

/// 中身の指紋。文書は内容のハッシュ、録音は巨大なのでハッシュを取らず大きさと更新日時。
enum DriveFingerprint {
    static func of(_ kind: DriveContentKind, fileURL: URL) -> String? {
        if kind.isDocument {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attrs[.size] as? Int, let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return "\(size)-\(Int(modified.timeIntervalSince1970))"
    }
}

/// 1 回の書き出しの結果。
struct DriveExportOutcome: Equatable, Sendable {
    var created: [DriveContentKind] = []
    var updated: [DriveContentKind] = []
    /// ローカルに実体が無くて書き出せなかったもの。
    var missing: [DriveContentKind] = []
    var failures: [DriveContentKind: String] = [:]
    var folderID: String?

    /// 先の結果に後の結果を重ねる。後で成功した種類は、先の失敗を取り下げる。
    func merging(_ later: DriveExportOutcome) -> DriveExportOutcome {
        func unique(_ kinds: [DriveContentKind]) -> [DriveContentKind] {
            var seen = Set<DriveContentKind>()
            return kinds.filter { seen.insert($0).inserted }
        }
        var result = self
        result.created = unique(created + later.created)
        result.updated = unique(updated + later.updated)
        result.missing = unique(missing + later.missing)
        for kind in later.created + later.updated { result.failures[kind] = nil }
        for (kind, message) in later.failures { result.failures[kind] = message }
        result.folderID = later.folderID ?? folderID
        return result
    }

    var succeededCount: Int { created.count + updated.count }
    var hasFailure: Bool { !failures.isEmpty }

    var failureMessage: String? {
        guard hasFailure else { return nil }
        return DriveContentKind.allCases.compactMap { kind in
            failures[kind].map { "\(kind.label): \($0)" }
        }.joined(separator: " / ")
    }
}

/// フォルダの解決と、中身の新規作成 / 更新の判定。ネットワークは DriveAPI の向こう。
/// 同時に複数の書き出しが同じフォルダを作って重複しないよう、呼び出し側は 1 本ずつ流すこと。
struct DriveExporter: Sendable {
    let api: DriveAPI

    /// 書き出す。進行は onProgress に流す。認証の失敗(isFatal)だけが throw で、
    /// 種類ごとの失敗は outcome.failures に残して次の種類へ進む。
    func export(
        session: SessionInfo, kinds: [DriveContentKind], automatic: Bool = false,
        onProgress: @Sendable (String) -> Void = { _ in }
    ) async throws -> DriveExportOutcome {
        var outcome = DriveExportOutcome()
        var record = DriveRecordStore.load(in: session.directory)
        outcome.folderID = record.folderID
        let directoryName = session.directory.lastPathComponent
        var folderID: String?

        for kind in kinds {
            try Task.checkCancellation()
            guard let source = session.url(of: kind.artifact) else {
                outcome.missing.append(kind)
                continue
            }
            onProgress("\(kind.label)を送信中")
            let upload = DriveUpload(
                name: kind.driveName(fileName: source.lastPathComponent, session: session), fileURL: source,
                kind: kind.isDocument ? .document : .raw(mimeType: "audio/mp4"))
            do {
                if folderID == nil {
                    let resolved = try await resolveFolder(
                        path: DrivePaths.folderPath(
                            group: session.folder, sessionDirectoryName: directoryName))
                    folderID = resolved
                    outcome.folderID = resolved
                    // ファイルが 1 つも置けなくても、作れたフォルダは開けるようにしておく。
                    // 既に別の場所に置いたファイルがあるときは、付け替えに成功するまで据え置く。
                    if record.folderID != resolved && record.files.isEmpty {
                        record.folderID = resolved
                        try DriveRecordStore.save(record, in: session.directory)
                    }
                }
                let parent = folderID!
                var ref: DriveFileRef?
                let fingerprint = DriveFingerprint.of(kind, fileURL: source)
                if let existing = record.fileID(for: kind) {
                    do {
                        // 親が現在のパスと違えば(グループ移動・改名の後)、ここで現在のフォルダへ移る。
                        let changed = fingerprint == nil || fingerprint != record.fingerprint(for: kind)
                        let updated = try await api.update(
                            fileID: existing, with: upload, parentID: parent, contentChanged: changed)
                        // ごみ箱に入れられたファイルは更新できても見えないので、作り直す。
                        if !updated.trashed {
                            ref = updated
                            outcome.updated.append(kind)
                        }
                    } catch DriveError.notFound {
                        // 消されている。新規作成へ進む。
                    }
                }
                if ref == nil {
                    // 記録を失った・前回の作成が届いていたなどで同名があれば、新しく作らずそれを使う。
                    // 日付つきの名前にする前に書き出したファイルも同じ扱いで、更新時に名前を直す。
                    var found = try await api.findFile(name: upload.name, parentID: parent)
                    if found == nil, let legacy = kind.legacyDriveName {
                        found = try await api.findFile(name: legacy, parentID: parent)
                    }
                    if let found {
                        ref = try await api.update(
                            fileID: found, with: upload, parentID: parent, contentChanged: true)
                        outcome.updated.append(kind)
                    } else {
                        ref = try await createRecovering(upload, parentID: parent)
                        outcome.created.append(kind)
                    }
                }
                record.set(ref!.id, for: kind, fingerprint: fingerprint, automatic: automatic)
                if !ref!.moveFailed {
                    record.setLocation(
                        DriveLocation(
                            path: DrivePaths.folderPath(group: session.folder, sessionDirectoryName: directoryName),
                            name: upload.name),
                        for: kind)
                }
                if ref!.moveFailed {
                    // 実際の親は変わっていない。「Drive で開く」は元のフォルダのままにする。
                    outcome.folderID = record.folderID
                } else {
                    record.folderID = parent
                    outcome.folderID = parent
                }
                // 1 つ成功するごとに残す。後ろの種類が失敗しても、成功分の対応は失わない。
                try DriveRecordStore.save(record, in: session.directory)
            } catch let error as DriveError where error.isFatal {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome.failures[kind] = error.localizedDescription
            }
        }
        return outcome
    }

    /// 記録にあるファイルをすべてごみ箱へ移し、記録から消す。フォルダは作らない。
    /// 失敗したファイルは記録に残し、最初の失敗を投げる。
    /// kinds を渡したときは、その種類だけを対象にする。
    func trashRecorded(session: SessionInfo, kinds: [DriveContentKind]? = nil) async throws {
        var record = DriveRecordStore.load(in: session.directory)
        var firstError: Error?
        for kind in record.recordedKinds where kinds?.contains(kind) ?? true {
            do {
                try await api.trash(fileID: record.fileID(for: kind)!)
                record.remove(kind)
            } catch let error as DriveError where error.isFatal {
                throw error
            } catch {
                firstError = firstError ?? error
            }
        }
        if record.files.isEmpty {
            try? FileManager.default.removeItem(at: DriveRecordStore.url(in: session.directory))
        } else {
            try DriveRecordStore.save(record, in: session.directory)
        }
        if let firstError { throw firstError }
    }

    /// 作成が一時的に失敗したときは、届いていたかもしれないので同名を探してからやり直す
    /// (そのまま作り直すと二重になる)。
    private func createRecovering(_ upload: DriveUpload, parentID: String) async throws -> DriveFileRef {
        do {
            return try await api.create(upload, parentID: parentID)
        } catch let error as DriveError where error.isTransient {
            if let found = try await api.findFile(name: upload.name, parentID: parentID) {
                return DriveFileRef(id: found, trashed: false)
            }
            return try await api.create(upload, parentID: parentID)
        }
    }

    /// path の各階層を順に辿り、無ければ作る。最後の階層の ID を返す。
    /// 同名のフォルダが既にあれば(アプリ再起動後の再実行など)それを使い、重複して作らない。
    func resolveFolder(path: [String]) async throws -> String {
        var parent: String?
        for name in path {
            if let found = try await api.findFolder(name: name, parentID: parent) {
                parent = found
                continue
            }
            do {
                parent = try await api.createFolder(name: name, parentID: parent)
            } catch let error as DriveError where error.isTransient {
                if let found = try await api.findFolder(name: name, parentID: parent) {
                    parent = found
                } else {
                    parent = try await api.createFolder(name: name, parentID: parent)
                }
            }
        }
        guard let parent else { throw DriveError.notFound }
        return parent
    }
}
