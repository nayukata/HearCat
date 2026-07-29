import Foundation
import Testing

@testable import HearCatKit

struct MeetingRuleTests {
    @Test func 会議サービスのURLがあれば会議とみなす() {
        #expect(MeetingRule.mentionsMeetingHost(["https://meet.google.com/abc-defg", nil, nil]))
        #expect(MeetingRule.mentionsMeetingHost([nil, "https://zoom.us/j/123456", nil]))
        #expect(MeetingRule.mentionsMeetingHost([nil, nil, "参加: https://teams.microsoft.com/l/meetup"]))
    }

    @Test func サービス名を文字で書いただけでは会議とみなさない() {
        // 説明欄に「Discord で実施」とだけ書かれたもくもく会が、参加者の多さを
        // 根拠に会議と判定され、自動録音が始まってしまった。待ち合わせ URL が
        // 無い以上、文字列だけでは会議の根拠にしない。
        #expect(!MeetingRule.mentionsMeetingHost([nil, "Discord で実施", nil]))
        #expect(!MeetingRule.mentionsMeetingHost([nil, "オンライン", "Zoom でやります"]))
    }

    @Test func 会議と関係ないURLでは会議とみなさない() {
        // URL 欄をホスト名の確認なしに通していた頃は、これらも会議になっていた。
        #expect(!MeetingRule.mentionsMeetingHost(["https://github.com/example/pull/1", nil, nil]))
        #expect(!MeetingRule.mentionsMeetingHost([nil, nil, "資料: https://docs.example.com/spec"]))
    }

    @Test func 招待リンクのdiscordは対象にしない() {
        #expect(!MeetingRule.mentionsMeetingHost([nil, nil, "https://discord.gg/abcdefg"]))
    }

    @Test func 欄が空なら会議とみなさない() {
        #expect(!MeetingRule.mentionsMeetingHost([nil, nil, nil]))
        #expect(!MeetingRule.mentionsMeetingHost(["", "", ""]))
    }

    @Test func ホスト名の大文字小文字は区別しない() {
        #expect(MeetingRule.mentionsMeetingHost([nil, "HTTPS://ZOOM.US/J/123456", nil]))
    }
}
