import Foundation
import Testing

@testable import HearCatKit

struct LiveTimelineTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func 暫定の更新は同じ席で文面だけ変わる() {
        var timeline = LiveTimeline()
        timeline.setVolatile(speaker: "自分", text: "こん", startedAt: base)
        timeline.setVolatile(speaker: "自分", text: "こんにちは", startedAt: base)

        #expect(timeline.rows.count == 1)
        #expect(timeline.rows[0].text == "こんにちは")
        #expect(timeline.rows[0].volatile)
    }

    @Test func 確定は同じ話者の暫定の席に流し込まれる() {
        var timeline = LiveTimeline()
        timeline.setVolatile(speaker: "自分", text: "こんにち", startedAt: base)
        timeline.setVolatile(speaker: "相手", text: "どう", startedAt: base.addingTimeInterval(1))
        timeline.finalize(TranscriptSegment(speaker: "自分", text: "こんにちは。", timestamp: base))

        #expect(timeline.rows.count == 2)
        #expect(timeline.rows[0].text == "こんにちは。")
        #expect(!timeline.rows[0].volatile)
        #expect(timeline.rows[1].text == "どう")
    }

    @Test func 遅れて届いた確定でも行の並びは動かない() {
        // 自分の確定は相手より遅い(実測で中央値+6秒)。相手の確定が先に届いても、
        // 先に話し始めた自分の行はもとの席に残り、割り込み挿入が起きないこと。
        var timeline = LiveTimeline()
        timeline.setVolatile(speaker: "自分", text: "先に話し始めた", startedAt: base)
        timeline.setVolatile(speaker: "相手", text: "後から話し始めた", startedAt: base.addingTimeInterval(2))
        timeline.finalize(
            TranscriptSegment(speaker: "相手", text: "後から話し始めた。", timestamp: base.addingTimeInterval(2)))
        timeline.finalize(TranscriptSegment(speaker: "自分", text: "先に話し始めた。", timestamp: base))

        #expect(timeline.rows.map(\.text) == ["先に話し始めた。", "後から話し始めた。"])
    }

    @Test func 暫定のない確定は末尾に足される() {
        var timeline = LiveTimeline()
        timeline.setVolatile(speaker: "相手", text: "話し中", startedAt: base.addingTimeInterval(1))
        timeline.finalize(TranscriptSegment(speaker: "自分", text: "暫定が届かなかった発話。", timestamp: base))

        #expect(timeline.rows.map(\.text) == ["話し中", "暫定が届かなかった発話。"])
    }

    @Test func 空文字の暫定で行が消える() {
        // 確定がエコーとして破棄された時、エンジンは空文字の暫定で行の消去を伝える。
        var timeline = LiveTimeline()
        timeline.setVolatile(speaker: "自分", text: "エコーになる発話", startedAt: base)
        timeline.setVolatile(speaker: "自分", text: "", startedAt: base)

        #expect(timeline.rows.isEmpty)
    }

    @Test func 確定後の続きの暫定は新しい席で末尾に出る() {
        var timeline = LiveTimeline()
        timeline.setVolatile(speaker: "自分", text: "長い発話の前半", startedAt: base)
        timeline.finalize(TranscriptSegment(speaker: "自分", text: "長い発話の前半。", timestamp: base))
        timeline.setVolatile(speaker: "自分", text: "後半の続き", startedAt: base.addingTimeInterval(5))

        #expect(timeline.rows.map(\.text) == ["長い発話の前半。", "後半の続き"])
        #expect(timeline.rows[1].volatile)
    }

    @Test func 確定行のIDは行ごとに一意で暫定は話者で固定() {
        var timeline = LiveTimeline()
        timeline.setVolatile(speaker: "自分", text: "一言目", startedAt: base)
        let volatileID = timeline.rows[0].id
        timeline.finalize(TranscriptSegment(speaker: "自分", text: "一言目。", timestamp: base))
        timeline.setVolatile(speaker: "自分", text: "二言目", startedAt: base.addingTimeInterval(3))
        timeline.finalize(TranscriptSegment(speaker: "自分", text: "二言目。", timestamp: base.addingTimeInterval(3)))

        #expect(timeline.rows[0].id != timeline.rows[1].id)
        // 同じ話者の暫定行は常に同じ ID(認識中→確定の入れ替わりでビューの状態が迷子にならないように)。
        timeline.setVolatile(speaker: "自分", text: "三言目", startedAt: base.addingTimeInterval(6))
        #expect(timeline.rows[2].id == volatileID)
    }

    @Test func clearVolatilesは確定行だけ残す() {
        var timeline = LiveTimeline()
        timeline.finalize(TranscriptSegment(speaker: "自分", text: "確定済み。", timestamp: base))
        timeline.setVolatile(speaker: "相手", text: "話し中", startedAt: base.addingTimeInterval(1))
        timeline.clearVolatiles()

        #expect(timeline.rows.map(\.text) == ["確定済み。"])
    }
}
