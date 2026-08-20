import Foundation
import os

/// decisions.json の読み込み失敗(壊れた JSON 等)を残すための内部ログ。ファイル不存在は
/// load が正常系として空を返すため、ここでは記録しない。
private let decisionLogStoreLogger = Logger(
    subsystem: SessionStore.bundleIdentifier, category: "decision-log-store")

/// 決定事項の状態。表示名は UI 側の文言をここに正本として持つ
/// (画面ごとに 確定/仮/保留 の表記が揺れないように)。
public enum DecisionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case confirmed
    case tentative
    case pending

    public var displayName: String {
        switch self {
        case .confirmed: return "確定"
        case .tentative: return "仮"
        case .pending: return "保留"
        }
    }
}

/// 決定を言い出した側。不明な場合は nil(発言者の切り分けができない要約もあるため)。
public enum DecisionSpeaker: String, Codable, Sendable, Equatable {
    case me
    case them

    /// 表示名。DecisionStatus.displayName と同じ理由(画面ごとに表記が揺れないように)で正本を持つ。
    public var displayName: String {
        switch self {
        case .me: return "自分"
        case .them: return "相手"
        }
    }
}

/// エントリの由来。値が無い(nil)場合は会話(AI 抽出)由来を表す。既存の decisions.json は
/// このフィールド自体を持たないため、増やす選択肢は「nil = 会話由来」に固定し、旧ファイルの
/// デコードが壊れないようにする(会話由来にまで明示の case を振ると、旧 JSON にキーが
/// 無いだけで判別できてしまうように見えて、実装が「キーの有無」と「値」の二重管理になる)。
public enum DecisionEntryOrigin: String, Codable, Sendable, Equatable {
    /// 会話の外(Slack・PR レビュー等)でユーザーが手動で記録したエントリ。
    case manual
}

/// 1回の決定の記録。どのセッションの、いつの発言かを保つのは、後から該当箇所へ
/// ジャンプする・同じセッションの要約を再生成したときに置き換える、の両方に使うため。
public struct DecisionEntry: Codable, Sendable, Equatable {
    public var text: String
    public var status: DecisionStatus
    /// 由来セッションのディレクトリ名。SessionStore が付ける命名と同じもので、
    /// 再抽出時の置換キー(DecisionLogStore.merge 参照)にもなる。
    /// 手動エントリ(origin == .manual)はどのセッションにも属さないため空文字固定。
    public var sessionDirectoryName: String
    /// 表示用のセッション名。ディレクトリ名は日時混じりで読みにくいため別に持つ。
    /// 手動エントリは sessionDirectoryName と同じ理由で空文字固定。
    public var sessionName: String
    /// セッションの開始日時。複数セッションをまたいだ履歴の並び順の主キー。
    /// 手動エントリでは「記録した日時」がそのままこれにあたる。
    public var recordedAt: Date
    /// セッション内の経過秒。該当発言へのジャンプ用。分からなければ nil。手動エントリは常に nil。
    public var timeSeconds: Int?
    /// 手動エントリは発言者の切り分けという概念自体が無いため常に nil。
    public var by: DecisionSpeaker?
    /// 変更理由の一言。新規決定には無いことが多いので任意。手動エントリでは
    /// 「どこで決まったか」(例: "Slack で合意")を入れる想定。
    public var reason: String?
    /// エントリの由来。nil = 会話由来(既存の抽出フロー)。
    public var origin: DecisionEntryOrigin?

    public init(
        text: String, status: DecisionStatus, sessionDirectoryName: String, sessionName: String,
        recordedAt: Date, timeSeconds: Int? = nil, by: DecisionSpeaker? = nil,
        reason: String? = nil, origin: DecisionEntryOrigin? = nil
    ) {
        self.text = text
        self.status = status
        self.sessionDirectoryName = sessionDirectoryName
        self.sessionName = sessionName
        self.recordedAt = recordedAt
        self.timeSeconds = timeSeconds
        self.by = by
        self.reason = reason
        self.origin = origin
    }

    /// 会話の外でユーザーが手動記録したエントリかどうか。nil は会話からの抽出を表す。
    public var isManual: Bool { origin == .manual }
}

/// 1つの議題と、その決定の変遷。history は常に recordedAt 昇順を保つ約束にする
/// (DecisionLogStore.merge がソートしてから保存するので、読む側は並べ直さなくてよい)。
public struct DecisionTopic: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    /// nil = 一覧・索引に出す。今回はアーカイブする UI は作らないが、型だけ用意する。
    public var archivedAt: Date?
    public var history: [DecisionEntry]

    public init(id: String, title: String, archivedAt: Date? = nil, history: [DecisionEntry] = []) {
        self.id = id
        self.title = title
        self.archivedAt = archivedAt
        self.history = history
    }

    /// 現在の決定。history の末尾(=最新)が無ければ nil。
    public var current: DecisionEntry? { history.last }
}

/// グループ(セッションフォルダ)ごとの決定事項の記録全体。
/// version はこの構造自体の版で、将来フィールドを増やしても古いデータをそのまま読める
/// ようにするための足場(現時点では移行処理は無い)。
public struct DecisionLog: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static var empty: DecisionLog { DecisionLog(version: currentVersion, topics: []) }

    public var version: Int
    public var topics: [DecisionTopic]
    /// 決定事項の取り込み処理(要約後の専用抽出・バックフィル)を実行済みのセッションディレクトリ名。
    /// 決定が1つも見つからなかったセッションもここに入れる。これが無いと「決定ゼロのセッション」が
    /// 毎回バックフィルの対象に数えられ続けてしまう。
    public var extractedSessionDirectories: [String]

    public init(
        version: Int = DecisionLog.currentVersion, topics: [DecisionTopic] = [],
        extractedSessionDirectories: [String] = []
    ) {
        self.version = version
        self.topics = topics
        self.extractedSessionDirectories = extractedSessionDirectories
    }

    private enum CodingKeys: String, CodingKey {
        case version, topics, extractedSessionDirectories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        topics = try container.decode([DecisionTopic].self, forKey: .topics)
        // 旧形式の decisions.json にはこのフィールドが無いため、空配列に落として読む
        // (無ければ全セッションが未取り込み扱いになるだけで、壊れて読めなくなるよりはよい)。
        extractedSessionDirectories =
            try container.decodeIfPresent([String].self, forKey: .extractedSessionDirectories) ?? []
    }
}

// MARK: - グループ画面の絞り込み・並び替え

/// GroupDetailView の「決まったこと」タブが表示のたびに必要とする、絞り込み・並び替え結果一式。
/// フィルタチップの件数からセクション分けまで1回の呼び出しで揃え、呼び出し側(View)が
/// 同じ内容を検索語・状態フィルタ・アーカイブ表示の組み合わせごとに何度も計算し直さずに済む
/// ようにする。並び順・判定条件は元の GroupDetailView の実装をそのまま移したもの
/// (このファイルへ移すにあたって挙動は変えていない)。
public struct DecisionTopicFilterResult: Equatable {
    /// showArchived の母集団の件数。フィルタチップ「すべて」の件数に使う。
    public let visibleCount: Int
    /// showArchived の母集団を DecisionStatus ごとに数えた件数。フィルタチップの件数に使う。
    public let statusCounts: [DecisionStatus: Int]
    /// 検索語・状態フィルタ・アーカイブ表示を適用した議題(並び順は未確定)。
    public let filtered: [DecisionTopic]
    /// filtered を最近動いた順(current.recordedAt の新しい順)に並べたもの。
    public let sorted: [DecisionTopic]
    /// sorted のうち、最新の記録日と current.recordedAt が同じ議題だけ。
    /// 同じ会議由来の議題は recordedAt が完全一致するため、これで「最近の会議で動いた」を切り出せる。
    public let recentlyMoved: [DecisionTopic]
}

extension DecisionLog {
    /// アーカイブ済み議題の総数。showArchived の状態に関わらず一定
    /// (フィルタチップ「アーカイブ」は「切り替えた先に何件あるか」を示すため)。
    public var archivedTopicCount: Int {
        topics.filter { $0.archivedAt != nil }.count
    }

    /// 検索語・状態フィルタ・アーカイブ表示を1回で解決する。GroupDetailView の
    /// visibleTopics / filteredTopics / sortedTopics / recentlyMovedTopics / statusCount が
    /// それぞれ個別に行っていた計算を1箇所にまとめたもの(判定条件・並び順は変えていない)。
    public func filterTopics(
        query: String, status: DecisionStatus?, showArchived: Bool
    ) -> DecisionTopicFilterResult {
        let visible = topics.filter { ($0.archivedAt != nil) == showArchived }

        var statusCounts: [DecisionStatus: Int] = [:]
        for candidate in DecisionStatus.allCases {
            statusCounts[candidate] = visible.filter { $0.current?.status == candidate }.count
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = visible.filter { topic in
            if let status, topic.current?.status != status { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return topic.title.localizedCaseInsensitiveContains(trimmedQuery)
                || (topic.current?.text.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }

        let sorted = filtered.sorted {
            ($0.current?.recordedAt ?? .distantPast) > ($1.current?.recordedAt ?? .distantPast)
        }
        let latest = sorted.compactMap { $0.current?.recordedAt }.max()
        let recentlyMoved = latest.map { latestDate in
            sorted.filter { $0.current?.recordedAt == latestDate }
        } ?? []

        return DecisionTopicFilterResult(
            visibleCount: visible.count, statusCounts: statusCounts,
            filtered: filtered, sorted: sorted, recentlyMoved: recentlyMoved)
    }

    /// メニューパネルの「まだ決まっていないこと」カード用: アーカイブ済みを除き、
    /// 現在の状態が保留・仮のまま持ち越されている議題を新しい順に返す。
    /// 「未決」の定義を View 側に散らさないため、判定はここへ一元化する。
    public func unresolvedTopics() -> [DecisionTopic] {
        topics
            .filter { topic in
                guard topic.archivedAt == nil, let current = topic.current else { return false }
                return current.status == .pending || current.status == .tentative
            }
            .sorted {
                ($0.current?.recordedAt ?? .distantPast) > ($1.current?.recordedAt ?? .distantPast)
            }
    }
}

// MARK: - AI からの差分(デコード専用)

/// 要約 AI が出力する JSON の差分。AI の出力は形式が多少ぶれるため、
/// title と text 以外は寛容にデコードする(未知の status/by で全体が壊れないように)。
public struct DecisionDelta: Decodable, Sendable, Equatable {
    public struct Item: Decodable, Sendable, Equatable {
        public let topicId: String?
        public let title: String
        public let text: String
        public let status: DecisionStatus
        /// "MM:SS" 形式の経過時間文字列。DecisionLogStore.parseTimeSeconds で秒へ変換する。
        public let time: String?
        public let by: DecisionSpeaker?
        public let reason: String?

        private enum CodingKeys: String, CodingKey {
            case topicId, title, text, status, time, by, reason
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            text = try container.decode(String.self, forKey: .text)
            topicId = try container.decodeIfPresent(String.self, forKey: .topicId)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            time = try container.decodeIfPresent(String.self, forKey: .time)

            // 未知の status は「保留」に落とす。AI の勝手な確度で 確定/仮 側へ寄せるよりは、
            // 人が見て気付ける保留のほうが安全なため。
            let rawStatus = try container.decodeIfPresent(String.self, forKey: .status)
            status = rawStatus.flatMap(DecisionStatus.init(rawValue:)) ?? .pending
            let rawBy = try container.decodeIfPresent(String.self, forKey: .by)
            by = rawBy.flatMap(DecisionSpeaker.init(rawValue:))
        }

        public init(
            topicId: String?, title: String, text: String, status: DecisionStatus,
            time: String?, by: DecisionSpeaker?, reason: String?
        ) {
            self.topicId = topicId
            self.title = title
            self.text = text
            self.status = status
            self.time = time
            self.by = by
            self.reason = reason
        }
    }

    public let decisions: [Item]

    private enum CodingKeys: String, CodingKey { case decisions }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // decisions が無い・null なら空差分として扱う(要約 AI が「決定事項なし」を
        // キー省略で表すことがあるため)。
        decisions = try container.decodeIfPresent([Item].self, forKey: .decisions) ?? []
    }

    public init(decisions: [Item]) {
        self.decisions = decisions
    }
}

// MARK: - 永続化と操作

/// グループごとの決定事項ログの保存先・読み書き・マージを一元管理する。
/// 保存先の解決は SessionStore に合わせ(フォルダ名の sanitize は storedName を通す)、
/// SessionStore.sessionsDirectory 以外にパスを書かない。
public enum DecisionLogStore {
    private static let fileName = "decisions.json"

    public enum LoadError: LocalizedError {
        case corrupted(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .corrupted(let underlying):
                return "決定事項の記録を読み込めませんでした: \(underlying.localizedDescription)"
            }
        }
    }

    /// appendManualEntry の失敗。議題が見つからない場合、黙って何もせず返すと
    /// ユーザーは「記録したつもり」のまま気づけないため、必ず throw する。
    public enum ManualEntryError: LocalizedError {
        case topicNotFound(topicId: String)

        public var errorDescription: String? {
            switch self {
            case .topicNotFound(let topicId):
                return "議題が見つかりませんでした: \(topicId)"
            }
        }
    }

    private static func directory(forFolder folder: String) -> URL {
        SessionStore.sessionsDirectory
            .appendingPathComponent(SessionStore.storedName(for: folder), isDirectory: true)
    }

    /// decisions.json の絶対パス。load/save の解決に使う。
    public static func fileURL(folder: String) -> URL {
        directory(forFolder: folder).appendingPathComponent(fileName)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 記録を読む。ファイルが無い(初回)場合は空の記録を返すが、
    /// ファイルはあるのに読めない(壊れた JSON)場合は throw する。
    /// ここを黙って空にすると、次の保存でユーザーの過去の記録がまるごと消える。
    public static func load(folder: String) throws -> DecisionLog {
        let url = fileURL(folder: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(DecisionLog.self, from: data)
        } catch {
            throw LoadError.corrupted(underlying: error)
        }
    }

    /// 記録を読む。load と違い、読み込みに失敗した場合も空の記録を返す(throw しない)。
    /// 決定事項の記録を「無ければ空」として扱ってよい場面専用(要約プロンプトへの既存議題
    /// 添付・バックフィルの取り込み済み判定など、記録を読めないこと自体が処理を止める理由には
    /// ならない場面)。壊れた JSON などで読み込みに失敗したことはログに残す
    /// (黙って空にすると、記録が消えていること自体に誰も気づけないため)。
    /// UI 側で読み込み失敗をエラーとして扱いたい場面(GroupDetailView / SessionDetailView の
    /// 検品操作)では、こちらではなく load を使うこと。
    public static func loadOrEmpty(folder: String) -> DecisionLog {
        do {
            return try load(folder: folder)
        } catch {
            decisionLogStoreLogger.error(
                "decisions.json の読み込みに失敗: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }

    /// 記録を保存する。SessionStore の他の書き込み(writeFolderOrder 等)と同じく
    /// options: .atomic で書き、書き込み途中でクラッシュしても既存ファイルを壊さない。
    public static func save(_ log: DecisionLog, folder: String) throws {
        let dir = directory(forFolder: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(log).write(to: fileURL(folder: folder), options: .atomic)
    }

    /// "MM:SS" を経過秒に変換する。不正な形式はクラッシュさせず nil に落とす
    /// (AI の出力は完全に信用しない)。
    public static func parseTimeSeconds(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] >= 0, (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// AI からの差分を取り込む。同じセッションの要約を何度再生成しても結果が変わらないよう、
    /// 必ず「そのセッション由来のエントリを全部消してから積み直す」置換マージにする
    /// (積み上げ式にすると、再生成のたびに同じ決定が重複して並んでしまう)。
    ///
    /// 不変条件: 1つの議題(DecisionTopic)の history には、同じ sessionDirectoryName の
    /// 会話由来(origin == nil)エントリが最大1件しか無い。変遷 UI はこの history を
    /// 「前回の決定 → 今回の決定」の打ち消し(置き換え)として描くため、同じ会議由来のエントリが
    /// 2件以上並ぶと、実際には「同じ会議内の複数の言明」でしかないものが「一度合意してすぐ覆した」
    /// ように見えてしまう。この不変条件は、抽出プロンプト側(decisions フェンスに同じ議題を
    /// 2回書かない指示)と、下の束ね処理(AI が指示を守れなかった場合の保険)の2段で保っている。
    /// 手動エントリ(origin == .manual、DecisionLogStore.appendManualEntry 参照)は
    /// この不変条件の対象外(会話由来ではなく、sessionDirectoryName も空文字固定で
    /// 実在のセッションと衝突しない)。以下の置換削除が origin == nil だけを対象にしているのは
    /// そのため。
    @discardableResult
    public static func merge(
        delta: DecisionDelta, folder: String,
        sessionDirectoryName: String, sessionName: String, sessionStartedAt: Date
    ) throws -> DecisionLog {
        var log = try load(folder: folder)

        // 会話由来(origin == nil)のエントリだけを置換対象にする。手動エントリは
        // ユーザーが意図して記録したものであり、会話の再抽出のたびに消えては困るため、
        // origin が付いている時点で無条件に保護する。
        for index in log.topics.indices {
            log.topics[index].history.removeAll {
                $0.origin == nil && $0.sessionDirectoryName == sessionDirectoryName
            }
        }

        // 同じ議題へ解決される item を先にまとめてから1エントリを作る(上の不変条件を守るための保険)。
        // 解決先の判定(topicId 一致 → title 一致 → 新規)はマージ前の log.topics に対して行う。
        // 新規議題になる item は、まだ topics に存在しないため title をキーに束ねる
        // (同じ delta 内で同名の新規議題を作る item はすべて同じ新規議題に収束する)。
        enum ResolutionKey: Hashable {
            case existingTopic(Int)
            case newTopic(String)
        }
        var groupedItems: [ResolutionKey: [DecisionDelta.Item]] = [:]
        var groupOrder: [ResolutionKey] = []
        for item in delta.decisions {
            let key: ResolutionKey
            if let topicId = item.topicId,
                let index = log.topics.firstIndex(where: { $0.id == topicId }) {
                key = .existingTopic(index)
            } else if let index = log.topics.firstIndex(where: { $0.title == item.title }) {
                key = .existingTopic(index)
            } else {
                key = .newTopic(item.title)
            }
            if groupedItems[key] == nil { groupOrder.append(key) }
            groupedItems[key, default: []].append(item)
        }

        for key in groupOrder {
            // groupedItems[key] はここまでの積み立てで必ず1件以上入っている。
            let items = groupedItems[key]!
            let entry = mergedEntry(
                from: items, sessionDirectoryName: sessionDirectoryName, sessionName: sessionName,
                sessionStartedAt: sessionStartedAt)
            switch key {
            case .existingTopic(let index):
                log.topics[index].history.append(entry)
            case .newTopic(let title):
                log.topics.append(
                    DecisionTopic(id: UUID().uuidString, title: title, history: [entry]))
            }
        }

        sortHistories(&log)
        log.topics.removeAll { $0.history.isEmpty }

        // 決定が1つも無かった差分でもここへ積む。「取り込み済み」という事実は決定の有無と
        // 独立していて、これが無いとバックフィルが決定ゼロのセッションを毎回対象に数え続ける。
        if !log.extractedSessionDirectories.contains(sessionDirectoryName) {
            log.extractedSessionDirectories.append(sessionDirectoryName)
        }

        try save(log, folder: folder)
        return log
    }

    /// 同じ議題へ解決された同一セッション由来の item 群を、1つの DecisionEntry へ束ねる。
    /// merge の不変条件(1議題1セッションにつき history は最大1件)を保つための集約ルール:
    /// - text: 各 item の text を改行で連結する(UI の Text は複数行を扱えるため、
    ///   個々の言明を消さずに1エントリへ収める)。
    /// - status: 最後の item の値(会議の最後に語られた確度が、そのセッション時点での最終状態)。
    /// - timeSeconds: 最初に時刻が取れた item の値(その議題の話が始まった位置へジャンプするのが自然)。
    /// - by / reason: 最初に取れた非 nil 値。
    private static func mergedEntry(
        from items: [DecisionDelta.Item], sessionDirectoryName: String, sessionName: String,
        sessionStartedAt: Date
    ) -> DecisionEntry {
        let text = items.map { $0.text }.joined(separator: "\n")
        let timeSeconds = items.lazy.compactMap { $0.time.flatMap(parseTimeSeconds) }.first
        let by = items.lazy.compactMap { $0.by }.first
        let reason = items.lazy.compactMap { $0.reason }.first
        return DecisionEntry(
            // 呼び出し元(merge)は空でない items しか渡さないため force unwrap で問題ない。
            text: text, status: items.last!.status,
            sessionDirectoryName: sessionDirectoryName, sessionName: sessionName,
            recordedAt: sessionStartedAt, timeSeconds: timeSeconds, by: by, reason: reason)
    }

    /// セッションのリネーム後、このグループの記録内で旧ディレクトリ名を指している参照
    /// (履歴エントリの sessionDirectoryName・表示用の sessionName と extractedSessionDirectories)を
    /// 新しい値へ書き換える。追従させないと、リネーム後にバックフィルが未抽出と誤判定して再抽出し
    /// (旧名・新名で履歴が重複する)、セッション詳細画面や履歴ジャンプの照合も切れ、変遷カードの
    /// 由来表示も古いままになる。該当が1件も無ければ保存せずそのまま返す。
    @discardableResult
    public static func retargetSessionDirectory(
        folder: String, from oldDirectoryName: String, to newDirectoryName: String,
        newSessionName: String
    ) throws -> DecisionLog {
        var log = try load(folder: folder)
        guard oldDirectoryName != newDirectoryName else { return log }

        var changed = false
        for topicIndex in log.topics.indices {
            for entryIndex in log.topics[topicIndex].history.indices
            where log.topics[topicIndex].history[entryIndex].sessionDirectoryName == oldDirectoryName {
                log.topics[topicIndex].history[entryIndex].sessionDirectoryName = newDirectoryName
                log.topics[topicIndex].history[entryIndex].sessionName = newSessionName
                changed = true
            }
        }
        for index in log.extractedSessionDirectories.indices
        where log.extractedSessionDirectories[index] == oldDirectoryName {
            log.extractedSessionDirectories[index] = newDirectoryName
            changed = true
        }

        guard changed else { return log }
        try save(log, folder: folder)
        return log
    }

    /// 会話の外(Slack や PR レビュー等)で決まった・不要になったことを、ユーザーが手動で記録する。
    /// 状態を直接書き換えるのではなく、history へ手動エントリを1件追記する
    /// (経緯を消さずに「前回の決定 → 今回の決定」の変遷として残す、既存の history の
    /// 設計をそのまま使うため)。追記したエントリが recordedAt 最新なら current(=history.last)
    /// になり、議題の表示上の状態・内容はそのまま更新される。
    ///
    /// 議題が見つからない場合は黙って何もしない(=ユーザーが記録したつもりで実は残っていない)
    /// を避けるため throw する。
    @discardableResult
    public static func appendManualEntry(
        folder: String, topicId: String, text: String, status: DecisionStatus,
        reason: String? = nil
    ) throws -> DecisionLog {
        var log = try load(folder: folder)
        guard let index = log.topics.firstIndex(where: { $0.id == topicId }) else {
            throw ManualEntryError.topicNotFound(topicId: topicId)
        }

        let entry = DecisionEntry(
            text: text, status: status, sessionDirectoryName: "", sessionName: "",
            recordedAt: Date(), timeSeconds: nil, by: nil, reason: reason, origin: .manual)
        log.topics[index].history.append(entry)

        sortHistories(&log)
        try save(log, folder: folder)
        return log
    }

    /// 検品用: 「記録に残さない」。該当議題の該当セッション由来エントリを消し、
    /// 履歴が空になった議題はそのまま残さず削除する。
    @discardableResult
    public static func removeEntries(
        folder: String, sessionDirectoryName: String, topicID: String
    ) throws -> DecisionLog {
        var log = try load(folder: folder)
        guard let index = log.topics.firstIndex(where: { $0.id == topicID }) else { return log }
        log.topics[index].history.removeAll { $0.sessionDirectoryName == sessionDirectoryName }
        if log.topics[index].history.isEmpty {
            log.topics.remove(at: index)
        }
        try save(log, folder: folder)
        return log
    }

    /// グループ画面の「アーカイブする」/「アーカイブから戻す」。archivedAt は
    /// 「いつ隠したか」の記録ではなく「隠れているか」の真偽値としてだけ使うため、
    /// 実際の日時は問わず Date() を積む(戻す側は nil に戻す)。
    @discardableResult
    public static func setArchived(
        folder: String, topicID: String, archived: Bool
    ) throws -> DecisionLog {
        var log = try load(folder: folder)
        guard let index = log.topics.firstIndex(where: { $0.id == topicID }) else { return log }
        log.topics[index].archivedAt = archived ? Date() : nil
        try save(log, folder: folder)
        return log
    }

    /// 検品用: 「内容を修正」。同じセッション由来のエントリが複数あれば最後(=最新)を書き換える。
    @discardableResult
    public static func updateEntryText(
        folder: String, sessionDirectoryName: String, topicID: String, newText: String
    ) throws -> DecisionLog {
        var log = try load(folder: folder)
        guard let topicIndex = log.topics.firstIndex(where: { $0.id == topicID }) else {
            return log
        }
        guard
            let entryIndex = log.topics[topicIndex].history.lastIndex(where: {
                $0.sessionDirectoryName == sessionDirectoryName
            })
        else { return log }
        log.topics[topicIndex].history[entryIndex].text = newText
        try save(log, folder: folder)
        return log
    }

    /// 質問パネル添付用の圧縮索引。アーカイブ済み議題は除外し、1議題1行で現在の決定だけ見せる
    /// (履歴全部を渡すとプロンプトが肥大するため、現在値だけに絞る)。各行の先頭 [ ] に
    /// topic.id を入れる。AI が経緯を問われた際、この id をそのまま
    /// ```decision-history フェンス(AppModel.codeImpactDecisionContext 参照)へ積むことで、
    /// アプリ側が decisions.json の記録から直接タイムラインを描ける(AI に日付・理由・
    /// セッション名の整形を任せない)。
    public static func compactIndex(_ log: DecisionLog) -> String {
        let lines = log.topics
            .filter { $0.archivedAt == nil }
            .compactMap { topic -> String? in
                guard let current = topic.current else { return nil }
                let date = dateOnlyFormatter.string(from: current.recordedAt)
                return
                    "- [\(topic.id)] \(topic.title): \(current.text) (\(current.status.displayName)、最終更新 \(date))"
            }
        return lines.joined(separator: "\n")
    }

    /// 抽出プロンプト用の既存議題一覧。アーカイブ済みも含める(AI が同名の議題を
    /// 新規として増殖させないよう、見えなくなった議題の存在も伝える必要があるため)。
    public static func promptTopicList(_ log: DecisionLog) -> String {
        log.topics.map { "- \($0.id): \($0.title)" }.joined(separator: "\n")
    }

    /// 各議題の history を recordedAt 昇順、同値なら timeSeconds 昇順(nil は先頭扱い)に揃える。
    private static func sortHistories(_ log: inout DecisionLog) {
        for index in log.topics.indices {
            log.topics[index].history.sort { lhs, rhs in
                if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
                return (lhs.timeSeconds ?? -1) < (rhs.timeSeconds ?? -1)
            }
        }
    }

    /// compactIndex の「最終更新 YYYY-MM-DD」表示用。SessionStore.makeFormatter と同じく
    /// タイムゾーンは明示せず、端末のカレンダー表示と揃える。
    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
