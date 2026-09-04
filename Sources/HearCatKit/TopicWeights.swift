import Foundation

/// 話題ごとの言及時間。質問応答パネルの ```weights フェンス(重みの棒)が表示する 1 行分。
/// 回数(mentions)と合計時間(seconds)は AI ではなくアプリ側(parse)が文字起こしの実時刻
/// から測る。firstStart は最初に言及した区間の開始を壁時計表記のまま持ち(ジャンプ先に使う。
/// 経過秒への変換は表示側の責務で、TranscriptWriter が書く時刻表記とそのまま比較できるよう
/// 壁時計のままにしている)。
public struct TopicWeight: Equatable, Sendable {
    public let label: String
    public let mentions: Int
    public let seconds: TimeInterval
    public let firstStart: String

    public init(label: String, mentions: Int, seconds: TimeInterval, firstStart: String) {
        self.label = label
        self.mentions = mentions
        self.seconds = seconds
        self.firstStart = firstStart
    }
}

/// ```weights フェンスの並び順・数値の尺度。AI が JSON の任意キー "measure" で指定する
/// (省略時・不正な値は time 扱い)。
public enum TopicMeasure: String, Equatable, Sendable {
    /// 合計時間の降順。
    case time
    /// 言及回数の降順(同数なら合計時間の降順)。
    case count
}

/// ```weights フェンスの中身(AI が話題と言及区間の壁時計だけを出したもの)をパースし、
/// 回数・合計時間を測った結果。
public struct TopicWeights: Equatable, Sendable {
    /// 見出し(AI が付けた場合のみ)。
    public let title: String?
    /// 並び順・表示の尺度。View 側はこれを初期値にしつつ、ユーザーがその場で time/count を
    /// 切り替えられる(TopicWeightsView 参照。切り替え後の並び替えは View 側の責務)。
    public let measure: TopicMeasure
    /// measure に従って並べた最大 8 件(time なら合計時間の降順、count なら言及回数の降順・
    /// 同数なら合計時間の降順)。
    public let topics: [TopicWeight]

    public init(title: String?, measure: TopicMeasure, topics: [TopicWeight]) {
        self.title = title
        self.measure = measure
        self.topics = topics
    }

    private struct JSON: Decodable {
        let title: String?
        let measure: String?
        let topics: [Topic]
        struct Topic: Decodable {
            let label: String
            let ranges: [[String]]
        }
    }

    /// フェンスの中身が JSON として最低限の形になっているかだけを見る、時刻変換より前の
    /// 軽い判定。呼び出し側(CodeImpactOverlay.swift の segments(from:))が、セッション開始
    /// 時刻が引けず parse(_:offset:) を呼べない(= 時刻変換の成否を判定できない)場合に、
    /// 「JSON 自体は壊れていないので何も描画しない」と「JSON 自体が壊れているので .code へ
    /// 落とす」を区別するために使う。時刻文字列(ranges の中身)が実際に妥当かどうかまでは
    /// 見ない(offset が無ければ判定できないため)。
    public static func isWellFormed(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(JSON.self, from: data)
        else { return false }
        return decoded.topics.contains { topic in
            !topic.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && topic.ranges.contains { $0.count == 2 }
        }
    }

    /// フェンスの中身(1 行 JSON)をパースする。JSON として壊れている・話題が 1 件も
    /// 有効でない場合は nil を返し、呼び出し側は通常のコード表示にフォールバックする
    /// (```choices の parseChoicePrompt と同じ方針)。
    ///
    /// offset は "HH:MM:SS" 形式の壁時計をセッション開始からの経過秒へ変換する関数
    /// (呼び出し側が TranscriptParser.offsetSeconds を渡す想定)。変換できない・
    /// 終わりが始まりより前の区間は、その区間だけ捨てる(話題自体は他に有効な区間が
    /// 残っていれば生かす)。有効な区間が1つも残らない話題、ラベルが空の話題は捨てる。
    ///
    /// フェンスの言語名(weights)と JSON のキー(title / topics / label / ranges)は
    /// AgentCodeImpactAnalyzer.questionPrompt の出力契約と手打ちで揃えているので、
    /// 変える場合は両方直すこと。
    public static func parse(_ json: String, offset: (String) -> TimeInterval?) -> TopicWeights? {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(JSON.self, from: data)
        else { return nil }

        struct ValidRange {
            let start: TimeInterval
            let end: TimeInterval
            let rawStart: String
        }

        let topics: [TopicWeight] = decoded.topics.compactMap { topic in
            let label = topic.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }

            let validRanges: [ValidRange] = topic.ranges.compactMap { range in
                guard range.count == 2,
                    let start = offset(range[0]),
                    let end = offset(range[1]),
                    end >= start
                else { return nil }
                return ValidRange(start: start, end: end, rawStart: range[0])
            }
            guard !validRanges.isEmpty else { return nil }

            let seconds = validRanges.reduce(0) { $0 + ($1.end - $1.start) }
            let earliest = validRanges.min { $0.start < $1.start }!
            return TopicWeight(
                label: label, mentions: validRanges.count, seconds: seconds,
                firstStart: earliest.rawStart)
        }
        guard !topics.isEmpty else { return nil }

        // 省略時・"time"/"count" 以外の不正な値は time 扱い。
        let measure = decoded.measure.flatMap(TopicMeasure.init(rawValue:)) ?? .time
        let sorted: [TopicWeight]
        switch measure {
        case .time:
            sorted = topics.sorted { $0.seconds > $1.seconds }
        case .count:
            sorted = topics.sorted { lhs, rhs in
                if lhs.mentions != rhs.mentions { return lhs.mentions > rhs.mentions }
                return lhs.seconds > rhs.seconds
            }
        }
        let title = decoded.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TopicWeights(
            title: (title?.isEmpty == false) ? title : nil,
            measure: measure,
            topics: Array(sorted.prefix(8)))
    }
}
