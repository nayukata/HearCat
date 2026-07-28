import Foundation

/// 1セッション(=1会議)ぶんの成果物の置き場所。
/// ディレクトリ名は「日時」または「日時 セッション名」。文字起こしと録音はディレクトリ名と
/// 同じ基底名を持つ(Finder で1ファイルだけ取り出しても、どの会議か分かるように)。
public struct SessionInfo: Identifiable, Sendable, Equatable {
    /// sessions ディレクトリからの相対パス(プロジェクトフォルダ内なら「フォルダ名/ディレクトリ名」)。
    public let id: String
    public let directory: URL
    public let startDate: Date
    /// ユーザーが付けたセッション名。未設定は空文字。
    public let name: String
    /// 所属するプロジェクトフォルダ。未分類なら nil。
    public let folder: String?

    /// 旧形式(transcript.md / audio.m4a の固定名)のセッションも読めるよう、両方の名前を探す。
    public var transcriptURL: URL? {
        existing("\(directory.lastPathComponent).md") ?? existing("transcript.md")
    }
    /// 録音(モノラル、自分と相手のミックス)。録音オフのセッションには無い。
    public var audioURL: URL? {
        existing("\(directory.lastPathComponent).m4a") ?? existing("audio.m4a")
    }
    /// 要約はアプリ内で表示する用途のため固定名。
    public var summaryURL: URL? { existing("summary.md") }
    /// エージェント CLI で清書した文字起こし(hearcat-clean スキル由来)。無ければ nil。
    public var cleanedURL: URL? { existing("cleaned.md") }

    /// summary.md と対になる固定名。要約を生成したエンジンの記録(SessionStore.writeSummaryEngine 参照)。
    fileprivate static let summaryEngineFileName = "summary.engine"

    /// 要約を生成したエンジン。無ければ nil(この機能より前に生成された過去の要約、
    /// または読み取り失敗)。現在の設定から推測せず、生成時点に書かれた記録だけを見る。
    public var summaryEngine: SummaryEngine? {
        guard let url = existing(Self.summaryEngineFileName) else { return nil }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SummaryEngine(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func existing(_ name: String) -> URL? {
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 検索クエリに一致するか。セッション名・ディレクトリ名(日時)に加え、
    /// 文字起こしと要約の本文まで横断して見る(「あの話どの会議だっけ」を引けるように)。
    public func matches(_ query: String) -> Bool {
        if name.localizedCaseInsensitiveContains(query)
            || directory.lastPathComponent.localizedCaseInsensitiveContains(query) {
            return true
        }
        return [transcriptURL, summaryURL].compactMap { $0 }.contains { url in
            (try? String(contentsOf: url, encoding: .utf8))?
                .localizedCaseInsensitiveContains(query) ?? false
        }
    }
}

/// セッションの保存先(Application Support)と IPC ソケットのパスを一元管理する。
/// アプリと CLI が同じパスを見ることが IPC 成立の前提なので、ここ以外にパスを書かない。
public enum SessionStore {
    public static let bundleIdentifier = "dev.nayukata.hearcat"

    /// セッションディレクトリ名の日時部分のフォーマット。
    /// フォーマット文字列と出力("2026-07-06_000858")は同じ長さで、名前の切り出しに使う。
    private static let idFormat = "yyyy-MM-dd_HHmmss"

    public static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearCat", isDirectory: true)
    }

    public static var sessionsDirectory: URL {
        rootDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Unix ドメインソケットのパス。sockaddr_un の 104 バイト制限に収まる長さであること。
    public static var socketPath: String {
        rootDirectory.appendingPathComponent("control.sock").path
    }

    private static func makeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = idFormat
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// ディレクトリ名を開始日時とセッション名に分解する。
    /// 日時で始まらない名前は nil(=セッションではなくプロジェクトフォルダ)。
    static func parse(directoryName: String) -> (startDate: Date, name: String)? {
        guard directoryName.count >= idFormat.count,
              let date = makeFormatter().date(from: String(directoryName.prefix(idFormat.count)))
        else { return nil }
        let rest = directoryName.dropFirst(idFormat.count)
        guard !rest.isEmpty else { return (date, "") }
        guard rest.hasPrefix(" ") else { return nil }
        return (date, String(rest.dropFirst()))
    }

    /// 新しいセッションディレクトリを作って返す。
    /// name(カレンダーの予定名など)があれば「日時 名前」の形で最初から名前付きにする。
    /// 開始後のリネームは書き込み中のパスとずれるため、名前は作成時に決める。
    /// folder を指定すると、そのプロジェクトフォルダ(グループ)の配下に作る
    /// (中間ディレクトリの作成は createDirectory の withIntermediateDirectories で足りる)。
    public static func createSessionDirectory(
        startDate: Date, name: String = "", folder: String? = nil
    ) throws -> URL {
        let cleaned = sanitize(name)
        let datePart = makeFormatter().string(from: startDate)
        let dirName = cleaned.isEmpty ? datePart : "\(datePart) \(cleaned)"
        let parent = folder.map { sessionsDirectory.appendingPathComponent(sanitize($0), isDirectory: true) }
            ?? sessionsDirectory
        let dir = parent.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// セッションディレクトリの URL から SessionInfo.id を計算する。
    /// SessionEngine の status.sessionID もこの規則を通し、
    /// 「list() が返す id」と「今動いているセッションの id」の照合が必ず成立するようにする
    /// (両者が食い違うと、停止直後の自動要約や履歴の自動選択が空振りする)。
    public static func relativeID(for sessionDirectory: URL) -> String {
        let base = sessionsDirectory.standardizedFileURL.pathComponents
        let target = sessionDirectory.standardizedFileURL.pathComponents
        guard target.starts(with: base), target.count > base.count else {
            return sessionDirectory.lastPathComponent
        }
        return target.dropFirst(base.count).joined(separator: "/")
    }

    /// 全セッションを新しい順で返す。sessions 直下と、プロジェクトフォルダ1階層の中を見る。
    public static func list() -> [SessionInfo] {
        var sessions: [SessionInfo] = []
        for url in subdirectories(of: sessionsDirectory) {
            if let parsed = parse(directoryName: url.lastPathComponent) {
                sessions.append(SessionInfo(
                    id: relativeID(for: url), directory: url,
                    startDate: parsed.startDate, name: parsed.name, folder: nil))
            } else {
                let folder = url.lastPathComponent
                for child in subdirectories(of: url) {
                    guard let parsed = parse(directoryName: child.lastPathComponent) else {
                        continue
                    }
                    sessions.append(SessionInfo(
                        id: relativeID(for: child), directory: child,
                        startDate: parsed.startDate, name: parsed.name, folder: folder))
                }
            }
        }
        return sessions.sorted { $0.startDate > $1.startDate }
    }

    /// プロジェクトフォルダの一覧(空のフォルダも含む)。
    public static func listFolders() -> [String] {
        subdirectories(of: sessionsDirectory)
            .map(\.lastPathComponent)
            .filter { parse(directoryName: $0) == nil }
            .sorted()
    }

    private static func subdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return contents.filter {
            !$0.lastPathComponent.hasPrefix(".")
                && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
    }

    /// 最新のセッション(録音中のものを含む)。
    public static func latest() -> SessionInfo? {
        list().first
    }

    public static func delete(_ session: SessionInfo) throws {
        try FileManager.default.removeItem(at: session.directory)
    }

    /// 要約を生成したエンジンを記録する。要約生成の直後、summary.md の保存とセットで呼ぶこと。
    /// 表示のたびに「今の設定」から推測すると、設定を後から変えた時に過去の要約の表示が
    /// 実態と食い違うため、生成時点の値をそのまま固定する(SummaryEngine 参照)。
    /// 既存の要約保存形式(セッションディレクトリ内の1関心=1ファイル)に馴染ませ、
    /// summary.md 自体のフォーマットは変えない(SummaryParser の後方互換を壊さないため)。
    public static func writeSummaryEngine(_ engine: SummaryEngine, for session: SessionInfo) throws {
        try engine.rawValue.write(
            to: session.directory.appendingPathComponent(SessionInfo.summaryEngineFileName),
            atomically: true, encoding: .utf8)
    }

    public enum StoreError: LocalizedError {
        case destinationExists(String)
        case emptyName
        case reservedName(String)

        public var errorDescription: String? {
            switch self {
            case .destinationExists(let name):
                return "「\(name)」は既にあります"
            case .emptyName:
                return "名前を入力してください"
            case .reservedName(let name):
                return "「\(name)」はフォルダ名に使えません(日時形式はセッション用のため)"
            }
        }
    }

    /// セッション名を変える(空文字で名前を外す)。ディレクトリと中の成果物をまとめてリネームし、
    /// 変更後の SessionInfo を返す。旧形式の固定名ファイルもこの機会に新形式へ揃える。
    public static func rename(_ session: SessionInfo, to rawName: String) throws -> SessionInfo {
        let name = sanitize(rawName)
        let datePart = makeFormatter().string(from: session.startDate)
        let newDirName = name.isEmpty ? datePart : "\(datePart) \(name)"
        guard newDirName != session.directory.lastPathComponent else { return session }

        let fm = FileManager.default
        let newDir = session.directory.deletingLastPathComponent()
            .appendingPathComponent(newDirName, isDirectory: true)
        guard !fm.fileExists(atPath: newDir.path) else {
            throw StoreError.destinationExists(newDirName)
        }
        if let transcript = session.transcriptURL {
            try fm.moveItem(
                at: transcript, to: session.directory.appendingPathComponent("\(newDirName).md"))
        }
        if let audio = session.audioURL {
            try fm.moveItem(
                at: audio, to: session.directory.appendingPathComponent("\(newDirName).m4a"))
        }
        try fm.moveItem(at: session.directory, to: newDir)
        return SessionInfo(
            id: session.folder.map { "\($0)/\(newDirName)" } ?? newDirName,
            directory: newDir, startDate: session.startDate, name: name, folder: session.folder)
    }

    /// セッションをプロジェクトフォルダへ移す(nil で未分類へ戻す)。フォルダは無ければ作る。
    public static func move(_ session: SessionInfo, toFolder rawFolder: String?) throws -> SessionInfo {
        let folder = rawFolder.map(sanitize).flatMap { $0.isEmpty ? nil : $0 }
        let fm = FileManager.default
        let parent = folder.map { sessionsDirectory.appendingPathComponent($0, isDirectory: true) }
            ?? sessionsDirectory
        let dirName = session.directory.lastPathComponent
        let newDir = parent.appendingPathComponent(dirName, isDirectory: true)
        guard newDir.path != session.directory.path else { return session }
        guard !fm.fileExists(atPath: newDir.path) else {
            throw StoreError.destinationExists(dirName)
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.moveItem(at: session.directory, to: newDir)
        return SessionInfo(
            id: folder.map { "\($0)/\(dirName)" } ?? dirName,
            directory: newDir, startDate: session.startDate, name: session.name, folder: folder)
    }

    /// 資料フォルダから新規グループを作る際、グループ名(候補は選んだフォルダの
    /// lastPathComponent)の衝突を避けた実際の名前を決める。
    /// - 候補名が未使用なら候補名をそのまま返す(新規グループとして作る)。
    /// - 候補名のグループは既にあるが関連フォルダが未設定なら、候補名をそのまま返す
    ///   (新規に作らず、既存の未紐付けグループへ紐付けるだけにする)。
    /// - 候補名のグループが既に選んだのと同じパスへ紐付け済みなら、候補名をそのまま返す
    ///   (同じ操作のやり直しなので、グループを増やさない)。
    /// - 候補名のグループが別パスへ紐付け済みなら、「候補名-2」のように空いている
    ///   接尾辞付きの名前を返す(既存の紐付けを壊さず、別グループとして分ける)。
    ///   このとき、接尾辞候補が「選んだのと同じパスに既に紐付いている」なら
    ///   それを再利用する(過去に同じ操作で作った Foo-2 を再度作り直さないため)。
    public static func resolveFolderName(
        candidate: String, selectedPath: String,
        existingFolders: [String], referenceFolders: [String: String]
    ) -> String {
        guard existingFolders.contains(candidate) else { return candidate }
        let candidateLinkedPath = referenceFolders[candidate]
        if candidateLinkedPath == nil || candidateLinkedPath == selectedPath {
            return candidate
        }
        var suffix = 2
        while true {
            let name = "\(candidate)-\(suffix)"
            // 過去の同じ操作で作った接尾辞グループが同じパスに紐付いていれば、
            // 新規に作らず再利用する(そうしないと選ぶたびに Foo-2, Foo-3, Foo-4 …と増える)。
            if referenceFolders[name] == selectedPath { return name }
            // それ以外の既存グループ(別パスに紐付いている、または未紐付けだが名前だけ埋まっている)
            // は避けて次の接尾辞へ進む。空きが見つかったらそこを新規に使う。
            if !existingFolders.contains(name) { return name }
            suffix += 1
        }
    }

    /// 空のプロジェクトフォルダを作る。
    public static func createFolder(_ rawName: String) throws {
        let name = try validFolderName(rawName)
        let dir = sessionsDirectory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw StoreError.destinationExists(name)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// フォルダ名を変え、新しい名前を返す。中のセッションの ID も変わるため、
    /// 呼び出し側で一覧を取り直すこと。
    public static func renameFolder(_ name: String, to rawNewName: String) throws -> String {
        let newName = try validFolderName(rawNewName)
        guard newName != name else { return name }
        let fm = FileManager.default
        let newDir = sessionsDirectory.appendingPathComponent(newName, isDirectory: true)
        guard !fm.fileExists(atPath: newDir.path) else {
            throw StoreError.destinationExists(newName)
        }
        try fm.moveItem(
            at: sessionsDirectory.appendingPathComponent(name, isDirectory: true), to: newDir)
        return newName
    }

    /// フォルダを消す。中のセッションは消さず、未分類(sessions 直下)へ戻す。
    public static func deleteFolder(_ name: String) throws {
        let fm = FileManager.default
        let dir = sessionsDirectory.appendingPathComponent(name, isDirectory: true)
        for child in subdirectories(of: dir)
        where parse(directoryName: child.lastPathComponent) != nil {
            let dest = sessionsDirectory.appendingPathComponent(
                child.lastPathComponent, isDirectory: true)
            guard !fm.fileExists(atPath: dest.path) else {
                throw StoreError.destinationExists(child.lastPathComponent)
            }
            try fm.moveItem(at: child, to: dest)
        }
        try fm.removeItem(at: dir)
    }

    private static func validFolderName(_ rawName: String) throws -> String {
        let name = sanitize(rawName)
        guard !name.isEmpty else { throw StoreError.emptyName }
        // 日時で始まる名前はセッションと見分けが付かなくなるため使えない。
        guard parse(directoryName: name) == nil else { throw StoreError.reservedName(name) }
        return name
    }

    /// ファイル名に使えない文字を除いたセッション名/フォルダ名にする。
    private static func sanitize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
