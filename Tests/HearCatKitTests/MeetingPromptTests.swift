import Foundation
import Testing

@testable import HearCatKit

struct MeetingPromptTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func slot(_ id: String, startsIn: TimeInterval, lasts: TimeInterval = 1800) -> MeetingSlot {
        let start = now.addingTimeInterval(startsIn)
        return MeetingSlot(id: id, start: start, end: start.addingTimeInterval(lasts))
    }

    private func decide(
        _ candidates: [MeetingSlot], handled: Set<String> = [], shown: MeetingSlot? = nil
    ) -> MeetingPrompt.Decision {
        MeetingPrompt.decide(
            candidates: candidates, handled: handled, shown: shown, now: now, grace: 60)
    }

    @Test func 未確認の会議には確認を出して処理済みにする() {
        let a = slot("a", startsIn: 20)
        let d = decide([a])
        #expect(d.show == a)
        #expect(d.handle == ["a"])
    }

    @Test func 確認済みの会議にはもう出さない() {
        #expect(decide([slot("a", startsIn: 20)], handled: ["a"]).show == nil)
    }

    @Test func 終わった会議には出さない() {
        #expect(decide([slot("a", startsIn: -600, lasts: 300)]).show == nil)
    }

    @Test func 始まって猶予を超えた会議には割り込まない() {
        #expect(decide([slot("a", startsIn: -120)]).show == nil)
        #expect(decide([slot("a", startsIn: -30)]).show?.id == "a")
    }

    @Test func 出している間に遅く始まる会議が来たら置き換える() {
        let a = slot("a", startsIn: -10)
        let b = slot("b", startsIn: 25)
        let d = decide([a, b], handled: ["a"], shown: a)
        #expect(d.show == b)
        #expect(d.handle == ["b"])
    }

    @Test func 開始時刻が同じ会議は置き換えず黙って処理済みにする() {
        let a = slot("a", startsIn: 20)
        let b = slot("b", startsIn: 20)
        let first = decide([a, b])
        #expect(first.show?.id == "a")
        #expect(Set(first.handle) == ["a", "b"])
        let again = decide([a, b], handled: ["a"], shown: a)
        #expect(again.show == nil)
        #expect(again.handle == ["b"])
    }

    @Test func 出している会議より早く始まる未確認は出さずに処理済みにする() {
        let shown = slot("late", startsIn: 25)
        let early = slot("early", startsIn: 5)
        let d = decide([early, shown], handled: ["late"], shown: shown)
        #expect(d.show == nil)
        #expect(d.handle == ["early"])
    }

    @Test func 出している確認は窓に残っているうちは有効() {
        let a = slot("a", startsIn: -10)
        #expect(MeetingPrompt.isStillValid(shown: a, candidates: [a], now: now))
    }

    @Test func 予定が消えたら確認は無効() {
        let a = slot("a", startsIn: 20)
        #expect(!MeetingPrompt.isStillValid(shown: a, candidates: [], now: now))
    }

    @Test func 時刻が変わるとIDが変わるので確認は無効() {
        let old = slot("a@1", startsIn: 20)
        let moved = slot("a@2", startsIn: 3600)
        #expect(!MeetingPrompt.isStillValid(shown: old, candidates: [moved], now: now))
    }

    @Test func スリープ復帰で終了時刻を過ぎていたら確認は無効() {
        let a = slot("a", startsIn: -1900, lasts: 1800)
        #expect(!MeetingPrompt.isStillValid(shown: a, candidates: [a], now: now))
    }
}

extension MeetingPromptTests {
    @Test func 猶予ちょうど60秒前に始まった会議には出し_それを超えたら出さない() {
        #expect(decide([slot("a", startsIn: -60)]).show?.id == "a")
        #expect(decide([slot("a", startsIn: -60.5)]).show == nil)
    }

    @Test func 開始時刻の差が1秒でも遅い方なら置き換える() {
        let a = slot("a", startsIn: 20)
        let b = slot("b", startsIn: 21)
        let d = decide([a, b], handled: ["a"], shown: a)
        #expect(d.show == b)
    }

    @Test func 開始時刻の差が小さくても早い方では置き換えない() {
        let a = slot("a", startsIn: 21)
        let b = slot("b", startsIn: 20)
        let d = decide([a, b], handled: ["a"], shown: a)
        #expect(d.show == nil)
        #expect(d.handle == ["b"])
    }
}
