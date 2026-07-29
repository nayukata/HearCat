import Foundation
import Testing

@testable import HearCatKit

struct UpdateCheckScheduleTests {
    /// 判定が実行環境のタイムゾーンに左右されないよう、暦を固定する。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func isDue(now: Date, lastCheckedAt: Date?) -> Bool {
        UpdateCheckSchedule.isDue(
            now: now, lastCheckedAt: lastCheckedAt, hour: 11, calendar: calendar)
    }

    @Test func 基準時刻より前は確認しない() {
        #expect(!isDue(now: date(7, 29, 10, 59), lastCheckedAt: nil))
    }

    @Test func 基準時刻を過ぎたら確認する() {
        #expect(isDue(now: date(7, 29, 11, 0), lastCheckedAt: nil))
    }

    @Test func 同じ日に二度は確認しない() {
        let checked = date(7, 29, 11, 0)
        #expect(!isDue(now: date(7, 29, 11, 1), lastCheckedAt: checked))
        #expect(!isDue(now: date(7, 29, 23, 59), lastCheckedAt: checked))
    }

    @Test func 翌日の基準時刻を過ぎたらまた確認する() {
        let checked = date(7, 29, 11, 0)
        #expect(!isDue(now: date(7, 30, 10, 59), lastCheckedAt: checked))
        #expect(isDue(now: date(7, 30, 11, 0), lastCheckedAt: checked))
    }

    /// Mac が寝ていて基準時刻をまたげなかった場合、起動した時点で追いつく。
    @Test func 基準時刻を過ぎてから起動しても追いつく() {
        #expect(isDue(now: date(7, 29, 20, 0), lastCheckedAt: date(7, 27, 11, 30)))
    }

    /// 追いついて確認した後は、その日はもう確認しない。
    @Test func 追いついた日はもう確認しない() {
        #expect(!isDue(now: date(7, 29, 21, 0), lastCheckedAt: date(7, 29, 20, 0)))
    }
}
