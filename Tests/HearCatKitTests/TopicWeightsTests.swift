import Foundation
import Testing

@testable import HearCatKit

struct TopicWeightsTests {
    /// "HH:MM:SS" を単純に秒数へ変換するだけのテスト用 offset(実際の壁時計変換の妥当性は
    /// TranscriptParserTests が担う。ここでは parse 自身のロジックだけを見る)。
    private func offset(_ stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    @Test func 壊れたJSONはnil() {
        #expect(TopicWeights.parse("not json", offset: offset) == nil)
    }

    @Test func 話題が0件ならnil() {
        let json = #"{"topics": []}"#
        #expect(TopicWeights.parse(json, offset: offset) == nil)
    }

    @Test func topicsキーが無いJSONはnil() {
        #expect(TopicWeights.parse("{}", offset: offset) == nil)
    }

    @Test func titleだけでtopicsキーが無いJSONもnil() {
        let json = #"{"title": "x"}"#
        #expect(TopicWeights.parse(json, offset: offset) == nil)
    }

    @Test func 範囲が逆転していれば捨てて他の有効な範囲だけ残す() {
        let json = #"""
            {"topics": [
                {"label": "価格", "ranges": [["00:10:00", "00:09:00"], ["00:20:00", "00:21:00"]]}
            ]}
            """#
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.topics.count == 1)
        #expect(result?.topics.first?.mentions == 1)
        #expect(result?.topics.first?.seconds == 60)
    }

    @Test func 全範囲が無効な話題は捨てられる() {
        let json = #"""
            {"topics": [
                {"label": "価格", "ranges": [["00:10:00", "00:09:00"]]},
                {"label": "納期", "ranges": [["00:20:00", "00:21:00"]]}
            ]}
            """#
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.topics.count == 1)
        #expect(result?.topics.first?.label == "納期")
    }

    @Test func 変換できない時刻表記の範囲は捨てられる() {
        let json = #"""
            {"topics": [
                {"label": "価格", "ranges": [["不正", "00:09:00"], ["00:10:00", "00:11:00"]]}
            ]}
            """#
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.topics.first?.mentions == 1)
    }

    @Test func ラベルが空の話題は捨てられる() {
        let json = #"""
            {"topics": [
                {"label": "  ", "ranges": [["00:10:00", "00:11:00"]]},
                {"label": "納期", "ranges": [["00:20:00", "00:21:00"]]}
            ]}
            """#
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.topics.count == 1)
        #expect(result?.topics.first?.label == "納期")
    }

    @Test func 合計時間の降順に並ぶ() {
        let json = #"""
            {"topics": [
                {"label": "短い話題", "ranges": [["00:00:00", "00:00:10"]]},
                {"label": "長い話題", "ranges": [["00:01:00", "00:03:00"]]}
            ]}
            """#
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.topics.map(\.label) == ["長い話題", "短い話題"])
    }

    @Test func 話題が8件を超える場合は上位8件に切り詰められる() {
        let topics = (0..<10).map { index in
            #"{"label": "話題\#(index)", "ranges": [["00:\#(String(format: "%02d", index)):00", "00:\#(String(format: "%02d", index)):\#(String(format: "%02d", 10 + index))"]]}"#
        }.joined(separator: ",")
        let json = #"{"topics": [\#(topics)]}"#
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.topics.count == 8)
        // 一番長い(index 9: 19秒)から順に並ぶはず。
        #expect(result?.topics.first?.label == "話題9")
    }

    @Test func タイトルは省略可() {
        let json = #"{"topics": [{"label": "価格", "ranges": [["00:00:00", "00:00:10"]]}]}"#
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.title == nil)
    }

    @Test func タイトルがあれば保持される() {
        let json = #"""
            {"title": "気になっていた話題", "topics": [{"label": "価格", "ranges": [["00:00:00", "00:00:10"]]}]}
            """#
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.title == "気になっていた話題")
    }

    @Test func firstStartは最も早い有効な区間の壁時計() {
        let json = #"""
            {"topics": [
                {"label": "価格", "ranges": [["00:20:00", "00:21:00"], ["00:05:00", "00:06:00"]]}
            ]}
            """#
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.topics.first?.firstStart == "00:05:00")
    }

    // MARK: - measure(尺度)

    /// 価格: 1 回だが合計 100 秒。納期: 3 回だが合計 30 秒。
    /// time なら価格が先、count なら納期が先になる、両方の並びが逆転する材料。
    private static let measureFixtureJSON = #"""
        {"topics": [
            {"label": "価格", "ranges": [["00:00:00", "00:01:40"]]},
            {"label": "納期", "ranges": [["00:10:00", "00:10:10"], ["00:20:00", "00:20:10"], ["00:30:00", "00:30:10"]]}
        ]}
        """#

    @Test func measure省略はtimeとして合計時間順に並ぶ() {
        let result = TopicWeights.parse(Self.measureFixtureJSON, offset: offset)
        #expect(result?.measure == .time)
        #expect(result?.topics.map(\.label) == ["価格", "納期"])
    }

    @Test func measureにcountを指定すると回数順に並ぶ() {
        let json = Self.measureFixtureJSON.replacingOccurrences(
            of: "{\"topics\"", with: "{\"measure\": \"count\", \"topics\"")
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.measure == .count)
        #expect(result?.topics.map(\.label) == ["納期", "価格"])
    }

    @Test func measureに不正な値を指定するとtime扱いになる() {
        let json = Self.measureFixtureJSON.replacingOccurrences(
            of: "{\"topics\"", with: "{\"measure\": \"foo\", \"topics\"")
        let result = TopicWeights.parse(json, offset: offset)
        #expect(result?.measure == .time)
        #expect(result?.topics.map(\.label) == ["価格", "納期"])
    }
}
