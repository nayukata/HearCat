import Foundation

/// summary.md を構造化表示用に分解した結果。
/// 要約は「## 概要 / ## 話題ごとのまとめ / ## 決定事項 / ## TODO・宿題」の
/// 4 セクション構成(オンデバイス・エージェントとも同じプロンプトで固定)を想定する。
public struct ParsedSummary: Sendable {
    /// 「話題ごとのまとめ」内の ### 見出し1つぶん。
    /// 中身は段落(エージェント要約の自然文)と箇条書き(オンデバイス要約・過去の要約)の
    /// 両方がありえるため、ブロック単位で種別を持つ。
    public struct Topic: Identifiable, Sendable {
        public struct Block: Identifiable, Sendable {
            public let id: Int
            public let text: String
            public let isBullet: Bool
        }

        public let id: Int
        /// ### の見出し。見出しなしで本文だけが置かれていた場合は空文字。
        public let title: String
        public let blocks: [Block]
    }

    /// TODO 1件。「- {本文}(担当: {名前})」の担当部分を分離して保持する。
    public struct Todo: Identifiable, Sendable {
        public let id: Int
        public let text: String
        public let assignee: String?
    }

    public let overview: String
    public let topics: [Topic]
    public let decisions: [String]
    public let todos: [Todo]
}

/// summary.md のパーサー。想定の 4 セクション構成から外れた文書(未知の ## 見出しや
/// 先頭の前置きがあるもの)には nil を返す。中途半端に構造化すると想定外の部分が
/// 静かに欠落するため、その場合は呼び出し側が原文をそのまま表示する。
public enum SummaryParser {
    private static let overviewTitle = "概要"
    private static let topicsTitle = "話題ごとのまとめ"
    private static let decisionsTitle = "決定事項"
    private static let todosTitle = "TODO・宿題"

    public static func parse(_ markdown: String) -> ParsedSummary? {
        var overview: [String] = []
        var topics: [ParsedSummary.Topic] = []
        var decisions: [String] = []
        var todos: [ParsedSummary.Todo] = []

        var currentSection: String?
        // 話題セクション内で組み立て中の ### 見出しと本文ブロック。
        var topicTitle: String?
        var topicBlocks: [ParsedSummary.Topic.Block] = []

        func flushTopic() {
            guard let title = topicTitle else { return }
            if !title.isEmpty || !topicBlocks.isEmpty {
                topics.append(.init(id: topics.count, title: title, blocks: topicBlocks))
            }
            topicTitle = nil
            topicBlocks = []
        }

        // 直前が空行だったか。地の文の段落の区切り判定に使う。
        var afterBlankLine = false

        // 箇条書き行は1行=1ブロック、地の文は空行を挟まない連続行を1つの段落ブロックに
        // まとめる(Markdown の折り返しで複数行になった段落を分断しないため)。
        func appendTopicLine(_ line: String) {
            let stripped = stripBullet(line)
            let isBullet = stripped != line
            if !isBullet, !afterBlankLine, let last = topicBlocks.last, !last.isBullet {
                topicBlocks[topicBlocks.count - 1] = .init(
                    id: last.id, text: last.text + "\n" + stripped, isBullet: false)
            } else {
                topicBlocks.append(
                    .init(id: topicBlocks.count, text: stripped, isBullet: isBullet))
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                afterBlankLine = true
                continue
            }
            defer { afterBlankLine = false }

            if let title = heading(line, prefix: "## ") {
                flushTopic()
                switch title {
                case overviewTitle, topicsTitle, decisionsTitle, todosTitle:
                    currentSection = title
                default:
                    return nil  // 未知のセクション。欠落させないため全体をフォールバック。
                }
                continue
            }

            switch currentSection {
            case overviewTitle:
                overview.append(line)
            case topicsTitle:
                if let title = heading(line, prefix: "### ") {
                    flushTopic()
                    topicTitle = title
                } else {
                    // ### より前に本文が置かれていたら、見出しなしの話題として保持する。
                    if topicTitle == nil { topicTitle = "" }
                    appendTopicLine(line)
                }
            case decisionsTitle:
                decisions.append(stripBullet(line))
            case todosTitle:
                todos.append(todo(from: stripBullet(line), id: todos.count))
            default:
                return nil  // 最初の ## より前の前置き。想定形式ではない。
            }
        }
        flushTopic()

        // 空セクションのプレースホルダ「なし」は項目ではないため落とす。
        if decisions == ["なし"] { decisions = [] }
        if todos.count == 1, todos[0].text == "なし", todos[0].assignee == nil { todos = [] }

        // 全セクションが空(見出しすら無い、または中身が空)の文書は構造化する意味がない。
        if overview.isEmpty && topics.isEmpty && decisions.isEmpty && todos.isEmpty {
            return nil
        }
        return ParsedSummary(
            overview: overview.joined(separator: "\n"),
            topics: topics, decisions: decisions, todos: todos)
    }

    /// 行が指定レベルの見出しなら、そのタイトルを返す。
    private static func heading(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// 行頭の箇条書き記号を剥がす。要約の生成側が使い分ける記号に合わせる。
    private static func stripBullet(_ line: String) -> String {
        for prefix in ["- ", "* ", "・", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    /// 末尾の「(担当: 名前)」を分離する。半角・全角の括弧とコロンの揺れを許容する。
    /// Regex は Sendable でないため static に置けず(Swift 6 の並行性チェック)、
    /// 呼び出しごとにリテラルから作る。要約は高々数十行なのでコストは無視できる。
    private static func todo(from text: String, id: Int) -> ParsedSummary.Todo {
        let assigneePattern = /[（(]担当[:：]\s*(?<name>[^）)]+)[)）]$/
        if let match = text.firstMatch(of: assigneePattern) {
            let body = text[..<match.range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let name = String(match.output.name).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty && !name.isEmpty {
                return .init(id: id, text: body, assignee: name)
            }
        }
        return .init(id: id, text: text, assignee: nil)
    }
}
