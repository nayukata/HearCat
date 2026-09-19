import Foundation
import Testing

@testable import HearCatKit

struct CurrentEventRuleTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)  // 適当な基準日時 0:00 扱い
    private static let fiveMinutes: TimeInterval = 5 * 60

    private static func at(_ hour: Double, _ minute: Double = 0) -> Date {
        base.addingTimeInterval(hour * 3600 + minute * 60)
    }

    /// 「有休(全日)」のような 5:00〜22:00 の長い予定に、20:00 開始の個別会議が
    /// 埋もれて捨てられていた不具合の再現。19:59 の時点では長い予定だけが
    /// 進行中に見えるが、入れ子の短い予定を優先する。
    @Test func 長い予定に入れ子の個別会議があれば個別会議を選ぶ() {
        let long = CurrentEventRule.Candidate(title: "有休", start: Self.at(5), end: Self.at(22))
        let short = CurrentEventRule.Candidate(title: "個別MTG", start: Self.at(20), end: Self.at(21))
        let picked = CurrentEventRule.pick(
            [long, short], now: Self.at(19, 59), lookahead: Self.fiveMinutes)
        #expect(picked == short)
    }

    @Test func 進行中どうしでも入れ子は短い方を選ぶ() {
        let long = CurrentEventRule.Candidate(title: "有休", start: Self.at(5), end: Self.at(22))
        let short = CurrentEventRule.Candidate(title: "定例", start: Self.at(14), end: Self.at(15))
        let picked = CurrentEventRule.pick(
            [long, short], now: Self.at(14.5), lookahead: Self.fiveMinutes)
        #expect(picked == short)
    }

    @Test func 長い予定しか無ければそれを選ぶ() {
        let long = CurrentEventRule.Candidate(title: "有休", start: Self.at(5), end: Self.at(22))
        let picked = CurrentEventRule.pick([long], now: Self.at(10), lookahead: Self.fiveMinutes)
        #expect(picked == long)
    }

    @Test func 進行中が複数で入れ子でなければ一番あとに始まったものを選ぶ() {
        let a = CurrentEventRule.Candidate(title: "A", start: Self.at(10), end: Self.at(11.5))
        let b = CurrentEventRule.Candidate(title: "B", start: Self.at(11), end: Self.at(12))
        let picked = CurrentEventRule.pick(
            [a, b], now: Self.at(11, 10), lookahead: Self.fiveMinutes)
        #expect(picked == b)
    }

    @Test func 進行中が無ければ一番早く始まるまもなく始まる予定を選ぶ() {
        let a = CurrentEventRule.Candidate(title: "A", start: Self.at(18, 30), end: Self.at(19))
        let b = CurrentEventRule.Candidate(title: "B", start: Self.at(18, 10), end: Self.at(18, 30))
        let picked = CurrentEventRule.pick([a, b], now: Self.at(18), lookahead: 40 * 60)
        #expect(picked == b)
    }

    /// 同一期間の予定どうしは互いに含む関係とみなさず、どちらも候補に残る。
    @Test func 同一期間の予定は互いに落とさない() {
        let a = CurrentEventRule.Candidate(title: "A", start: Self.at(10), end: Self.at(11))
        let b = CurrentEventRule.Candidate(title: "B", start: Self.at(10), end: Self.at(11))
        let picked = CurrentEventRule.pick(
            [a, b], now: Self.at(10.5), lookahead: Self.fiveMinutes)
        #expect(picked == a || picked == b)
    }

    @Test func 候補が空ならnil() {
        #expect(CurrentEventRule.pick([], now: Self.at(10), lookahead: Self.fiveMinutes) == nil)
    }

    /// 規則は呼び出し側の検索窓に依存せず、自分でも先読み窓を絞る。窓を絞らないと
    /// 「会議A 14:00〜16:00 の中に休憩 15:00〜15:10」を渡したとき、14:30 の時点でも
    /// 窓の外にある休憩まで含む判定に混ざり、会議Aが誤って外れてしまう。
    @Test func 先読み窓の外の候補は含む判定に混ぜない() {
        let meeting = CurrentEventRule.Candidate(title: "会議A", start: Self.at(14), end: Self.at(16))
        let rest = CurrentEventRule.Candidate(
            title: "休憩", start: Self.at(15), end: Self.at(15, 10))
        let beforeRest = CurrentEventRule.pick(
            [meeting, rest], now: Self.at(14, 30), lookahead: Self.fiveMinutes)
        #expect(beforeRest == meeting)

        // 14:56 になると休憩(15:00開始)も先読み窓(+5分=15:01まで)に入り、会議Aは
        // 休憩を含んでしまうため候補から外れる。休憩はまだ始まっていないので
        // upcoming としてではあるが、入れ子を優先する今回の方針どおり選ばれる。
        let afterWindowOpens = CurrentEventRule.pick(
            [meeting, rest], now: Self.at(14, 56), lookahead: Self.fiveMinutes)
        #expect(afterWindowOpens == rest)
    }

    @Test func 終了済みの予定は選ばれない() {
        let ended = CurrentEventRule.Candidate(title: "終わった会議", start: Self.at(10), end: Self.at(11))
        let picked = CurrentEventRule.pick([ended], now: Self.at(12), lookahead: Self.fiveMinutes)
        #expect(picked == nil)
    }

    /// 3段の入れ子でも、一番内側の予定まで正しく辿り着く。
    @Test func 三段の入れ子でも一番内側を選ぶ() {
        let a = CurrentEventRule.Candidate(title: "A", start: Self.at(10), end: Self.at(14))
        let b = CurrentEventRule.Candidate(title: "B", start: Self.at(11), end: Self.at(13))
        let c = CurrentEventRule.Candidate(title: "C", start: Self.at(11, 30), end: Self.at(12))
        let picked = CurrentEventRule.pick(
            [a, b, c], now: Self.at(11, 45), lookahead: Self.fiveMinutes)
        #expect(picked == c)
    }

    @Test func 開始が同じなら終了が早い短い方を選ぶ() {
        let long = CurrentEventRule.Candidate(title: "長い方", start: Self.at(10), end: Self.at(12))
        let short = CurrentEventRule.Candidate(title: "短い方", start: Self.at(10), end: Self.at(11))
        let picked = CurrentEventRule.pick(
            [long, short], now: Self.at(10.5), lookahead: Self.fiveMinutes)
        #expect(picked == short)
    }

    @Test func 終了が同じなら開始が遅い短い方を選ぶ() {
        let long = CurrentEventRule.Candidate(title: "長い方", start: Self.at(9), end: Self.at(12))
        let short = CurrentEventRule.Candidate(title: "短い方", start: Self.at(10), end: Self.at(12))
        let picked = CurrentEventRule.pick(
            [long, short], now: Self.at(10.5), lookahead: Self.fiveMinutes)
        #expect(picked == short)
    }

    /// 終了時刻が開始時刻より前の壊れた予定を渡すと、正常な予定が「壊れた方を
    /// 含む」と誤判定されて落ちていた。壊れた予定自体は候補から先に外す。
    @Test func 壊れた予定があっても正常な予定を選ぶ() {
        let broken = CurrentEventRule.Candidate(title: "壊れた予定", start: Self.at(14), end: Self.at(13))
        let normal = CurrentEventRule.Candidate(title: "正常な会議", start: Self.at(14), end: Self.at(15))
        let picked = CurrentEventRule.pick(
            [broken, normal], now: Self.at(14, 10), lookahead: Self.fiveMinutes)
        #expect(picked == normal)
    }
}
