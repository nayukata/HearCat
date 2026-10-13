import Foundation
import Testing

@testable import HearCatKit

struct MeetingBriefTests {
    @Test func 決まったことと未決を時刻つきで読む() {
        let raw = """
            ## 決まったこと
            - [14:32:05] リリース日を来週の金曜に変更
            - [14:33:20] 告知文を直す(自分)
            ## まだ決まっていないこと
            - [14:34:00] 告知文の期限
            """
        let brief = MeetingBriefParser.parse(raw)
        #expect(brief?.decided == [
            .init(text: "リリース日を来週の金曜に変更", time: "14:32:05"),
            .init(text: "告知文を直す(自分)", time: "14:33:20"),
        ])
        #expect(brief?.open == [.init(text: "告知文の期限", time: "14:34:00")])
    }

    @Test func 空の文字列は形式崩れとして扱う() {
        #expect(MeetingBriefParser.parse("") == nil)
        #expect(MeetingBriefParser.parse("  \n\n ") == nil)
    }

    @Test func 見出しが無い返答は形式崩れとして扱う() {
        #expect(MeetingBriefParser.parse("- [14:32:05] 見出しの無い箇条書き") == nil)
        #expect(MeetingBriefParser.parse("会議では特に何も決まりませんでした。") == nil)
    }

    @Test func 見出しだけで項目が0件なら空の結果になる() {
        let brief = MeetingBriefParser.parse("## 決まったこと\n## まだ決まっていないこと\n")
        #expect(brief == MeetingBrief())
        #expect(brief?.isEmpty == true)
    }

    @Test func 該当なしの印は項目にしない() {
        let raw = "## 決まったこと\n- なし\n- （なし）\n## まだ決まっていないこと\n- 特になし"
        #expect(MeetingBriefParser.parse(raw)?.isEmpty == true)
    }

    @Test func 時刻が無い項目は時刻nilで残す() {
        let raw = "## 決まったこと\n- 来週に延期\n- [] 括弧だけで時刻が空"
        #expect(MeetingBriefParser.parse(raw)?.decided == [
            .init(text: "来週に延期", time: nil),
            .init(text: "括弧だけで時刻が空", time: nil),
        ])
    }

    @Test func 範囲外や読めない時刻はnilにして括弧は本文に残さない() {
        let raw = "## 決まったこと\n- [25:99:00] 範囲外\n- [abc] 文字\n- [] 空"
        #expect(MeetingBriefParser.parse(raw)?.decided == [
            .init(text: "範囲外", time: nil),
            .init(text: "文字", time: nil),
            .init(text: "空", time: nil),
        ])
    }

    @Test func マーカーの直後に空白が無い行は箇条書きにしない() {
        let raw = "## 決まったこと\n-5度まで下げる\n- 拾う\n---\n***\n- 区切りの後も拾う"
        #expect(MeetingBriefParser.parse(raw)?.decided.map(\.text) == ["拾う", "区切りの後も拾う"])
    }

    @Test func 太字で始まる注記は項目にせず太字の見出しは節を切り替える() {
        let raw = "**決まったこと**:\n- 一つ目\n**注:** 補足です\n続きの文\n**まだ決まっていないこと:**\n- 二つ目"
        let brief = MeetingBriefParser.parse(raw)
        #expect(brief?.decided == [.init(text: "一つ目", time: nil)])
        #expect(brief?.open == [.init(text: "二つ目", time: nil)])
    }

    @Test func 単独の太字の知らない見出しは節を閉じる() {
        let raw = "## 決まったこと\n- 拾う\n**決定の背景**\n- 拾わない"
        #expect(MeetingBriefParser.parse(raw)?.decided.map(\.text) == ["拾う"])
    }

    @Test func 区切り線の後ろの行は直前の項目につながない() {
        let raw = "## 決まったこと\n- 一つ目\n---\n区切りの後の文\n- 二つ目"
        #expect(MeetingBriefParser.parse(raw)?.decided.map(\.text) == ["一つ目", "二つ目"])
    }

    @Test func 継続行は直前の項目の本文につなぐ() {
        let raw = "## 決まったこと\n- [10:00:00] リリースを\n  来週に延期する\n- 次の項目"
        #expect(MeetingBriefParser.parse(raw)?.decided == [
            .init(text: "リリースを来週に延期する", time: "10:00:00"),
            .init(text: "次の項目", time: nil),
        ])
    }

    @Test func インデントされた子の項目は親の本文に読点でつなぐ() {
        let raw = "## 決まったこと\n- 告知を直す\n  - 文面は木曜まで\n  - 担当は自分\n- 別の件"
        #expect(MeetingBriefParser.parse(raw)?.decided == [
            .init(text: "告知を直す、文面は木曜まで、担当は自分", time: nil),
            .init(text: "別の件", time: nil),
        ])
    }

    @Test func つないだあとの本文も上限で切り詰める() {
        let raw = "## 決まったこと\n- 親\n" + (0..<10).map { _ in "  - " + String(repeating: "い", count: 50) }.joined(separator: "\n")
        let text = MeetingBriefParser.parse(raw)?.decided.first?.text ?? ""
        #expect(text.count == MeetingBriefParser.maxTextLength + 1)
    }

    @Test func 見出しの言い換えを決まったことと未決に振り分ける() {
        let raw = "## 決定事項\n- a\n## 未決事項\n- b\n## 合意事項\n- c\n## 保留\n- d\n## 確定事項\n- e"
        let brief = MeetingBriefParser.parse(raw)
        #expect(brief?.decided.map(\.text) == ["a", "c", "e"])
        #expect(brief?.open.map(\.text) == ["b", "d"])
    }

    @Test func 決定の背景のような見出しでは節が始まらない() {
        #expect(MeetingBriefParser.parse("## 決定の背景\n- 拾わない") == nil)
        let raw = "## 決まったこと\n- 拾う\n## 決定の背景\n- 拾わない"
        #expect(MeetingBriefParser.parse(raw)?.decided.map(\.text) == ["拾う"])
    }

    @Test func 秒なしの時刻は秒を補い範囲表記は前半を使う() {
        let raw = "## 決まったこと\n- [9:05] 秒なし\n- [14:30:00〜14:31:10] 範囲"
        let brief = MeetingBriefParser.parse(raw)
        #expect(brief?.decided.map(\.time) == ["09:05:00", "14:30:00"])
    }

    @Test func 末尾の括弧の時刻も読む() {
        let raw = "## 決まったこと\n- 延期する (14:32:05)"
        #expect(MeetingBriefParser.parse(raw)?.decided == [.init(text: "延期する", time: "14:32:05")])
    }

    @Test func 長すぎる行は切り詰める() {
        let long = String(repeating: "あ", count: 1000)
        let brief = MeetingBriefParser.parse("## 決まったこと\n- [14:32:05] \(long)")
        let text = brief?.decided.first?.text ?? ""
        #expect(text.count == MeetingBriefParser.maxTextLength + 1)
        #expect(text.hasSuffix("…"))
    }

    @Test func 項目数は見出しごとに上限で止める() {
        let lines = (0..<100).map { "- 項目\($0)" }.joined(separator: "\n")
        let brief = MeetingBriefParser.parse("## 決まったこと\n\(lines)")
        #expect(brief?.decided.count == MeetingBriefParser.maxItemsPerSection)
    }

    @Test func コードフェンスや番号付きや太字の見出しでも読む() {
        let raw = "```markdown\n**決まったこと**\n1. [10:00:00] 一つ目\n2) 二つ目\n**まだ決まっていないこと**\n* 三つ目\n```"
        let brief = MeetingBriefParser.parse(raw)
        #expect(brief?.decided.map(\.text) == ["一つ目", "二つ目"])
        #expect(brief?.open.map(\.text) == ["三つ目"])
    }

    @Test func 知らない見出しの下の箇条書きは拾わない() {
        let raw = "## 決まったこと\n- 拾う\n## 補足\n- 拾わない"
        #expect(MeetingBriefParser.parse(raw)?.decided.map(\.text) == ["拾う"])
    }

    @Test func 長い文字起こしは新しい側の行を残して先頭を落とす() {
        let lines = (0..<10).map { "[00:00:0\($0)] 自分: 発言\($0)" }
        let trimmed = MeetingBriefPrompt.trimmedTranscript(lines.joined(separator: "\n"), maxCharacters: 60)
        #expect(trimmed.hasSuffix("発言9"))
        #expect(!trimmed.contains("発言0"))
        #expect(trimmed.count <= 60)
        #expect(trimmed.hasPrefix("["))
    }

    @Test func 切り詰めた範囲を行頭の時刻から分で数える() {
        let text = "[10:00:00] 自分: a\n[10:12:30] 相手: b\n[10:30:00] 自分: c"
        #expect(MeetingBriefPrompt.coveredMinutes(of: text) == 30)
    }

    @Test func 日をまたぐ範囲は24時間を足して数える() {
        let text = "[23:50:00] 自分: a\n[00:10:00] 相手: b"
        #expect(MeetingBriefPrompt.coveredMinutes(of: text) == 20)
    }

    @Test func 時刻つきの行が2つ未満なら分は出さない() {
        #expect(MeetingBriefPrompt.coveredMinutes(of: "") == nil)
        #expect(MeetingBriefPrompt.coveredMinutes(of: "[10:00:00] 自分: a") == nil)
    }

    @Test func 上限以内の文字起こしはそのまま返す() {
        #expect(MeetingBriefPrompt.trimmedTranscript("", maxCharacters: 10) == "")
        #expect(MeetingBriefPrompt.trimmedTranscript("abc", maxCharacters: 10) == "abc")
    }

    @Test func 一行だけで上限を超えるときは末尾側を残す() {
        let line = String(repeating: "a", count: 50) + "END"
        #expect(MeetingBriefPrompt.trimmedTranscript(line, maxCharacters: 10).hasSuffix("END"))
        #expect(MeetingBriefPrompt.trimmedTranscript(line, maxCharacters: 10).count == 10)
    }
}
