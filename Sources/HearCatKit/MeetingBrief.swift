import Foundation

/// 進行中の会議を「ここまで」でまとめた結果。決まったことと、まだ決まっていないこと。
public struct MeetingBrief: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let text: String
        /// 根拠の発言の時刻。文字起こしの行頭と同じ "HH:mm:ss"(壁時計)。AI が返さなかった・読めなかったときは nil。
        public let time: String?

        public init(text: String, time: String?) {
            self.text = text
            self.time = time
        }
    }

    public var decided: [Item]
    public var open: [Item]

    public init(decided: [Item] = [], open: [Item] = []) {
        self.decided = decided
        self.open = open
    }

    public var isEmpty: Bool { decided.isEmpty && open.isEmpty }
}

/// 「ここまでをまとめる」で AI に渡す指示と、返ってきた文章の読み取り。
///
/// 返答は見出し 2 つと箇条書きの Markdown に決めている。AI は JSON より見出し付きの箇条書きの方が
/// 崩れにくく、崩れても行単位で拾えるため。
public enum MeetingBriefPrompt {
    public static let decidedHeading = "決まったこと"
    public static let openHeading = "まだ決まっていないこと"

    public static func build() -> String {
        """
        標準入力は進行中の会議の文字起こしです(各行は「[HH:mm:ss] 話者: 発言」)。ここまでの内容から、決まったことと、まだ決まっていないことを抜き出してください。

        出力は次の形式だけにしてください。前置き・後書き・コードフェンスは付けません。

        ## \(decidedHeading)
        - [HH:mm:ss] 決まった内容を 1 文で
        ## \(openHeading)
        - [HH:mm:ss] 話題に上がったが結論が出ていない内容を 1 文で

        ルール:
        - [HH:mm:ss] は、その根拠になった発言の行頭の時刻を文字起こしからそのまま写す。推測で作らない。分からなければ [] ごと省く。
        - 決まったことは、合意や決定が発言から読み取れるものだけ。提案や雑談は入れない。
        - 誰がやるかが分かるときは文末に「(自分)」「(相手)」を付ける。話者は「自分」「相手」だけで、人名は書かない。
        - 該当が無い見出しは、箇条書きを書かずに見出しだけ残す。
        - 1 項目は 1 文、80 文字以内。
        """
    }

    /// 切り詰めた文字起こしが、行頭の時刻でどれだけの長さ(分)にあたるか。時刻つきの行が 2 つ未満なら nil。
    /// 日をまたぐ場合は 24 時間を足して数える。
    public static func coveredMinutes(of transcript: String) -> Int? {
        let seconds = transcript.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                let stamp = MeetingBriefParser.normalizedTime(String(line[line.index(after: line.startIndex)..<close]))
            else { return nil }
            let parts = stamp.split(separator: ":").compactMap { Int($0) }
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        guard let first = seconds.first, let last = seconds.last, seconds.count >= 2 else { return nil }
        let span = last >= first ? last - first : last + 86400 - first
        return max(1, (span + 59) / 60)
    }

    /// 長い会議で入力が大きくなりすぎないよう、新しい側の行を残して先頭を落とす。
    /// 行の途中では切らない。1 行だけで上限を超えるときは、その行の末尾側を残す。
    public static func trimmedTranscript(_ transcript: String, maxCharacters: Int) -> String {
        guard transcript.count > maxCharacters, maxCharacters > 0 else { return transcript }
        var kept: [Substring] = []
        var total = 0
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let cost = line.count + 1
            if total + cost > maxCharacters {
                if kept.isEmpty { return String(line.suffix(maxCharacters)) }
                break
            }
            kept.append(line)
            total += cost
        }
        return kept.reversed().joined(separator: "\n")
    }
}

public enum MeetingBriefParser {
    public static let maxItemsPerSection = 30
    public static let maxTextLength = 160

    private enum Section {
        case decided
        case open
    }

    /// 箇条書き 1 件ぶん。子の項目や継続行を本文へつなぎ終えてから、最後に長さと「なし」を判定する。
    private struct Draft {
        var section: Section
        var indent: Int
        var text: String
        var time: String?
    }

    /// 見出しが 1 つも見つからない(指示した形式で返っていない)ときは nil。
    /// 見出しがあって項目が 0 件なのは「何も決まっていない」という正しい結果なので、空の MeetingBrief を返す。
    public static func parse(_ raw: String) -> MeetingBrief? {
        var drafts: [Draft] = []
        var section: Section?
        var sawHeading = false
        var current: Int?  // drafts の添字。継続行・子の項目のつなぎ先。

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") { continue }
            if isRule(line) {
                // 区切り線の後ろの行は、直前の項目の続きではない。
                current = nil
                continue
            }
            let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" }).count

            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" || $0 == " " })
                    .replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
                section = classify(heading)
                sawHeading = sawHeading || section != nil
                current = nil
                continue
            }
            if line.hasPrefix("**") {
                // 太字だけの行は見出し。「**注:** 本文」のように太字の後ろに本文が続く行は
                // 見出しではなく、項目にも節の切り替えにもしない(続く継続行も拾わない)。
                current = nil
                if let heading = boldHeading(of: line) {
                    // 単独の太字は `##` 見出しと同じ扱い。知らない語なら節を閉じる。
                    section = classify(heading)
                    sawHeading = sawHeading || section != nil
                }
                continue
            }

            if let body = bulletBody(of: line) {
                guard let section else { continue }
                let parsed = extract(from: body)
                if let parentIndex = current, indent > drafts[parentIndex].indent {
                    join(parsed, into: &drafts[parentIndex], separator: "、")
                } else {
                    drafts.append(
                        Draft(section: section, indent: indent, text: parsed.text, time: parsed.time))
                    current = drafts.count - 1
                }
            } else if let index = current {
                join(extract(from: line), into: &drafts[index], separator: nil)
            }
        }

        guard sawHeading else { return nil }
        var brief = MeetingBrief()
        for draft in drafts {
            guard let item = finalize(draft) else { continue }
            switch draft.section {
            case .decided:
                if brief.decided.count < maxItemsPerSection { brief.decided.append(item) }
            case .open:
                if brief.open.count < maxItemsPerSection { brief.open.append(item) }
            }
        }
        return brief
    }

    /// "H:mm" / "HH:mm:ss" を "HH:mm:ss" にそろえる。範囲外・読めないものは nil。
    public static func normalizedTime(_ text: String) -> String? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, (0..<24).contains(numbers[0]),
            (0..<60).contains(numbers[1]), numbers.count < 3 || (0..<60).contains(numbers[2])
        else { return nil }
        return String(format: "%02d:%02d:%02d", numbers[0], numbers[1], numbers.count == 3 ? numbers[2] : 0)
    }

    private static let openKeywords = ["まだ決まっていない", "未決事項", "未決", "保留"]
    private static let decidedKeywords = ["決まったこと", "決定事項", "合意事項", "確定事項"]

    /// 見出しの文言から節を決める。どれにも当たらない見出し(「決定の背景」など)は nil で、節を閉じる。
    /// 「まだ決まっていないこと」を先に調べ、決まったことと取り違えないようにする。
    private static func classify(_ heading: String) -> Section? {
        if openKeywords.contains(where: heading.contains) { return .open }
        if decidedKeywords.contains(where: heading.contains) { return .decided }
        return nil
    }

    /// 「**見出し**」「**見出し**:」「**見出し:**」の見出し部分。太字の後ろに本文が続く行は見出しではない。
    private static func boldHeading(of line: String) -> String? {
        let body = line.dropFirst(2)
        guard let close = body.range(of: "**") else { return nil }
        let rest = body[close.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
        guard rest.isEmpty else { return nil }
        return String(body[..<close.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
    }

    /// `---` `***` `___` のような区切り線。箇条書きのマーカーと取り違えない。
    private static func isRule(_ line: String) -> Bool {
        let chars = Set(line.filter { !$0.isWhitespace })
        return line.count >= 3 && chars.count == 1 && "-*_=".contains(chars.first!)
    }

    private static let bulletMarkers: [Character] = ["-", "*", "•", "・", "‣"]

    /// マーカーの直後に空白があるときだけ箇条書きとみなす(`-5度` や `**太字**` を拾わない)。
    private static func bulletBody(of line: String) -> String? {
        if let first = line.first, bulletMarkers.contains(first),
            let next = line.dropFirst().first, next.isWhitespace
        {
            return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // "1. " "1) " "1）" の番号付き。
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 2 {
            let rest = line.dropFirst(digits.count)
            if let mark = rest.first, ".)）".contains(mark),
                let next = rest.dropFirst().first, next.isWhitespace || mark == "）"
            {
                return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static let time = #"\d{1,2}:\d{2}(?::\d{2})?"#
    private static let leadingTime = try! NSRegularExpression(
        pattern: #"^[\[\(（【]\s*("# + time + #")(?:\s*[〜~\-–]\s*"# + time + #")?\s*[\]\)）】]\s*[:：\-–—]?\s*"#)
    private static let trailingTime = try! NSRegularExpression(
        pattern: #"\s*[\[\(（【]\s*("# + time + #")(?:\s*[〜~\-–]\s*"# + time + #")?\s*[\]\)）】]\s*$"#)
    /// 時刻として読めなかった `[]` `[abc]` も本文には残さない(指示は「分からなければ [] ごと省く」)。
    private static let leadingBracket = try! NSRegularExpression(pattern: #"^\[[^\]]{0,20}\]\s*"#)
    private static let placeholders: Set<String> = ["なし", "特になし", "該当なし", "(なし)", "（なし）", "-", "ー"]

    private static func extract(from body: String) -> (text: String, time: String?) {
        var text = body.replacingOccurrences(of: "**", with: "")
        var time: String?
        /// 一致した括弧を本文から外す。範囲表記は前半を根拠の位置とする。時刻として読めなくても括弧は外す。
        func strip(_ regex: NSRegularExpression) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                let whole = Range(match.range, in: text)
            else { return false }
            if match.numberOfRanges > 1, let timeRange = Range(match.range(at: 1), in: text) {
                time = normalizedTime(String(text[timeRange]))
            }
            text.removeSubrange(whole)
            return true
        }
        if !strip(leadingTime) { _ = strip(leadingBracket) }
        if time == nil { _ = strip(trailingTime) }
        return (text.split(whereSeparator: \.isWhitespace).joined(separator: " "), time)
    }

    private static func join(
        _ part: (text: String, time: String?), into draft: inout Draft, separator: String?
    ) {
        if draft.time == nil { draft.time = part.time }
        guard !part.text.isEmpty else { return }
        if let separator {
            draft.text += draft.text.isEmpty ? part.text : separator + part.text
        } else if let last = draft.text.last, let first = part.text.first,
            last.isASCII, first.isASCII
        {
            draft.text += " " + part.text
        } else {
            draft.text += part.text
        }
    }

    private static func finalize(_ draft: Draft) -> MeetingBrief.Item? {
        var text = draft.text
        guard !text.isEmpty, !placeholders.contains(text) else { return nil }
        if text.count > maxTextLength {
            text = String(text.prefix(maxTextLength)) + "…"
        }
        return MeetingBrief.Item(text: text, time: draft.time)
    }
}
