import Foundation

/// ```deadlines フェンス(期限の暦)の1項目の種類。締切(やることの期限)か、次回の会議
/// のような予定かでマーカーの見た目を変える(DeadlineCalendarView 参照)。
public enum DeadlineKind: String, Equatable, Sendable {
    case due
    case event
}

/// ```deadlines フェンスの1項目の担当。AI 側の "me" / "you" にそのまま対応する
/// (文字起こしの「自分」= 質問者本人、と同じ意味)。省略・不正な値は nil(担当不明)。
public enum DeadlineOwner: String, Equatable, Sendable {
    case me
    case you
}

/// 期限の暦の1項目。at(経過秒)と due(その日の0時)は役割が違う: due は横軸の位置
/// (日単位)、at は文字起こしへジャンプする実際の発言時刻。at はセッション開始からの
/// 経過秒で持ち、壁時計文字列への変換は表示側(DeadlineCalendarView)の責務にする
/// (TopicWeight.firstStart が壁時計のまま持つのと違い、こちらは parse 時点で
/// offset クロージャによる妥当性検証を兼ねるため経過秒で持つ)。
public struct DeadlineItem: Equatable, Sendable {
    public let label: String
    public let owner: DeadlineOwner?
    public let kind: DeadlineKind
    public let at: TimeInterval
    public let due: Date

    public init(label: String, owner: DeadlineOwner?, kind: DeadlineKind, at: TimeInterval, due: Date) {
        self.label = label
        self.owner = owner
        self.kind = kind
        self.at = at
        self.due = due
    }
}

/// ```deadlines フェンスの中身(AI が話題ごとの期限だけを出したもの)をパースした結果。
public struct DeadlineCalendar: Equatable, Sendable {
    /// 見出し(AI が付けた場合のみ)。無ければ View 側が「期限の早い順」を出す。
    public let title: String?
    /// 期限の早い順(同日は at の早い順)に並べた最大6件。
    public let items: [DeadlineItem]

    public init(title: String?, items: [DeadlineItem]) {
        self.title = title
        self.items = items
    }

    private struct JSON: Decodable {
        let title: String?
        let items: [Item]
        struct Item: Decodable {
            let label: String
            let who: String?
            // at・due・kind は項目ごとに欠落・不正がありうる(その項目だけを捨てたい)ため、
            // JSON 全体のデコードを失敗させないよう optional にする(label だけ必須)。
            let at: String?
            let due: String?
            let kind: String?
        }
    }

    /// "yyyy-MM-dd"(ゼロ埋め必須)だけを受け付ける、Calendar.current のタイムゾーンでの
    /// その日の0時。DateFormatter(dateFormat: "yyyy-MM-dd")は isLenient = false でも
    /// "2026/09/10" のような区切り違いを黙って受理してしまう実挙動があるため、
    /// DateFormatter を使わず自前で桁と区切りを検証してから Calendar で組み立てる。
    ///
    /// Calendar.date(from:) は月末を超えた日(例: 2月30日)を実在しない日として拒否せず、
    /// 黙って繰り上げる(2026-02-30 → 3月2日)。実在しない日付を別の実在する日付として
    /// 受理してしまうと、AI が壊れた日付を出したときに違う日の期限として表示してしまうため、
    /// 組み立てた Date から年月日を取り戻し、入力の年月日とすべて一致する場合だけ有効とする。
    private static func parseDueDate(_ string: String) -> Date? {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        let calendar = Calendar.current
        guard let date = calendar.date(from: components) else { return nil }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year, normalized.month == month, normalized.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// フェンスの中身が JSON として最低限の形になっているかだけを見る、時刻変換より前の
    /// 軽い判定(TopicWeights.isWellFormed と同じ役割。呼び出し側の使い分けもそちらを参照)。
    public static func isWellFormed(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(JSON.self, from: data)
        else { return false }
        return decoded.items.contains { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// フェンスの中身(1行JSON)をパースする。JSON として壊れている・items キーが無い・
    /// 有効な項目が1件も無い場合は nil を返し、呼び出し側は通常のコード表示にフォールバックする
    /// (TopicWeights.parse と同じ方針)。
    ///
    /// offset は "HH:MM:SS" 形式の壁時計をセッション開始からの経過秒へ変換する関数
    /// (呼び出し側が TranscriptParser.offsetSeconds を渡す想定)。at が変換できない・
    /// due が無い/壊れている・label が空の項目はその項目だけ捨てる。kind が "due"/"event"
    /// 以外(省略含む)は due 扱い、who が "me"/"you" 以外(省略含む)は nil 扱いにする。
    ///
    /// フェンスの言語名(deadlines)と JSON のキー(title / items / label / who / at / due / kind)は
    /// AgentCodeImpactAnalyzer.questionPrompt の出力契約と手打ちで揃えているので、
    /// 変える場合は両方直すこと。
    public static func parse(_ json: String, offset: (String) -> TimeInterval?) -> DeadlineCalendar? {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(JSON.self, from: data)
        else { return nil }

        let items: [DeadlineItem] = decoded.items.compactMap { item -> DeadlineItem? in
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            guard let atString = item.at, let at = offset(atString) else { return nil }
            guard let dueString = item.due, let due = parseDueDate(dueString) else { return nil }
            let owner = item.who.flatMap(DeadlineOwner.init(rawValue:))
            let kind = item.kind.flatMap(DeadlineKind.init(rawValue:)) ?? .due
            return DeadlineItem(label: label, owner: owner, kind: kind, at: at, due: due)
        }
        guard !items.isEmpty else { return nil }

        let sorted = items.sorted { lhs, rhs in
            if lhs.due != rhs.due { return lhs.due < rhs.due }
            return lhs.at < rhs.at
        }
        let title = decoded.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DeadlineCalendar(
            title: (title?.isEmpty == false) ? title : nil,
            items: Array(sorted.prefix(6)))
    }
}

/// 期限の暦の横軸(始点・終点)。始点は会議の日の0時、終点は「一番遅い期限と今日のうち
/// 遅い方」に1日分の余白を足した日。始点と終点が同じ日にならないよう、常に +1日する
/// (最遅の期限・今日がどちらも会議当日でも、終点は翌日になり区間の幅がゼロにならない)。
public struct DeadlineAxis: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(sessionDay: Date, today: Date, items: [DeadlineItem]) {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: sessionDay)
        let todayDay = calendar.startOfDay(for: today)
        let latestDue = items.map(\.due).max() ?? startDay
        let farthest = max(latestDue, todayDay)
        self.start = startDay
        self.end = calendar.date(byAdding: .day, value: 1, to: farthest) ?? farthest.addingTimeInterval(86400)
    }

    /// date の横軸上の位置(0...1)。date は日単位(startOfDay)で丸めてから比率を取る。
    public func fraction(of date: Date) -> Double {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        let elapsed = day.timeIntervalSince(start)
        return min(max(elapsed / total, 0), 1)
    }
}

/// 期限の暦のラベル配置(上下交互・同日積み)を計算する純粋関数。View 側(SwiftUI)から
/// 独立させ、Kit 側でテストできるようにする。
public enum DeadlineCalendarLayout {
    /// 名前ラベルを線のどちら側に置くか。
    public enum Side: Equatable, Sendable {
        case above
        case below
    }

    /// 1項目分の配置結果。side は上下、stackIndex は同じ due の中で何番目か(0始まり。
    /// 表示側はこれを使って段数分だけ線から遠ざける)。
    public struct Placement: Equatable, Sendable {
        public let side: Side
        public let stackIndex: Int

        public init(side: Side, stackIndex: Int) {
            self.side = side
            self.stackIndex = stackIndex
        }
    }

    /// items は期限の早い順(同日は at の早い順、DeadlineCalendar.parse の並びのまま)である
    /// ことを前提にする。上下の交互は「異なる期限日が何番目に現れたか」で数える(項目の通し
    /// 番号では数えない)。項目の通し番号で数えると、同じ日が複数件続いた直後の次の日が
    /// たまたま同じ側になってしまい(例: 1件目下・2件目〈同日〉下・3件目〈翌日〉下)、
    /// 交互に上下させたい元の目的(隣り合う日のラベルが重ならないようにする)を果たせない。
    /// 同じ due の項目は、その中で最初に現れた項目の側を引き継ぐ(その項目自体は交互判定に
    /// 加えない)。最初の期限日(dueGroupIndex == 0)は上(.above)から始まる。
    public static func placements(for items: [DeadlineItem]) -> [Placement] {
        var sideByDue: [Date: Side] = [:]
        var stackCountByDue: [Date: Int] = [:]
        var dueGroupIndex = 0
        return items.map { item in
            let side: Side
            if let existing = sideByDue[item.due] {
                side = existing
            } else {
                side = dueGroupIndex.isMultiple(of: 2) ? .above : .below
                sideByDue[item.due] = side
                dueGroupIndex += 1
            }
            let stackIndex = stackCountByDue[item.due, default: 0]
            stackCountByDue[item.due] = stackIndex + 1
            return Placement(side: side, stackIndex: stackIndex)
        }
    }

    /// 横軸上の位置に応じたラベルの水平アンカー。中央揃えのままだと、端に近い項目
    /// (会議の日・今日の点・期限が左右の余白に近いとき)のラベルが絵の外へはみ出す
    /// (実機で確認)。端から一定の範囲は、その項目の点をラベルの外側の辺として使う
    /// (左端なら左辺、右端なら右辺)ことではみ出しを防ぐ。
    ///
    /// fraction(0...1の比率)ではなく px で判定する: 比率のしきい値だと、絵の幅が変わる
    /// たびに「ラベルの半幅がその幅の何%を占めるか」も変わり、狭い幅(パネルの最小幅相当)
    /// では固定の比率しきい値だけではみ出しを防ぎきれない・逆に広い幅では余分に端揃えが
    /// 効きすぎる、という食い違いが起きるため。
    public enum Anchor: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    /// x はラベルが指す点の横軸上の位置(0 が横軸の左端)、width は横軸の実効幅
    /// (DeadlineCalendarView の左右余白 40pt を除いた、印が実際に動く範囲の幅)、
    /// halfLabelWidth はラベルの想定半幅。x を中心にラベルを置いたとき、その左辺が
    /// 横軸の左端(0)より外に出るなら leading、右辺が右端(width)より外に出るなら
    /// trailing、どちらでもなければ center。
    public static func labelAnchor(x: Double, width: Double, halfLabelWidth: Double) -> Anchor {
        if x - halfLabelWidth < 0 { return .leading }
        if x + halfLabelWidth > width { return .trailing }
        return .center
    }
}
