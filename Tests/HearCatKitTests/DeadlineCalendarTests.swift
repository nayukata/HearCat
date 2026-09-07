import Foundation
import Testing

@testable import HearCatKit

struct DeadlineCalendarTests {
    /// "HH:MM:SS" を単純に秒数へ変換するだけのテスト用 offset(TopicWeightsTests と同じ方針)。
    private func offset(_ stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    private func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        return Calendar.current.startOfDay(for: formatter.date(from: string)!)
    }

    // MARK: - parse

    @Test func 壊れたJSONはnil() {
        #expect(DeadlineCalendar.parse("not json", offset: offset) == nil)
    }

    @Test func itemsキーが無いJSONはnil() {
        #expect(DeadlineCalendar.parse("{}", offset: offset) == nil)
    }

    @Test func itemsが0件ならnil() {
        let json = #"{"items": []}"#
        #expect(DeadlineCalendar.parse(json, offset: offset) == nil)
    }

    @Test func dueが無い項目は捨てられ他の有効な項目は残る() {
        let json = #"""
            {"items": [
                {"label": "資料", "at": "13:00:00", "kind": "due"},
                {"label": "LP", "at": "14:00:00", "due": "2026-09-10"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.count == 1)
        #expect(result?.items.first?.label == "LP")
    }

    @Test func dueが壊れた日付表記の項目は捨てられる() {
        let json = #"""
            {"items": [
                {"label": "資料", "at": "13:00:00", "due": "2026/09/10"},
                {"label": "LP", "at": "14:00:00", "due": "2026-09-10"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.count == 1)
        #expect(result?.items.first?.label == "LP")
    }

    /// Calendar.date(from:) は月末を超えた日を黙って繰り上げる(2026-02-30 → 3/2)ため、
    /// parseDueDate が組み立てた Date から年月日を取り戻して照合していないと、
    /// 実在しない日付が別の実在する日付として通ってしまう。
    @Test func dueが実在しない日付なら捨てられる() {
        let json = #"""
            {"items": [
                {"label": "実在しない日", "at": "13:00:00", "due": "2026-02-30"},
                {"label": "LP", "at": "14:00:00", "due": "2026-09-10"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.count == 1)
        #expect(result?.items.first?.label == "LP")
    }

    @Test func dueがISO8601の時刻付き表記なら捨てられる() {
        let json = #"""
            {"items": [
                {"label": "時刻付き", "at": "13:00:00", "due": "2026-09-10T00:00:00Z"},
                {"label": "LP", "at": "14:00:00", "due": "2026-09-10"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.count == 1)
        #expect(result?.items.first?.label == "LP")
    }

    @Test func itemsがオブジェクトならnil() {
        #expect(DeadlineCalendar.parse(#"{"items": {}}"#, offset: offset) == nil)
    }

    @Test func itemsが文字列ならnil() {
        #expect(DeadlineCalendar.parse(#"{"items": "x"}"#, offset: offset) == nil)
    }

    @Test func atが変換できない項目は捨てられる() {
        let json = #"""
            {"items": [
                {"label": "資料", "at": "不正", "due": "2026-09-10"},
                {"label": "LP", "at": "14:00:00", "due": "2026-09-10"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.count == 1)
        #expect(result?.items.first?.label == "LP")
    }

    @Test func labelが空の項目は捨てられる() {
        let json = #"""
            {"items": [
                {"label": "  ", "at": "13:00:00", "due": "2026-09-10"},
                {"label": "LP", "at": "14:00:00", "due": "2026-09-10"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.count == 1)
        #expect(result?.items.first?.label == "LP")
    }

    @Test func kindが不正または省略ならdue扱い() {
        let json = #"""
            {"items": [
                {"label": "A", "at": "13:00:00", "due": "2026-09-10", "kind": "foo"},
                {"label": "B", "at": "13:00:00", "due": "2026-09-11"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.map(\.kind) == [.due, .due])
    }

    @Test func kindにeventを指定するとevent扱い() {
        let json = #"""
            {"items": [
                {"label": "次回定例", "at": "13:00:00", "due": "2026-09-16", "kind": "event"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.first?.kind == .event)
    }

    @Test func whoが不正または省略ならnil扱い() {
        let json = #"""
            {"items": [
                {"label": "A", "at": "13:00:00", "due": "2026-09-10", "who": "foo"},
                {"label": "B", "at": "13:00:00", "due": "2026-09-11"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.map(\.owner) == [nil, nil])
    }

    @Test func whoにmeやyouを指定するとそのまま保持される() {
        let json = #"""
            {"items": [
                {"label": "A", "at": "13:00:00", "due": "2026-09-10", "who": "me"},
                {"label": "B", "at": "13:00:00", "due": "2026-09-11", "who": "you"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.map(\.owner) == [.me, .you])
    }

    @Test func 上限を超える場合は上位6件に切り詰められる() {
        let items = (0..<8).map { index in
            #"{"label": "項目\#(index)", "at": "13:00:00", "due": "2026-09-\#(String(format: "%02d", index + 1))"}"#
        }.joined(separator: ",")
        let json = #"{"items": [\#(items)]}"#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.count == 6)
        // 期限の早い順に並ぶので、上位6件は index 0〜5(9/1〜9/6)のはず。
        #expect(result?.items.map(\.label) == (0..<6).map { "項目\($0)" })
    }

    @Test func 期限の早い順に並ぶ() {
        let json = #"""
            {"items": [
                {"label": "遅い", "at": "13:00:00", "due": "2026-09-20"},
                {"label": "早い", "at": "13:00:00", "due": "2026-09-05"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.map(\.label) == ["早い", "遅い"])
    }

    @Test func 同日はatの早い順に並ぶ() {
        let json = #"""
            {"items": [
                {"label": "後発言", "at": "15:00:00", "due": "2026-09-10"},
                {"label": "先発言", "at": "13:00:00", "due": "2026-09-10"}
            ]}
            """#
        let result = DeadlineCalendar.parse(json, offset: offset)
        #expect(result?.items.map(\.label) == ["先発言", "後発言"])
    }

    @Test func タイトルは省略可() {
        let json = #"{"items": [{"label": "A", "at": "13:00:00", "due": "2026-09-10"}]}"#
        #expect(DeadlineCalendar.parse(json, offset: offset)?.title == nil)
    }

    @Test func タイトルがあれば保持される() {
        let json = #"""
            {"title": "宿題", "items": [{"label": "A", "at": "13:00:00", "due": "2026-09-10"}]}
            """#
        #expect(DeadlineCalendar.parse(json, offset: offset)?.title == "宿題")
    }

    // MARK: - isWellFormed

    @Test func isWellFormedは壊れたJSONでfalse() {
        #expect(DeadlineCalendar.isWellFormed("not json") == false)
    }

    @Test func isWellFormedは有効なlabelがあればtrue() {
        let json = #"{"items": [{"label": "A", "at": "13:00:00", "due": "2026-09-10"}]}"#
        #expect(DeadlineCalendar.isWellFormed(json))
    }

    // MARK: - DeadlineAxis

    @Test func 会議日が今日なら終点は翌日() {
        let sessionDay = day("2026-09-06")
        let axis = DeadlineAxis(sessionDay: sessionDay, today: sessionDay, items: [])
        #expect(axis.start == sessionDay)
        #expect(axis.end == day("2026-09-07"))
    }

    @Test func 過去の会議で今日が期限より手前なら終点は今日の翌日() {
        let sessionDay = day("2026-08-01")
        let today = day("2026-09-06")
        let item = DeadlineItem(label: "A", owner: nil, kind: .due, at: 0, due: day("2026-08-20"))
        let axis = DeadlineAxis(sessionDay: sessionDay, today: today, items: [item])
        #expect(axis.start == sessionDay)
        #expect(axis.end == day("2026-09-07"))
    }

    @Test func 期限が今日より遅ければ終点は期限の翌日() {
        let sessionDay = day("2026-09-01")
        let today = day("2026-09-06")
        let item = DeadlineItem(label: "A", owner: nil, kind: .due, at: 0, due: day("2026-09-20"))
        let axis = DeadlineAxis(sessionDay: sessionDay, today: today, items: [item])
        #expect(axis.end == day("2026-09-21"))
    }

    @Test func 始点と終点が同日にならない() {
        let sessionDay = day("2026-09-06")
        let today = day("2026-09-06")
        let item = DeadlineItem(label: "A", owner: nil, kind: .due, at: 0, due: day("2026-09-06"))
        let axis = DeadlineAxis(sessionDay: sessionDay, today: today, items: [item])
        #expect(axis.start != axis.end)
        #expect(axis.end == day("2026-09-07"))
    }

    @Test func fractionは始点で0終点で1() {
        let axis = DeadlineAxis(sessionDay: day("2026-09-01"), today: day("2026-09-01"), items: [])
        #expect(axis.fraction(of: day("2026-09-01")) == 0)
        #expect(axis.fraction(of: day("2026-09-02")) == 1)
    }

    @Test func fractionは範囲外を0から1に丸める() {
        let axis = DeadlineAxis(sessionDay: day("2026-09-01"), today: day("2026-09-05"), items: [])
        #expect(axis.fraction(of: day("2026-08-01")) == 0)
        #expect(axis.fraction(of: day("2026-12-01")) == 1)
    }

    /// 会議がまだ先(today < sessionDay)の場合。始点はあくまで会議の日で、今日を
    /// 始点として使わない(今日は横軸の範囲外・fraction 0 に丸められる)。
    @Test func 会議が未来のとき始点は会議の日終点は最遅期限翌日で今日は範囲外() {
        let sessionDay = day("2026-09-20")
        let today = day("2026-09-06")
        let item = DeadlineItem(label: "A", owner: nil, kind: .due, at: 0, due: day("2026-09-25"))
        let axis = DeadlineAxis(sessionDay: sessionDay, today: today, items: [item])
        #expect(axis.start == sessionDay)
        #expect(axis.end == day("2026-09-26"))
        #expect(axis.fraction(of: today) == 0)
    }

    // MARK: - DeadlineCalendarLayout

    private func makeItem(due: String, at: TimeInterval = 0) -> DeadlineItem {
        DeadlineItem(label: "x", owner: nil, kind: .due, at: at, due: day(due))
    }

    @Test func 異なる日の項目は上下交互になり最初は上になる() {
        let items = [
            makeItem(due: "2026-09-10"),
            makeItem(due: "2026-09-11"),
            makeItem(due: "2026-09-12"),
        ]
        let placements = DeadlineCalendarLayout.placements(for: items)
        #expect(placements.map(\.side) == [.above, .below, .above])
    }

    @Test func 同じ日の項目は同じ側になり段数が積み上がる() {
        let items = [
            makeItem(due: "2026-09-10", at: 0),
            makeItem(due: "2026-09-10", at: 60),
            makeItem(due: "2026-09-11", at: 0),
        ]
        let placements = DeadlineCalendarLayout.placements(for: items)
        #expect(placements[0].side == placements[1].side)
        #expect(placements[0].side == .above)
        #expect(placements[0].stackIndex == 0)
        #expect(placements[1].stackIndex == 1)
        // 別の日は最初から数え直すので段数は0に戻る。
        #expect(placements[2].stackIndex == 0)
        #expect(placements[2].side == .below)
    }

    // MARK: - DeadlineCalendarLayout.labelAnchor

    /// パネル最小幅 460 のときの暦の実効幅(≈308)を想定した境界値。
    /// halfLabelWidth はラベル幅 180 の半分(90)。
    @Test func 実効幅308でラベル半幅90のとき左端に近い位置は左端揃え() {
        #expect(DeadlineCalendarLayout.labelAnchor(x: 77, width: 308, halfLabelWidth: 90) == .leading)
    }

    @Test func 実効幅308でラベル半幅90のとき中央付近は中央揃え() {
        #expect(DeadlineCalendarLayout.labelAnchor(x: 154, width: 308, halfLabelWidth: 90) == .center)
    }

    @Test func 実効幅308でラベル半幅90のとき右端に近い位置は右端揃え() {
        #expect(DeadlineCalendarLayout.labelAnchor(x: 240, width: 308, halfLabelWidth: 90) == .trailing)
    }

    @Test func xがちょうど半幅の位置は中央揃え側に含める() {
        // x - halfLabelWidth == 0(左辺がちょうど0)は「はみ出す」に含めない。
        #expect(DeadlineCalendarLayout.labelAnchor(x: 90, width: 308, halfLabelWidth: 90) == .center)
        // x + halfLabelWidth == width(右辺がちょうど右端)も同様。
        #expect(DeadlineCalendarLayout.labelAnchor(x: 218, width: 308, halfLabelWidth: 90) == .center)
    }
}
