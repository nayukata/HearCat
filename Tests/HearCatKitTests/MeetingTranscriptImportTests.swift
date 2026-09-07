import Foundation
import Testing

@testable import HearCatKit

/// Google Meet と Zoom の文字起こしを読み、HearCat の文字起こし形式へ移せることの検証。
/// 実名を保ったまま「自分/相手」を割り当てられるか(取り込みの主目的)が主眼。
struct MeetingTranscriptImportTests {
    private func date(
        year: Int = 2026, month: Int = 9, day: Int = 3, hour: Int = 10, minute: Int = 0
    ) -> Date {
        Calendar.current.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Google Meet

    /// Google ドキュメントから貼り付けた実物と同じ形。日付・会議名・経過時間の見出し・
    /// 全角コロンの発言・末尾の断り書きが混ざる。
    private let meetSample = """
        9月 3, 2026
        マーケ定例 - 文字起こし
        00:00:44

        菅原啓史：おはようございます。
        渡辺健太：今日はなつめさんいないんだっけ?

        00:02:18

        菅原啓史：今考えているのは犬と散歩するアプリです。
        渡辺健太：それはバーチャル犬ってこと?

        00:32:54 より後に文字起こしが終了しました

        この編集可能な文字起こしはコンピュータが生成したものであり、誤りが含まれている可能性があります。
        """

    @Test func Meetの文字起こしから会議名と日付と発言を読む() throws {
        let parsed = try MeetingTranscriptImport.parse(meetSample)

        #expect(parsed.source == .meet)
        #expect(parsed.suggestedName == "マーケ定例")
        #expect(parsed.speakers == ["菅原啓史", "渡辺健太"])
        #expect(parsed.utterances.count == 4)
        #expect(parsed.utterances[0].speaker == "菅原啓史")
        #expect(parsed.utterances[0].text == "おはようございます。")

        let start = try #require(parsed.suggestedStart)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: start)
        #expect(comps.year == 2026 && comps.month == 9 && comps.day == 3)
    }

    /// 発言ごとの時刻は元の文字起こしに無いため、直前の見出しの経過時間をそのまま使う。
    @Test func 見出しの経過時間がその区間の全発言に付く() throws {
        let parsed = try MeetingTranscriptImport.parse(meetSample)

        #expect(parsed.utterances[0].offset == 44)
        #expect(parsed.utterances[1].offset == 44)
        #expect(parsed.utterances[2].offset == 138)
        #expect(parsed.utterances[3].offset == 138)
    }

    /// 末尾の断り書きは発言ではない。発言として拾うと、要約や検索に会議の中身でない
    /// 文が混ざる。
    @Test func 末尾の断り書きは発言として拾わない() throws {
        let parsed = try MeetingTranscriptImport.parse(meetSample)
        #expect(!parsed.utterances.contains { $0.text.contains("コンピュータが生成") })
        #expect(!parsed.utterances.contains { $0.text.contains("文字起こしが終了") })
    }

    /// 発言のすぐ下に続く行は、折り返された同じ発言として足す(捨てると発言が欠ける)。
    /// 空行を挟んだ後の行は断り書きなので、これまで通り捨てる。
    @Test func 折り返された発言は続きとして足す() throws {
        let text = """
            00:00:10

            菅原啓史：ここで話が
            折り返されています
            渡辺健太：はい。

            これは断り書きです。
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.utterances.count == 2)
        #expect(parsed.utterances[0].text == "ここで話が折り返されています")
        #expect(!parsed.utterances.contains { $0.text.contains("断り書き") })
    }

    // MARK: - 字幕ファイル (Zoom)

    private let vttSample = """
        WEBVTT

        1
        00:00:03.780 --> 00:00:06.290
        Yamada Taro: おはようございます。

        2
        00:01:12.000 --> 00:01:15.500
        Suzuki Hanako: 資料を共有します。
        """

    @Test func Zoomの字幕から話者と経過秒を読む() throws {
        let parsed = try MeetingTranscriptImport.parse(vttSample)

        #expect(parsed.source == .caption)
        #expect(parsed.speakers == ["Yamada Taro", "Suzuki Hanako"])
        #expect(parsed.utterances.count == 2)
        #expect(parsed.utterances[0].offset == 3.78)
        #expect(parsed.utterances[0].text == "おはようございます。")
        #expect(parsed.utterances[1].offset == 72.0)
    }

    /// WebVTT の話者タグ形式(Teams など)も同じ経路で読む。
    @Test func 話者タグつきの字幕も読む() throws {
        let text = """
            WEBVTT

            00:00:01.000 --> 00:00:04.000
            <v Yamada Taro>おはようございます</v>
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.utterances.count == 1)
        #expect(parsed.utterances[0].speaker == "Yamada Taro")
        #expect(parsed.utterances[0].text == "おはようございます")
    }

    /// .srt はコンマ区切りのミリ秒を使う。
    @Test func srt形式の時間も読む() throws {
        let text = """
            1
            00:00:05,500 --> 00:00:08,000
            Yamada Taro: はい。
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.utterances[0].offset == 5.5)
    }

    /// 折り返された字幕は1つの発言につなげる。
    @Test func 折り返された字幕は1発言にまとめる() throws {
        let text = """
            WEBVTT

            00:00:01.000 --> 00:00:06.000
            Yamada Taro: 長い話をします
            そして続きます
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.utterances.count == 1)
        #expect(parsed.utterances[0].text == "長い話をします そして続きます")
    }

    // MARK: - 話者の割り当てと書き出し

    @Test func 選んだ話者だけが自分になり実名は残る() throws {
        let parsed = try MeetingTranscriptImport.parse(meetSample)
        let text = MeetingTranscriptImport.transcript(
            from: parsed, me: "渡辺健太", startDate: date(hour: 10, minute: 0))

        #expect(text.contains("[10:00:44] 相手(菅原啓史): おはようございます。"))
        #expect(text.contains("[10:00:44] 自分(渡辺健太): 今日はなつめさんいないんだっけ?"))
    }

    /// 自分を選ばなかった場合は全員が相手になる。実名は変わらず残る。
    @Test func 自分を選ばなければ全員が相手になる() throws {
        let parsed = try MeetingTranscriptImport.parse(meetSample)
        let text = MeetingTranscriptImport.transcript(
            from: parsed, me: nil, startDate: date(hour: 10, minute: 0))

        #expect(!text.contains("自分"))
        #expect(text.contains("相手(渡辺健太):"))
    }

    /// 書き出した文字起こしを読み戻すと、話者・実名・発言がそのまま取れる
    /// (取り込んだセッションが履歴画面で録音セッションと同じように読めること)。
    @Test func 書き出した文字起こしを読み戻せる() throws {
        let start = date(hour: 10, minute: 0)
        let parsed = try MeetingTranscriptImport.parse(meetSample)
        let text = MeetingTranscriptImport.transcript(from: parsed, me: "渡辺健太", startDate: start)

        // 末尾の空行は録音したセッションの文字起こしと同じ(各行が改行で終わる)。
        let lines = TranscriptParser.lines(from: text, sessionStart: start)
        #expect(lines.count == 5)
        #expect(lines[4].body.isEmpty)
        #expect(lines[0].speaker == .other)
        #expect(lines[0].speakerName == "菅原啓史")
        #expect(lines[0].text == "おはようございます。")
        #expect(lines[0].offset == 44)
        #expect(lines[1].speaker == .me)
        #expect(lines[1].speakerName == "渡辺健太")
    }

    /// 実名の無い従来の行(録音したセッション)は、これまで通り読めること。
    @Test func 実名の無い従来の行も読める() {
        let start = date(hour: 10, minute: 0)
        let lines = TranscriptParser.lines(
            from: "[10:00:05] 自分: おはよう\n[10:00:09] 相手: こんにちは", sessionStart: start)
        #expect(lines[0].speaker == .me)
        #expect(lines[0].speakerName == nil)
        #expect(lines[0].text == "おはよう")
        #expect(lines[1].speakerName == nil)
    }

    /// 名前に丸括弧やコロンが入っていても、読み戻したときに発言側へ食い込まない。
    /// 半角の丸括弧は落とさず全角へ寄せる(「(Host)」のような表示名の中身を残すため)。
    @Test func 名前の半角括弧は全角に寄せて書き出す() {
        let start = date(hour: 10, minute: 0)
        let line = TranscriptWriter.line(
            time: start, speaker: .other, name: "山田 (営業):", text: "よろしく")
        #expect(line == "[10:00:00] 相手(山田 （営業）): よろしく")

        let parsed = TranscriptParser.lines(from: line, sessionStart: start)
        #expect(parsed[0].speakerName == "山田 （営業）")
        #expect(parsed[0].text == "よろしく")
    }

    /// 会議アプリの表示名によくある形。弾くとその人の発言がまるごと落ちるため、
    /// 全角の丸括弧と中黒は名前として通し、書き出しでもそのまま残す。
    @Test func 括弧や中黒を含む表示名も話者として読む() throws {
        let text = """
            WEBVTT

            00:00:01.000 --> 00:00:04.000
            山田太郎（営業）: よろしくお願いします

            00:00:05.000 --> 00:00:08.000
            ジョン・スミス: こちらこそ
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.speakers == ["山田太郎（営業）", "ジョン・スミス"])

        let line = TranscriptWriter.line(
            time: date(hour: 10, minute: 0), speaker: .other, name: "山田太郎（営業）",
            text: "よろしく")
        #expect(line == "[10:00:00] 相手(山田太郎（営業）): よろしく")
        let back = TranscriptParser.lines(from: line, sessionStart: date(hour: 10, minute: 0))
        #expect(back[0].speakerName == "山田太郎（営業）")
        #expect(back[0].text == "よろしく")
    }

    /// 発言の中の不等号を、字幕のタグと取り違えて後ろごと消さない。
    @Test func 閉じない山括弧は発言として残す() throws {
        let text = """
            WEBVTT

            00:00:01.000 --> 00:00:04.000
            Yamada Taro: a < b の場合は落ちます
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.utterances[0].text == "a < b の場合は落ちます")
    }

    /// 会議で「A --> B」と口にした一言があっても、字幕ファイルと取り違えない。
    /// 取り違えると発言を1件も拾えず、正常な文字起こしが丸ごと取り込めなくなる。
    @Test func 発言中の矢印を字幕形式と取り違えない() throws {
        let text = """
            9月 3, 2026
            マーケ定例 - 文字起こし
            00:00:10

            菅原啓史：データは API --> DB の順で流れます。
            渡辺健太：なるほど。
            菅原啓史：もう一度説明します。
            渡辺健太：はい。
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.source == .meet)
        #expect(parsed.utterances.count == 4)
        #expect(parsed.utterances[0].text == "データは API --> DB の順で流れます。")
    }

    /// 「結論: …」のような言い回しを新しい話者として切り出さない。
    /// 何度も出てくる名前が話者で、1度きりの名前は発言の一部。
    @Test func 一度きりの名前は話者にしない() throws {
        let text = """
            00:00:10

            菅原啓史：おはようございます。
            渡辺健太：はい。
            結論: 大丈夫です。
            菅原啓史：ありがとうございます。
            渡辺健太：では進めます。
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.speakers == ["菅原啓史", "渡辺健太"])
        #expect(parsed.utterances.count == 4)
        // 話者ではなかった行は、直前の発言に戻る。
        #expect(parsed.utterances[1].text == "はい。結論: 大丈夫です。")
    }

    /// 共有された URL を話者と取り違えない。
    @Test func URLで始まる発言を話者と取り違えない() {
        #expect(MeetingTranscriptImport.splitNamedSpeaker("https://example.com: 見てください") == nil)
    }

    /// 空行の無い書き出しで、次の字幕の通し番号を前の発言の末尾に混ぜない。
    @Test func 空行の無い字幕で番号を発言に混ぜない() throws {
        let text = """
            1
            00:00:01.000 --> 00:00:02.000
            Yamada Taro: text1
            2
            00:00:03.000 --> 00:00:04.000
            Suzuki Hanako: text2
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.utterances.count == 2)
        #expect(parsed.utterances[0].text == "text1")
        #expect(parsed.utterances[1].text == "text2")
    }

    /// 壊れた字幕で開始から24時間を超える位置は、壁時計表記に収まらないので落とす。
    @Test func 丸一日を超える位置の発言は落とす() throws {
        let text = """
            WEBVTT

            00:00:01.000 --> 00:00:04.000
            Yamada Taro: 最初の発言です

            25:00:00.000 --> 25:00:04.000
            Yamada Taro: 壊れた位置の発言です
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.utterances.count == 1)
        #expect(parsed.utterances[0].text == "最初の発言です")
    }

    /// 話者タグの名前にも長さの上限を掛ける(取り込み画面のチップがはみ出さないように)。
    @Test func 長すぎる話者タグは名前として使わない() throws {
        let long = String(repeating: "あ", count: 40)
        let text = """
            WEBVTT

            00:00:01.000 --> 00:00:04.000
            <v \(long)>おはようございます</v>
            """
        let parsed = try MeetingTranscriptImport.parse(text)
        #expect(parsed.utterances[0].speaker == nil)
        #expect(parsed.utterances[0].text == "おはようございます")
    }

    // MARK: - 読み取れない入力

    @Test func 空の入力は断る() {
        #expect(throws: MeetingTranscriptImport.ImportError.empty) {
            try MeetingTranscriptImport.parse("   \n\n  ")
        }
    }

    @Test func 発言の無い文章は断る() {
        #expect(throws: MeetingTranscriptImport.ImportError.unrecognized) {
            try MeetingTranscriptImport.parse("これはただのメモです。\n会議の文字起こしではありません。")
        }
    }

    /// 発言中のコロンを話者の区切りと取り違えない。
    @Test func 発言中のコロンは話者と見なさない() {
        #expect(MeetingTranscriptImport.splitNamedSpeaker("そこで、こう言った: だめだ。") == nil)
        #expect(MeetingTranscriptImport.splitNamedSpeaker("00:02:18") == nil)
        let named = MeetingTranscriptImport.splitNamedSpeaker("菅原啓史：はい。")
        #expect(named?.name == "菅原啓史")
        #expect(named?.text == "はい。")
    }

    /// ファイル名しか手がかりが無い書き出し(Zoom の字幕ファイル)から、
    /// 会議名と開始日時を拾えること。日時そのものは会議名にしない。
    @Test func ファイル名から会議名と開始日時を拾う() {
        let zoom = MeetingTranscriptImport.hints(
            forFileNamed: "GMT20260903-010000_Recording.transcript.vtt")
        #expect(zoom.name == nil)
        #expect(zoom.start != nil)

        let named = MeetingTranscriptImport.hints(forFileNamed: "マーケ定例.vtt")
        #expect(named.name == "マーケ定例")
        #expect(named.start == nil)
    }

    /// Zoom の書き出しファイル名にある日時(協定世界時)を開始日時として読む。
    @Test func Zoomのファイル名から開始日時を読む() throws {
        let start = try #require(
            MeetingTranscriptImport.startDate(
                fromFileName: "GMT20260903-010000_Recording.transcript.vtt"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = utc.dateComponents([.year, .month, .day, .hour], from: start)
        #expect(comps.year == 2026 && comps.month == 9 && comps.day == 3 && comps.hour == 1)
    }
}
