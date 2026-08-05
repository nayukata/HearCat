import Foundation
import Testing

@testable import HearCatKit

/// ```decision-history フェンスの抽出(DecisionHistoryFence.extractFirst)の検証。
struct DecisionHistoryFenceTests {

    @Test func フェンスが無ければ本文はそのままpromptはnil() {
        let text = "料金は月額980円のままです。"
        let result = DecisionHistoryFence.extractFirst(from: text)
        #expect(result.body == text)
        #expect(result.prompt == nil)
        #expect(result.isPending == false)
    }

    @Test func 閉じたフェンスからtopicIdsが抽出され本文から除かれる() {
        let text = """
            料金は月額980円で確定しています。
            ```decision-history
            {"topicIds": ["abc-123", "def-456"]}
            ```
            """
        let result = DecisionHistoryFence.extractFirst(from: text)
        #expect(result.prompt?.topicIds == ["abc-123", "def-456"])
        #expect(!result.body.contains("decision-history"))
        #expect(!result.body.contains("topicIds"))
        #expect(result.body.contains("料金は月額980円で確定しています。"))
        #expect(result.isPending == false)
    }

    @Test func フェンス前後のテキストが両方保たれる() {
        let text = """
            前段の文章。
            ```decision-history
            {"topicIds": ["abc-123"]}
            ```
            後段の文章。
            """
        let result = DecisionHistoryFence.extractFirst(from: text)
        #expect(result.body.contains("前段の文章。"))
        #expect(result.body.contains("後段の文章。"))
        #expect(!result.body.contains("topicIds"))
    }

    @Test func 壊れたJSONは無視されフェンスだけ本文から除かれる() {
        let text = """
            回答本文。
            ```decision-history
            { 壊れたJSON
            ```
            """
        let result = DecisionHistoryFence.extractFirst(from: text)
        #expect(result.prompt == nil)
        #expect(!result.body.contains("壊れたJSON"))
        #expect(result.body.contains("回答本文。"))
    }

    @Test func topicIdsが空配列ならpromptはnil() {
        let text = """
            ```decision-history
            {"topicIds": []}
            ```
            """
        let result = DecisionHistoryFence.extractFirst(from: text)
        #expect(result.prompt == nil)
    }

    @Test func 空文字だけのidは除外される() {
        let text = """
            ```decision-history
            {"topicIds": ["abc-123", "  ", ""]}
            ```
            """
        let result = DecisionHistoryFence.extractFirst(from: text)
        #expect(result.prompt?.topicIds == ["abc-123"])
    }

    @Test func 出力の先頭にあるフェンスを除いても前後に空行が残らない() {
        // 現在の契約はフェンスを出力の一番最初(## 回答より前)に置くこと
        // (AgentCodeImpactAnalyzer.decisionHistoryParagraph 参照)。除去後に空行だけの
        // 無題セクションができないことを確認する。
        let text = """
            ```decision-history
            {"topicIds": ["abc-123"]}
            ```

            ## 回答
            料金は月額980円で確定しています。
            """
        let result = DecisionHistoryFence.extractFirst(from: text)
        #expect(result.prompt?.topicIds == ["abc-123"])
        #expect(result.body.hasPrefix("## 回答"))
    }

    @Test func 開始行はあるが閉じていない場合はpendingで開始行以降が本文から消える() {
        let text = """
            回答の途中まで。
            ```decision-history
            {"topicId
            """
        let result = DecisionHistoryFence.extractFirst(from: text)
        #expect(result.isPending == true)
        #expect(result.prompt == nil)
        #expect(result.body == "回答の途中まで。")
    }
}
