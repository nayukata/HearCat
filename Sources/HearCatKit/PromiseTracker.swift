import Foundation

/// グループ質問の材料見出し(「## [M3] 名前 (日付)」)に振る会議の識別子と、その解決先。
/// 日付の計算は AI にさせず、AI が返した識別子をアプリ側でここから引く。
public struct PromiseMeeting: Equatable, Sendable {
    public let sessionID: String
    /// セッション ID は改名で変わりうる。ID で引けないときに folder と start で同じ会議を
    /// 引き直すために持つ(別のグループへ移した会議は追わない)。
    public let folder: String?
    public let start: Date

    public init(sessionID: String, folder: String? = nil, start: Date) {
        self.sessionID = sessionID
        self.folder = folder
        self.start = start
    }
}

/// 会議の識別子の振り方。開始日時の古い順に M1, M2, ... を振る(同時刻はセッション ID 順)。
/// 材料を作る側(AppModel.groupQuestionMaterial)と、フェンスを解決する側
/// (AppModel.codeImpactGroupMeetings)が同じ並びを得るよう、振り方はここ1か所に置く。
/// 材料に載らなかった(容量で省略された)会議にも番号は振る: 番号を材料の採否で
/// 振り直すと、AI が見た番号と解決先がずれるため。
public enum PromiseMeetingID {
    public static func assign(_ sessions: [(id: String, start: Date)]) -> [String: String] {
        let ordered = sessions.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.id < rhs.id
        }
        var result: [String: String] = [:]
        for (index, session) in ordered.enumerated() {
            result[session.id] = "M\(index + 1)"
        }
        return result
    }

    /// AI が返した識別子の表記ゆれ(前後の空白・小文字・角括弧付き)を吸収する。
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]")))
            .uppercased()
    }
}

/// 約束の追跡の1つの時点。time は会議内の発言時刻(HH:MM:SS)。AI が省略・不正な値を
/// 返したときは nil で、タップ時は会議の頭へ戻る。
public struct PromiseMoment: Equatable, Sendable {
    public let meeting: PromiseMeeting
    public let time: String?

    public init(meeting: PromiseMeeting, time: String?) {
        self.meeting = meeting
        self.time = time
    }
}

public struct PromiseItem: Equatable, Sendable {
    public let label: String
    public let owner: DeadlineOwner?
    public let made: PromiseMoment
    /// 済んだ会議。nil は未完了(今日まで伸びる矢印で描く)。
    public let done: PromiseMoment?

    public init(label: String, owner: DeadlineOwner?, made: PromiseMoment, done: PromiseMoment?) {
        self.label = label
        self.owner = owner
        self.made = made
        self.done = done
    }
}

/// ```promises フェンス(約束の追跡)をパースした結果。
public struct PromiseTracker: Equatable, Sendable {
    /// 見出し(AI が付けた場合のみ)。無ければ View 側が既定の文言を出す。
    public let title: String?
    /// 約束した会議の古い順に並べた最大 maximumItems 件(溢れたときは未完了を優先して残す)。
    public let items: [PromiseItem]

    public static let maximumItems = 8
    /// 名前は PromiseTrackerView のラベル列(幅132pt)に、callout(12pt)の太字で2行以内に
    /// 収まる文字数。全角1字は約12ptなので1行11字、2行で22字。これを超える項目は
    /// 「…」で切って見せると意味が変わるため、切らずに捨てる(プロンプトの14字はその手前の目安)。
    public static let maximumLabelLength = 22

    public init(title: String?, items: [PromiseItem]) {
        self.title = title
        self.items = items
    }

    /// AI の出力は項目ごと・フィールドごとに型が崩れうる。1つの崩れで全体を落とさないよう、
    /// 項目は1件ずつ、title / who / 時刻は型違いを無視して読む。落とすのは label が読めない項目と、
    /// 約束・完了の識別子が文字列でない項目だけ(後者は parse で捨てる)。
    private struct JSON: Decodable {
        let title: String?
        let items: [Item]

        private enum Keys: String, CodingKey { case title, items }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
            items = try container.decode([Lossy<Item>].self, forKey: .items).compactMap(\.value)
        }

        struct Lossy<Value: Decodable>: Decodable {
            let value: Value?
            init(from decoder: Decoder) { value = try? Value(from: decoder) }
        }

        struct Item: Decodable {
            let label: String
            let who: String?
            let made: String?
            let madeAt: String?
            let done: String?
            let doneAt: String?
            /// done が書かれているのに文字列でない(null は未完了なので含めない)。
            /// 未完了として残すと済んだ根拠を示した項目が誤って未完了に見えるため、parse で捨てる。
            let doneIsInvalid: Bool

            private enum Keys: String, CodingKey { case label, who, made, madeAt, done, doneAt }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                label = try container.decode(String.self, forKey: .label)
                who = (try? container.decodeIfPresent(String.self, forKey: .who)) ?? nil
                made = (try? container.decodeIfPresent(String.self, forKey: .made)) ?? nil
                madeAt = (try? container.decodeIfPresent(String.self, forKey: .madeAt)) ?? nil
                doneAt = (try? container.decodeIfPresent(String.self, forKey: .doneAt)) ?? nil
                if container.contains(.done), (try? container.decodeNil(forKey: .done)) != true {
                    let value = try? container.decode(String.self, forKey: .done)
                    done = value
                    doneIsInvalid = value == nil
                } else {
                    done = nil
                    doneIsInvalid = false
                }
            }
        }
    }

    /// フェンスの中身が JSON として最低限の形になっているかだけを見る軽い判定
    /// (DeadlineCalendar.isWellFormed と同じ役割)。
    public static func isWellFormed(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(JSON.self, from: data)
        else { return false }
        return decoded.items.contains { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// "HH:MM:SS" 以外(桁違い・範囲外)は nil。会議を特定する識別子と違い、時刻の不正は
    /// 項目を捨てる理由にしない(会議の頭へ戻れば足りる)。
    private static func validTime(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ $0.count == 2 }),
            let hour = Int(parts[0]), let minute = Int(parts[1]), let second = Int(parts[2]),
            (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second)
        else { return nil }
        return raw
    }

    /// meeting は識別子("M3")から会議を引く関数(引けなければ nil)。壊れた JSON・items キー無し・
    /// 有効な項目が1件も無い場合は nil を返し、呼び出し側は何も描かない。
    /// 次の項目はその項目だけ捨てる: label が空か長すぎる / made が引けない / done が
    /// 書いてあるのに引けない / 約束と完了が同じ会議 / 完了が約束より前(同時刻含む)。
    ///
    /// フェンスの言語名(promises)と JSON のキー(title / items / label / who / made /
    /// madeAt / done / doneAt)は AgentCodeImpactAnalyzer.promisesParagraph の出力契約と
    /// 手打ちで揃えているので、変える場合は両方直すこと。
    public static func parse(_ json: String, meeting: (String) -> PromiseMeeting?) -> PromiseTracker? {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(JSON.self, from: data)
        else { return nil }

        let items: [PromiseItem] = decoded.items.compactMap { item -> PromiseItem? in
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= maximumLabelLength else { return nil }
            guard let madeRaw = item.made, let madeMeeting = meeting(PromiseMeetingID.normalize(madeRaw))
            else { return nil }
            let made = PromiseMoment(meeting: madeMeeting, time: validTime(item.madeAt))

            guard !item.doneIsInvalid else { return nil }
            var done: PromiseMoment?
            if let doneRaw = item.done {
                guard let doneMeeting = meeting(PromiseMeetingID.normalize(doneRaw)),
                    doneMeeting.sessionID != madeMeeting.sessionID,
                    doneMeeting.start > madeMeeting.start
                else { return nil }
                done = PromiseMoment(meeting: doneMeeting, time: validTime(item.doneAt))
            }
            let owner = item.who.flatMap(DeadlineOwner.init(rawValue:))
            return PromiseItem(label: label, owner: owner, made: made, done: done)
        }
        guard !items.isEmpty else { return nil }

        // 溢れたときは未完了を残す(まだ追うべきものが消えると質問の答えにならない)。
        // 各群の中は AI の出した順のまま、そのあと約束した会議の日付順に並べ直す。
        let chosen = Array((items.filter { $0.done == nil } + items.filter { $0.done != nil }).prefix(maximumItems))
        // sorted は安定ではないため、同じ会議で約束した項目は元の並び(選んだ順)を保つ。
        let ordered = chosen.enumerated().sorted { lhs, rhs in
            if lhs.element.made.meeting.start != rhs.element.made.meeting.start {
                return lhs.element.made.meeting.start < rhs.element.made.meeting.start
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let title = decoded.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PromiseTracker(
            title: (title?.isEmpty == false) ? title : nil,
            items: ordered)
    }
}

/// 約束の追跡の横軸(全行共通の日付軸)。始点は一番早い約束の日、終点は「一番遅い完了・約束の日と
/// 今日(未完了があるときだけ)のうち遅い方」。全部が同じ日になっても幅がゼロにならないよう、
/// 終点は始点より必ず1日以上後ろにする。
public struct PromiseAxis: Equatable, Sendable {
    public let start: Date
    public let end: Date
    /// 未完了の矢印の先端。未完了が無ければ nil。
    public let today: Date?

    public init(items: [PromiseItem], today: Date) {
        let calendar = Calendar.current
        let todayDay = calendar.startOfDay(for: today)
        let madeDays = items.map { calendar.startOfDay(for: $0.made.meeting.start) }
        let doneDays = items.compactMap { $0.done.map { calendar.startOfDay(for: $0.meeting.start) } }
        let hasPending = items.contains { $0.done == nil }
        let startDay = madeDays.min() ?? todayDay
        var farthest = (madeDays + doneDays).max() ?? startDay
        if hasPending { farthest = max(farthest, todayDay) }
        self.start = startDay
        self.today = hasPending ? todayDay : nil
        if farthest > startDay {
            self.end = farthest
        } else {
            self.end = calendar.date(byAdding: .day, value: 1, to: startDay) ?? startDay.addingTimeInterval(86400)
        }
    }

    /// date の横軸上の位置(0...1)。日単位に丸めてから比率を取る。
    public func fraction(of date: Date) -> Double {
        let day = Calendar.current.startOfDay(for: date)
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(day.timeIntervalSince(start) / total, 0), 1)
    }
}

/// 質問文が約束・宿題の進み具合を尋ねているかの判定。単一の会議を対象にした質問で、
/// 前の会議を材料に足して ```promises を出すかどうかを決める。
///
/// 外れ方の重さが非対称なため、語は広めに取る: 誤って発動しても材料が増えるだけだが、
/// 発動しなければ絵が出ない。ただし「どうなった」「終わった」のように約束と無関係な質問にも
/// 普通に出る語は、単独では発動させない(「価格はどうなった?」で毎回長い材料になる)。
/// 「言ってた」「前回」単独も同じ理由で発動しない。
public enum PromiseQuestion {
    /// 単独で約束・宿題の質問と言える語。
    static let strongWords: [String] = [
        "宿題", "約束", "やると言", "やるって", "積み残", "やり残", "持ち帰", "todo", "タスク",
        "アクションアイテム", "ネクストアクション", "頼まれ",
    ]
    /// 進み具合を表す語。単独では約束と無関係な質問にも出るため、強い語か文脈語と一緒のときだけ数える。
    static let progressWords: [String] = ["どうなっ", "終わっ", "完了", "進捗", "進み具合", "済ん", "済み"]
    /// 過去の発言を指す語。進み具合の語と組んで初めて意味を持つ。
    static let contextWords: [String] = ["前回", "言って", "言った"]

    /// 全角半角・大文字小文字を畳んでから部分一致で見る。
    public static func asksAboutPromises(_ question: String?) -> Bool {
        guard let question else { return false }
        let folded = question.folding(options: [.widthInsensitive, .caseInsensitive], locale: nil)
        if strongWords.contains(where: { folded.contains($0) }) { return true }
        return progressWords.contains { folded.contains($0) }
            && contextWords.contains { folded.contains($0) }
    }
}
