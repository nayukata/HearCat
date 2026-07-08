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
    /// AI 清書(誤変換を文脈で直した版)。原文と同じ「[時刻] 話者: 本文」形式。
    /// 原文(transcript)が話した内容の一次記録なのに対し、こちらは読みやすさ優先の派生物。
    public var cleanedURL: URL? { existing("cleaned.md") }
    /// 清書のヒント(この会話の話題・固有名詞)。ユーザーが詳細画面で書く。
    public var hintsURL: URL? { existing("hints.md") }

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
    public static func createSessionDirectory(startDate: Date, name: String = "") throws -> URL {
        let cleaned = sanitize(name)
        let datePart = makeFormatter().string(from: startDate)
        let dir = sessionsDirectory.appendingPathComponent(
            cleaned.isEmpty ? datePart : "\(datePart) \(cleaned)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 全セッションを新しい順で返す。sessions 直下と、プロジェクトフォルダ1階層の中を見る。
    public static func list() -> [SessionInfo] {
        var sessions: [SessionInfo] = []
        for url in subdirectories(of: sessionsDirectory) {
            if let parsed = parse(directoryName: url.lastPathComponent) {
                sessions.append(SessionInfo(
                    id: url.lastPathComponent, directory: url,
                    startDate: parsed.startDate, name: parsed.name, folder: nil))
            } else {
                let folder = url.lastPathComponent
                for child in subdirectories(of: url) {
                    guard let parsed = parse(directoryName: child.lastPathComponent) else {
                        continue
                    }
                    sessions.append(SessionInfo(
                        id: "\(folder)/\(child.lastPathComponent)", directory: child,
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
