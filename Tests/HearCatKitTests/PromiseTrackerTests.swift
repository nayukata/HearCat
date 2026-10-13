import Foundation
import Testing

@testable import HearCatKit

struct PromiseTrackerTests {
    private func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        return Calendar.current.startOfDay(for: formatter.date(from: string)!)
    }

    /// M1=9/1, M2=9/8, M3=9/8(同じ日の別会議), M4=9/15。
    private var meetings: [String: PromiseMeeting] {
        [
            "M1": PromiseMeeting(sessionID: "s1", start: day("2026-09-01").addingTimeInterval(10 * 3600)),
            "M2": PromiseMeeting(sessionID: "s2", start: day("2026-09-08").addingTimeInterval(10 * 3600)),
            "M3": PromiseMeeting(sessionID: "s3", start: day("2026-09-08").addingTimeInterval(15 * 3600)),
            "M4": PromiseMeeting(sessionID: "s4", start: day("2026-09-15").addingTimeInterval(10 * 3600)),
        ]
    }

    private func parse(_ json: String) -> PromiseTracker? {
        let table = meetings
        return PromiseTracker.parse(json, meeting: { table[$0] })
    }

    // MARK: - parse

    @Test func 正常な項目は会議の日付へ解決される() {
        let json = #"""
            {"title": "宿題", "items": [
                {"label": "見積もり", "who": "me", "made": "M1", "madeAt": "14:03:12", "done": "M4", "doneAt": "10:21:40"},
                {"label": "契約書", "who": "you", "made": "M2"}
            ]}
            """#
        let result = parse(json)
        #expect(result?.title == "宿題")
        #expect(result?.items.count == 2)
        let first = result?.items[0]
        #expect(first?.owner == .me)
        #expect(first?.made.meeting.sessionID == "s1")
        #expect(first?.made.time == "14:03:12")
        #expect(first?.done?.meeting.sessionID == "s4")
        let second = result?.items[1]
        #expect(second?.owner == .you)
        #expect(second?.done == nil)
    }

    @Test func 識別子の表記ゆれを吸収する() {
        let json = #"{"items": [{"label": "A", "made": "[m1]", "done": " m4 "}]}"#
        #expect(parse(json)?.items.count == 1)
    }

    @Test func 壊れたJSONはnil() {
        #expect(parse("not json") == nil)
    }

    @Test func itemsが空ならnil() {
        #expect(parse(#"{"items": []}"#) == nil)
    }

    @Test func itemsキーが無ければnil() {
        #expect(parse("{}") == nil)
    }

    @Test func 未知の約束会議の項目は捨てられ他は残る() {
        let json = #"""
            {"items": [
                {"label": "A", "made": "M9"},
                {"label": "B", "made": "M1"},
                {"label": "C"}
            ]}
            """#
        let result = parse(json)
        #expect(result?.items.map(\.label) == ["B"])
    }

    @Test func 未知の完了会議の項目は未完了にせず捨てる() {
        let json = #"""
            {"items": [
                {"label": "A", "made": "M1", "done": "M9"},
                {"label": "B", "made": "M1"}
            ]}
            """#
        #expect(parse(json)?.items.map(\.label) == ["B"])
    }

    @Test func 完了が約束より前の項目は捨てられる() {
        let json = #"{"items": [{"label": "A", "made": "M4", "done": "M1"}]}"#
        #expect(parse(json) == nil)
    }

    @Test func 同じ会議で約束と完了の項目は捨てられる() {
        let json = #"{"items": [{"label": "A", "made": "M2", "done": "M2"}]}"#
        #expect(parse(json) == nil)
    }

    @Test func 同じ日でも後の会議で済んだ項目は残る() {
        let json = #"{"items": [{"label": "A", "made": "M2", "done": "M3"}]}"#
        #expect(parse(json)?.items.count == 1)
    }

    @Test func 全項目が不正ならnil() {
        let json = #"{"items": [{"label": "", "made": "M1"}, {"label": "A", "made": "M9"}]}"#
        #expect(parse(json) == nil)
    }

    @Test func 長すぎるラベルは切らずに捨てる() {
        let long = String(repeating: "あ", count: PromiseTracker.maximumLabelLength + 1)
        let ok = String(repeating: "あ", count: PromiseTracker.maximumLabelLength)
        let json = #"{"items": [{"label": "\#(long)", "made": "M1"}, {"label": "\#(ok)", "made": "M1"}]}"#
        let result = parse(json)
        #expect(result?.items.count == 1)
        #expect(result?.items.first?.label == ok)
    }

    @Test func 件数超過は先頭の8件に切る() {
        let items = (0..<12).map { #"{"label": "約束\#($0)", "made": "M1"}"# }.joined(separator: ",")
        let result = parse(#"{"items": [\#(items)]}"#)
        #expect(result?.items.count == PromiseTracker.maximumItems)
        #expect(result?.items.first?.label == "約束0")
    }

    @Test func 溢れたときは未完了を優先して残し日付順に並べる() {
        // 済み6件(M1 と M2 で約束)が先に並び、未完了4件(M3 と M4 で約束)が後に並ぶ。
        let done = (0..<6).map { #"{"label": "済\#($0)", "made": "\#($0 < 3 ? "M1" : "M2")", "done": "M4"}"# }
        let pending = (0..<4).map { #"{"label": "未\#($0)", "made": "\#($0 < 2 ? "M3" : "M4")"}"# }
        let json = #"{"items": [\#((done + pending).joined(separator: ","))]}"#
        let items = parse(json)?.items ?? []
        #expect(items.count == PromiseTracker.maximumItems)
        // 未完了は全部残り、済みは AI の出した順で4件(済0〜済3)だけ残る。
        #expect(items.filter { $0.done == nil }.count == 4)
        #expect(items.filter { $0.done != nil }.map(\.label) == ["済0", "済1", "済2", "済3"])
        // 約束した会議の日付順(M1 → M2 → M3 → M4)に並ぶ。
        #expect(items.map(\.label) == ["済0", "済1", "済2", "済3", "未0", "未1", "未2", "未3"])
        #expect(items.map(\.made.meeting.sessionID) == ["s1", "s1", "s1", "s2", "s3", "s3", "s4", "s4"])
    }

    @Test func titleとwhoの型違いは無視され項目は残る() {
        let json = #"{"title": 5, "items": [{"label": "A", "who": 1, "made": "M1", "madeAt": 3}]}"#
        let result = parse(json)
        #expect(result?.items.count == 1)
        #expect(result?.title == nil)
        #expect(result?.items.first?.owner == nil)
        #expect(result?.items.first?.made.time == nil)
    }

    @Test func labelが読めない項目だけ捨てられる() {
        let json = #"{"items": [{"made": "M1"}, {"label": 3, "made": "M1"}, "x", {"label": "B", "made": "M1"}]}"#
        #expect(parse(json)?.items.map(\.label) == ["B"])
    }

    @Test func madeが無いか文字列でない項目は捨てられる() {
        let json = #"{"items": [{"label": "A"}, {"label": "B", "made": 1}, {"label": "C", "made": "M1"}]}"#
        #expect(parse(json)?.items.map(\.label) == ["C"])
    }

    @Test func doneが文字列でない項目は未完了にせず捨てられる() {
        let json = #"{"items": [{"label": "A", "made": "M1", "done": 4}, {"label": "B", "made": "M1", "done": null}]}"#
        let items = parse(json)?.items ?? []
        #expect(items.map(\.label) == ["B"])
        #expect(items.first?.done == nil)
    }

    @Test func 会議にはグループと開始日時が残り引き直しに使える() {
        let meeting = PromiseMeeting(sessionID: "s1", folder: "定例", start: day("2026-09-01"))
        let result = PromiseTracker.parse(
            #"{"items": [{"label": "A", "made": "M1"}]}"#, meeting: { _ in meeting })
        #expect(result?.items.first?.made.meeting.folder == "定例")
        #expect(result?.items.first?.made.meeting.start == day("2026-09-01"))
    }

    @Test func 時刻が不正でも項目は残り時刻だけnilになる() {
        let json = #"{"items": [{"label": "A", "made": "M1", "madeAt": "25:00:00", "done": "M4", "doneAt": "9:1:1"}]}"#
        let item = parse(json)?.items.first
        #expect(item != nil)
        #expect(item?.made.time == nil)
        #expect(item?.done?.time == nil)
    }

    @Test func 約束した会議の古い順に並び同じ会議では元の順を保つ() {
        let json = #"""
            {"items": [
                {"label": "後", "made": "M4"},
                {"label": "先1", "made": "M1"},
                {"label": "先2", "made": "M1"}
            ]}
            """#
        #expect(parse(json)?.items.map(\.label) == ["先1", "先2", "後"])
    }

    @Test func 見出しが空白だけならnil扱い() {
        let json = #"{"title": "  ", "items": [{"label": "A", "made": "M1"}]}"#
        #expect(parse(json)?.title == nil)
    }

    // MARK: - isWellFormed

    @Test func isWellFormedは形だけを見る() {
        #expect(PromiseTracker.isWellFormed(#"{"items": [{"label": "A", "made": "M9"}]}"#))
        #expect(!PromiseTracker.isWellFormed("not json"))
        #expect(!PromiseTracker.isWellFormed(#"{"items": [{"label": " "}]}"#))
    }

    // MARK: - 識別子の振り方

    @Test func 識別子は開始の古い順に振られる() {
        let ids = PromiseMeetingID.assign([
            ("b", day("2026-09-08")), ("a", day("2026-09-01")), ("c", day("2026-09-15")),
        ])
        #expect(ids == ["a": "M1", "b": "M2", "c": "M3"])
    }

    @Test func 開始が同時刻ならセッションID順で決まる() {
        let same = day("2026-09-01")
        let ids = PromiseMeetingID.assign([("z", same), ("a", same)])
        #expect(ids == ["a": "M1", "z": "M2"])
    }

    // MARK: - 軸

    private func item(made: String, done: String?) -> PromiseItem {
        let table = meetings
        return PromiseItem(
            label: "x", owner: nil,
            made: PromiseMoment(meeting: table[made]!, time: nil),
            done: done.map { PromiseMoment(meeting: table[$0]!, time: nil) })
    }

    @Test func 軸は約束の最初の日から完了と今日の遅い方まで() {
        let axis = PromiseAxis(
            items: [item(made: "M1", done: "M4"), item(made: "M2", done: nil)], today: day("2026-09-20"))
        #expect(axis.start == day("2026-09-01"))
        #expect(axis.end == day("2026-09-20"))
        #expect(axis.today == day("2026-09-20"))
    }

    @Test func 未完了が無ければ今日は軸に含めない() {
        let axis = PromiseAxis(items: [item(made: "M1", done: "M4")], today: day("2026-12-01"))
        #expect(axis.end == day("2026-09-15"))
        #expect(axis.today == nil)
    }

    @Test func 全部が同じ日でも幅がゼロにならず0除算しない() {
        let axis = PromiseAxis(items: [item(made: "M2", done: nil)], today: day("2026-09-08"))
        #expect(axis.end > axis.start)
        let fraction = axis.fraction(of: day("2026-09-08"))
        #expect(fraction.isFinite)
        #expect(fraction == 0)
        #expect(axis.fraction(of: day("2030-01-01")) == 1)
    }

    @Test func 軸は範囲外の日付を0から1に収める() {
        let axis = PromiseAxis(items: [item(made: "M1", done: "M4")], today: day("2026-09-10"))
        #expect(axis.fraction(of: day("2026-08-01")) == 0)
        #expect(axis.fraction(of: day("2026-09-15")) == 1)
        #expect(axis.fraction(of: day("2026-09-08")) > 0)
    }
}

struct PromiseQuestionTests {
    @Test(arguments: [
        "宿題はどうなった？", "前回言ってたあれは済んだ?", "約束したことを教えて", "やると言っていたことは",
        "ToDo は終わった?", "ＴＯＤＯの状況", "積み残しは?", "持ち帰りの件", "タスクの進捗は?",
        "アクションアイテムを教えて", "ネクストアクションは?", "頼まれたことは?",
        "前回の件、完了してる?", "言ったことの進み具合は",
    ])
    func 約束や宿題の質問は発動する(_ question: String) {
        #expect(PromiseQuestion.asksAboutPromises(question))
    }

    @Test(arguments: [
        "相手は何を言ってた?", "前回との違いは?", "この会議の要点は", "価格について何が出た?", "",
        "価格はどうなった?", "会議が終わったら何する?", "進捗は?", "あの件、完了してる?",
    ])
    func 無関係な質問は発動しない(_ question: String) {
        #expect(!PromiseQuestion.asksAboutPromises(question))
    }

    @Test func nilは発動しない() {
        #expect(!PromiseQuestion.asksAboutPromises(nil))
    }
}
