import Foundation
import Testing

@testable import HearCatKit

/// TranscriptWriter が書く形式(「[HH:mm:ss] 話者: 発言」)を TranscriptParser が
/// 正しく読み戻せることの検証。再生ジャンプのオフセット計算が主眼。
struct TranscriptParserTests {
    /// テスト用のセッション開始時刻を作る(現在のカレンダー/タイムゾーン基準)。
    private func date(hour: Int, minute: Int, second: Int) -> Date {
        Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 5, hour: hour, minute: minute, second: second))!
    }

    @Test func 発話行から経過秒を割り出す() {
        let text = """
            [10:00:05] 自分: おはようございます
            [10:01:30] 相手: こんにちは
            """
        let lines = TranscriptParser.lines(from: text, sessionStart: date(hour: 10, minute: 0, second: 0))

        #expect(lines.count == 2)
        // 発話行は開始からの経過秒になる。
        #expect(lines[0].stamp == "10:00:05")
        #expect(lines[0].body == "自分: おはようございます")
        #expect(lines[0].offset == 5)
        #expect(lines[1].offset == 90)
    }

    /// 旧バージョンが書いていたヘッダー行(廃止済み)が残るファイルを開いても、
    /// 表示・オフセット計算の対象は発話行だけになることを確認する。
    @Test func 旧ヘッダー行と直後の空行はスキップされる() {
        let text = """
            # 文字起こし 2026-07-05 10:00:00

            [10:00:05] 自分: おはようございます
            """
        let lines = TranscriptParser.lines(from: text, sessionStart: date(hour: 10, minute: 0, second: 0))

        #expect(lines.count == 1)
        #expect(lines[0].stamp == "10:00:05")
        #expect(lines[0].body == "自分: おはようございます")
    }

    @Test func 日をまたいだ行は翌日として扱う() {
        let lines = TranscriptParser.lines(
            from: "[00:00:10] 自分: 日付が変わった",
            sessionStart: date(hour: 23, minute: 59, second: 50))
        #expect(lines[0].offset == 20)
    }

    @Test func 時刻に見えない行は本文のまま返す() {
        for line in ["[ab:cd:ef] x", "[10:00] 短い", "ただの本文", "[10:00:05]"] {
            let parsed = TranscriptParser.lines(
                from: line, sessionStart: date(hour: 10, minute: 0, second: 0))
            #expect(parsed[0].stamp == nil, "\(line)")
            #expect(parsed[0].body == line, "\(line)")
        }
    }
}
