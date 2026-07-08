import Foundation
import Testing

@testable import HearCatKit

/// 認識器が句読点の前に入れる半角スペースの掃除と、疑問文マークの整形。
struct PunctuationTidyTests {
    @Test func 句読点直前のスペースを詰める() {
        #expect(ChannelTranscriber.tightenPunctuation("どういうことなん ？") == "どういうことなん？")
        #expect(ChannelTranscriber.tightenPunctuation("そうか 。で、次 、いく") == "そうか。で、次、いく")
    }

    @Test func 数字や英語の前のスペースは残す() {
        #expect(ChannelTranscriber.tightenPunctuation("あと 5位は入らない。") == "あと 5位は入らない。")
        #expect(ChannelTranscriber.tightenPunctuation("GP エドとかは強い？") == "GP エドとかは強い？")
    }

    @Test func markAsQuestionは末尾スペースを剥がしてから付ける() {
        #expect(QuestionDetector.markAsQuestion("どんなコンボ選択 ") == "どんなコンボ選択？")
        #expect(QuestionDetector.markAsQuestion("使えるのかな。") == "使えるのかな？")
        #expect(QuestionDetector.markAsQuestion("もう入ってる？") == "もう入ってる？")
    }

    @Test func 句読点無しの単独1文字は幻聴とみなす() {
        #expect(ChannelTranscriber.isBareSingleChar("あ"))
        #expect(ChannelTranscriber.isBareSingleChar("M"))
        #expect(ChannelTranscriber.isBareSingleChar("ん"))
        #expect(ChannelTranscriber.isBareSingleChar(" あ "))
    }

    @Test func 句読点付き1文字や2文字以上は残す() {
        #expect(!ChannelTranscriber.isBareSingleChar("え？"))
        #expect(!ChannelTranscriber.isBareSingleChar("あ。"))
        #expect(!ChannelTranscriber.isBareSingleChar("あー"))
        #expect(!ChannelTranscriber.isBareSingleChar("うん"))
        #expect(!ChannelTranscriber.isBareSingleChar("俺?"))
    }
}
