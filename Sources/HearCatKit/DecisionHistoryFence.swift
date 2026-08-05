import Foundation

/// 質問応答パネルの経緯回答が出力の一番最初(## 回答より前)に出す ```decision-history
/// フェンスの抽出。
///
/// 以前は AI に「変遷: ...」の文章そのものを書かせていたが、日付の生表記・理由の捏造・
/// セッション名の誤りが実機で発生した。いまは AI に該当議題の id 指定だけをこのフェンスで
/// 出させ、実際のタイムライン描画は decisions.json の記録からアプリ側(HearCatApp の
/// DecisionHistoryCardsView)が直接組み立てる。フェンスの中身は「どの議題を出すか」の
/// 指示に過ぎない。
///
/// SwiftUI に依存しない Foundation だけの実装にしているのは、CodeImpactOverlay.swift の
/// View から抜き出してテストできるようにするため(HearCatApp には単体テストの土台が無い)。
public enum DecisionHistoryFence {
    /// フェンスの中身をパースした結果。topicIds は decisions.json の DecisionTopic.id。
    public struct Prompt: Equatable, Sendable {
        public let topicIds: [String]

        public init(topicIds: [String]) {
            self.topicIds = topicIds
        }
    }

    /// extractFirst の戻り値。body は元のテキストからフェンス(見つかれば)を取り除いたもの。
    public struct ExtractResult: Equatable, Sendable {
        public let body: String
        public let prompt: Prompt?
        /// フェンスの開始行はあるが閉じていない(ストリーミング途中)。true の間、
        /// 呼び出し側は生 JSON を見せず場所取り(スピナー等)を出す判断に使ってよい。
        public let isPending: Bool
    }

    private struct JSON: Decodable {
        let topicIds: [String]
    }

    private static let openingLine = "```decision-history"

    /// テキストから最初の ```decision-history フェンスを 1 つ取り除く。
    /// - フェンスが無ければ (元のテキストそのまま, nil, false)。
    /// - 開始行はあるが閉じていなければ、開始行より前だけを body にし isPending を true にする
    ///   (choices フェンスのストリーミング中の扱いと同じ: 未完のフェンス以降は表示しない)。
    /// - 閉じているが中身が壊れた JSON・topicIds が空なら、フェンスは取り除くが prompt は nil
    ///   (生の JSON を画面に漏らさないが、カードも出さない)。
    public static func extractFirst(from text: String) -> ExtractResult {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard
            let openIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == openingLine
            })
        else {
            return ExtractResult(body: text, prompt: nil, isPending: false)
        }

        guard
            let closeIndex = lines[(openIndex + 1)...].firstIndex(where: {
                $0.hasPrefix("```")
            })
        else {
            let body = lines[..<openIndex].joined(separator: "\n")
            return ExtractResult(body: body, prompt: nil, isPending: true)
        }

        let jsonBody = lines[(openIndex + 1)..<closeIndex].joined(separator: "\n")
        var remainder = lines
        remainder.removeSubrange(openIndex...closeIndex)
        // フェンスは回答の一番最初(## 回答より前)に置かれる契約なので、取り除いた直後は
        // 前後に空行だけが残ることがある(フェンス前に本文が無い場合の先頭の空行、フェンス自体が
        // 応答の末尾だった場合の末尾の空行)。そのまま渡すと parseSections 側で無題の空セクションが
        // できてしまうため、前後の空行だけを畳む(本文中の意味のある空行はフェンスの外なので影響しない)。
        while let first = remainder.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            remainder.removeFirst()
        }
        while let last = remainder.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            remainder.removeLast()
        }
        return ExtractResult(
            body: remainder.joined(separator: "\n"), prompt: parse(jsonBody), isPending: false)
    }

    /// フェンスの中身(JSON 本文)を Prompt にパースする。JSON として壊れている、または
    /// topicIds が 1 件も残らない(空配列・全要素が空文字)場合は nil。
    static func parse(_ json: String) -> Prompt? {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(JSON.self, from: data)
        else { return nil }
        let ids = decoded.topicIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { return nil }
        return Prompt(topicIds: ids)
    }
}
