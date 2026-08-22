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

    /// セッションディレクトリに置く成果物の名前。ここが「どのファイルがどう名付けられるか」の
    /// 正本で、保存・リネーム・受け渡し(SessionPackage)はすべてこれを通す
    /// (規則が散ると、成果物を1つ増やしたときに一部の経路だけ取り残される)。
    public enum Artifact: CaseIterable, Sendable {
        case transcript
        case audio
        case audioOther
        case summary
        case summaryEngine
        case cleaned

        /// そのセッションディレクトリでのファイル名。文字起こしと録音はディレクトリ名と
        /// 同じ基底名を持つ(Finder で1ファイルだけ取り出しても、どの会議か分かるように)。
        public func fileName(inDirectoryNamed directoryName: String) -> String {
            switch self {
            case .transcript: return "\(directoryName).md"
            case .audio: return "\(directoryName).m4a"
            case .audioOther: return "\(directoryName)-相手.m4a"
            case .summary: return "summary.md"
            case .summaryEngine: return "summary.engine"
            case .cleaned: return "cleaned.md"
            }
        }

        /// 録音か。録音を含めるかどうかの判断は、混ぜたものと相手だけのものを
        /// まとめて扱う(片方だけ残ると、再生の選択肢が中途半端に欠ける)。
        public var isAudio: Bool {
            switch self {
            case .audio, .audioOther: return true
            case .transcript, .summary, .summaryEngine, .cleaned: return false
            }
        }

        /// ディレクトリ名に依存しない固定名。旧形式(transcript.md / audio.m4a)の
        /// セッションを読むときの別名であり、受け渡しパッケージ(SessionPackage)の
        /// 中でもこの名前を使う(箱の中の名前がセッション名で揺れないように)。
        public var portableFileName: String {
            switch self {
            case .transcript: return "transcript.md"
            case .audio: return "audio.m4a"
            case .audioOther: return "audio-other.m4a"
            case .summary, .summaryEngine, .cleaned:
                // ディレクトリ名を使わない成果物は、保存時の名前がそのまま固定名。
                return fileName(inDirectoryNamed: "")
            }
        }

        /// 保存名とは別に探すべき旧形式の名前。無ければ nil。
        var legacyFileName: String? {
            let portable = portableFileName
            return portable == fileName(inDirectoryNamed: "") ? nil : portable
        }
    }

    /// 成果物の実体。無ければ nil。旧形式の固定名も探す。
    public func url(of artifact: Artifact) -> URL? {
        existing(artifact.fileName(inDirectoryNamed: directory.lastPathComponent))
            ?? artifact.legacyFileName.flatMap(existing)
    }

    public var transcriptURL: URL? { url(of: .transcript) }
    /// 録音(モノラル、自分と相手のミックス)。録音オフのセッションには無い。
    public var audioURL: URL? { url(of: .audio) }
    /// 相手の声だけの録音。会議アプリでマイクを切っていた場面でも自分の声が
    /// 混ざってしまうため、相手の声だけを聞き直せるようにしている。
    /// 相手の音を録らないセッションと、この機能より前のセッションには無い
    /// (再生の選択肢を出すかどうかは、この有無で決める)。
    ///
    /// 自分の声だけの録音は作らない。聞き直す場面が無いわりに、環境ノイズへ自動ゲインが
    /// 掛かるぶん最も容量を食う(実測で混ぜたものとほぼ同じ 1時間 44MB)。
    public var audioOtherURL: URL? { url(of: .audioOther) }
    /// 要約はアプリ内で表示する用途のため固定名。
    public var summaryURL: URL? { url(of: .summary) }
    /// エージェント CLI で清書した文字起こし(hearcat-clean スキル由来)。無ければ nil。
    public var cleanedURL: URL? { url(of: .cleaned) }

    /// summary.md と対になる固定名。要約を生成したエンジンの記録(SessionStore.writeSummaryEngine 参照)。
    fileprivate static let summaryEngineFileName =
        Artifact.summaryEngine.fileName(inDirectoryNamed: "")

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

    /// 保存先のルート。既定は Application Support/HearCat。
    ///
    /// アプリと CLI が同じパスを見ることが IPC 成立の前提なので、製品コードからは
    /// 絶対に書き換えないこと。差し替え口があるのは、保存や取り込みを本番の保存先に
    /// 触れずに検証するためで、書き換えてよいのはテストと検証ツールだけ。
    /// (差し替えるテストは書き換えが競合しないよう .serialized で直列に走らせる。)
    public nonisolated(unsafe) static var rootDirectory = defaultRootDirectory

    public static var defaultRootDirectory: URL {
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
        let dir = parentDirectory(forFolder: folder)
            .appendingPathComponent(
                directoryName(startDate: startDate, name: name), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 既存のどのセッションともぶつからないディレクトリを作り、実際に使った名前と
    /// グループ名を一緒に返す(どちらも sanitize 後の、ディスク上の実際の値)。
    /// 取り込み(SessionPackage)のように「同じ日時・同じ名前のセッションが既にあり得る」場面で使う。
    /// createSessionDirectory は既存ディレクトリがあってもそのまま返す(録音の途中再開を
    /// 壊さないため)ので、そちらを取り込みに使うと既存の記録へ上書きしてしまう。
    /// 衝突した場合は名前に「(2)」から順に接尾辞を足し、別のセッションとして並べる。
    public static func createUniqueSessionDirectory(
        startDate: Date, name: String = "", folder rawFolder: String? = nil
    ) throws -> (directory: URL, name: String, folder: String?) {
        // 外から渡ってきた名前(受け取ったパッケージ、取り込み画面の入力)をそのまま
        // ディレクトリ名にしない。日時形式のグループ名は list() がセッションと誤読するため、
        // 通常のグループ作成と同じ検証を通す。
        let folder = try rawFolder
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { try validFolderName($0) }

        let fm = FileManager.default
        let parent = parentDirectory(forFolder: folder)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let existing = Set((try? fm.contentsOfDirectory(atPath: parent.path)) ?? [])
        let resolved = uniqueSessionDirectoryName(
            startDate: startDate, name: name, existingNames: existing)
        let dir = parent.appendingPathComponent(resolved.directoryName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, resolved.name, folder)
    }

    /// createUniqueSessionDirectory が使う名前決めの本体。
    /// 「日時 名前」が既存と衝突する場合、名前に「(2)」から順に接尾辞を足して空きを探す。
    static func uniqueSessionDirectoryName(
        startDate: Date, name: String, existingNames: Set<String>
    ) -> (directoryName: String, name: String) {
        let base = sanitize(name)
        var candidate = base
        var suffix = 2
        while true {
            let dirName = directoryName(startDate: startDate, name: candidate)
            if !existingNames.contains(dirName) {
                return (dirName, candidate)
            }
            candidate = base.isEmpty ? "(\(suffix))" : "\(base) (\(suffix))"
            suffix += 1
        }
    }

    /// セッションディレクトリの名前。parse(directoryName:) が読む側の正本なので、
    /// 書く側はこの1関数だけを通す(区切りの空白や sanitize の有無がずれると、
    /// 自分で書いた名前を自分で読めなくなる)。
    static func directoryName(startDate: Date, name: String) -> String {
        let cleaned = sanitize(name)
        let datePart = makeFormatter().string(from: startDate)
        return cleaned.isEmpty ? datePart : "\(datePart) \(cleaned)"
    }

    /// セッションディレクトリを置く親。グループ名が nil なら sessions 直下(未分類)。
    private static func parentDirectory(forFolder folder: String?) -> URL {
        folder.map { sessionsDirectory.appendingPathComponent(sanitize($0), isDirectory: true) }
            ?? sessionsDirectory
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
    /// 並び順はユーザーが並べ替えた順(folder-order.json)を先に置き、まだ並び順に
    /// 載っていないフォルダ(新規作成・順序ファイル自体が無い場合)はアルファベット順で
    /// 末尾に続ける。順序ファイルに残ったまま実体が消えた名前は読み飛ばす。
    public static func listFolders() -> [String] {
        let onDisk = subdirectories(of: sessionsDirectory)
            .map(\.lastPathComponent)
            .filter { parse(directoryName: $0) == nil }
        let onDiskSet = Set(onDisk)
        let ordered = readFolderOrder().filter { onDiskSet.contains($0) }
        let orderedSet = Set(ordered)
        let rest = onDisk.filter { !orderedSet.contains($0) }.sorted()
        return ordered + rest
    }

    /// フォルダの並び順をユーザーの指定通りに固定する。listFolders() を使う全箇所
    /// (履歴・メニューパネルのグループ選択・CLI)で並びを一致させるため、
    /// UserDefaults ではなくここに永続化する。
    public static func setFolderOrder(_ order: [String]) {
        writeFolderOrder(order)
    }

    private static var folderOrderFileURL: URL {
        sessionsDirectory.appendingPathComponent("folder-order.json")
    }

    /// 保存された並び順。ファイルが無い・壊れている場合は空を返す
    /// (呼び出し側はアルファベット順へフォールバックする)。
    private static func readFolderOrder() -> [String] {
        guard let data = try? Data(contentsOf: folderOrderFileURL),
            let order = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return order
    }

    /// 並び順をそのまま書く。並び順はあくまで表示上の希望でしかないため、
    /// 書き込みに失敗しても呼び出し側に例外を投げない。
    private static func writeFolderOrder(_ order: [String]) {
        guard let data = try? JSONEncoder().encode(order) else { return }
        try? data.write(to: folderOrderFileURL, options: .atomic)
    }

    /// フォルダの改名を並び順に反映する。並び順にまだ載っていない名前
    /// (順序ファイルが無い、または一度も並べ替えていない)なら何もしない。
    private static func renameInFolderOrder(from name: String, to newName: String) {
        var order = readFolderOrder()
        guard let index = order.firstIndex(of: name) else { return }
        order[index] = newName
        writeFolderOrder(order)
    }

    /// フォルダの削除を並び順に反映する。並び順に載っていない名前なら何もしない。
    private static func removeFromFolderOrder(_ name: String) {
        var order = readFolderOrder()
        guard let index = order.firstIndex(of: name) else { return }
        order.remove(at: index)
        writeFolderOrder(order)
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

    // MARK: - 容量管理

    /// sessions ディレクトリの合計使用量。録音ファイル(.m4a)とそれ以外(文字起こし・要約など)に
    /// 分けて返す。ファイル種別ではなく拡張子で判定するので、SessionInfo.Artifact に無い
    /// 未知のファイルが混じっていてもディスク使用量の実態から漏れない。
    public struct StorageUsage: Sendable, Equatable {
        public let audioBytes: Int64
        public let otherBytes: Int64
        public var totalBytes: Int64 { audioBytes + otherBytes }
    }

    public static func storageUsage() -> StorageUsage {
        var audioBytes: Int64 = 0
        var otherBytes: Int64 = 0
        for url in regularFiles(under: sessionsDirectory) {
            let size = fileSize(at: url)
            if url.pathExtension == "m4a" {
                audioBytes += size
            } else {
                otherBytes += size
            }
        }
        return StorageUsage(audioBytes: audioBytes, otherBytes: otherBytes)
    }

    /// 指定日数より古いセッションのうち、録音ファイルを持つものの件数と合計サイズ。
    /// 実際に削除する前に、確認画面へ見せる用途。
    public struct OldRecordingsSummary: Sendable, Equatable {
        public let sessionCount: Int
        public let bytes: Int64
    }

    public static func oldRecordingsSummary(olderThanDays days: Int) -> OldRecordingsSummary {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        var count = 0
        var bytes: Int64 = 0
        for session in list() where session.startDate < cutoff {
            let sessionBytes = audioBytes(of: session)
            guard sessionBytes > 0 else { continue }
            count += 1
            bytes += sessionBytes
        }
        return OldRecordingsSummary(sessionCount: count, bytes: bytes)
    }

    /// 指定日数より古いセッションの録音ファイルだけを削除する。文字起こし・要約は残す
    /// (容量管理の目的は「聞き直しはもう要らないが記録は残したい」ため)。
    /// 個々のファイル削除が失敗しても他のセッションの削除は続け、実際に空いたバイト数を返す。
    @discardableResult
    public static func deleteOldRecordings(olderThanDays days: Int) -> Int64 {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        var freed: Int64 = 0
        for session in list() where session.startDate < cutoff {
            for artifact in SessionInfo.Artifact.allCases where artifact.isAudio {
                guard let url = session.url(of: artifact) else { continue }
                let size = fileSize(at: url)
                guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
                freed += size
            }
        }
        return freed
    }

    private static func audioBytes(of session: SessionInfo) -> Int64 {
        SessionInfo.Artifact.allCases
            .filter(\.isAudio)
            .compactMap(session.url(of:))
            .reduce(0) { $0 + fileSize(at: $1) }
    }

    /// ディレクトリ配下の通常ファイル(シンボリックリンク・ディレクトリを除く)を再帰的に列挙する。
    private static func regularFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
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
        let newDirName = directoryName(startDate: session.startDate, name: name)
        guard newDirName != session.directory.lastPathComponent else { return session }

        let fm = FileManager.default
        let newDir = session.directory.deletingLastPathComponent()
            .appendingPathComponent(newDirName, isDirectory: true)
        guard !fm.fileExists(atPath: newDir.path) else {
            throw StoreError.destinationExists(newDirName)
        }
        // ディレクトリ名に連動する成果物(文字起こし・録音)を新しい名前へ揃える。
        // どれが連動するかは Artifact 側の規則に従う(ここで名前を組み立て直さない)。
        for artifact in SessionInfo.Artifact.allCases {
            let newName = artifact.fileName(inDirectoryNamed: newDirName)
            guard let current = session.url(of: artifact),
                current.lastPathComponent != newName
            else { continue }
            try fm.moveItem(at: current, to: session.directory.appendingPathComponent(newName))
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
        renameInFolderOrder(from: name, to: newName)
        return newName
    }

    /// フォルダを消す。中のセッションは既定では消さず、未分類(sessions 直下)へ戻す。
    /// deletingSessionDirectories に挙げたディレクトリ名のセッションだけは中身ごと消す
    /// (挙げなかったものは未分類へ戻るため、録音中のセッションを外して呼べる)。
    public static func deleteFolder(
        _ name: String, deletingSessionDirectories doomed: Set<String> = []
    ) throws {
        let fm = FileManager.default
        let dir = sessionsDirectory.appendingPathComponent(name, isDirectory: true)
        // 名前順に固定する。ディレクトリの列挙順は保証されず、そのままだと途中で失敗した
        // ときに何が消えて何が残るかが実行のたびに変わる。
        let children = subdirectories(of: dir)
            .filter { parse(directoryName: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // 残す側の移動を先に済ませる。移動は未分類側の名前の衝突で失敗しうるため、
        // 消す方を先にやると、失敗を返す時点で消した分が戻せなくなる。
        for child in children where !doomed.contains(child.lastPathComponent) {
            let dest = sessionsDirectory.appendingPathComponent(
                child.lastPathComponent, isDirectory: true)
            guard !fm.fileExists(atPath: dest.path) else {
                throw StoreError.destinationExists(child.lastPathComponent)
            }
            try fm.moveItem(at: child, to: dest)
        }
        for child in children where doomed.contains(child.lastPathComponent) {
            try fm.removeItem(at: child)
        }
        try fm.removeItem(at: dir)
        removeFromFolderOrder(name)
    }

    private static func validFolderName(_ rawName: String) throws -> String {
        let name = sanitize(rawName)
        guard !name.isEmpty else { throw StoreError.emptyName }
        // 日時で始まる名前はセッションと見分けが付かなくなるため使えない。
        guard parse(directoryName: name) == nil else { throw StoreError.reservedName(name) }
        return name
    }

    /// ディレクトリ名として保存される形のセッション名。カレンダーの予定名と
    /// 保存済みセッション名を突き合わせる側(グループの自動推測)から呼ぶ。
    /// 保存時に文字が置換されることを知らずに生の予定名と比べると、
    /// 「/」「:」を含む予定名が永久に一致しなくなる。
    public static func storedName(for rawName: String) -> String {
        sanitize(rawName)
    }

    /// ファイル名に使えない文字を除いたセッション名/フォルダ名にする。
    private static func sanitize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
