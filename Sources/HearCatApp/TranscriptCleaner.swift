import Foundation
import FoundationModels
import HearCatKit

/// 文字起こしの誤変換をオンデバイス LLM で清書する。
///
/// 行の構造(時刻・話者・行数・順序)は一切変えず、発言の本文だけを直す。
/// 原文(transcript)は「実際にどう認識されたか」の一次記録として残し、
/// 結果は別ファイル(cleaned.md)に同じ形式で書く前提。形式を保つことで、
/// 時刻クリックの再生ジャンプが清書側でもそのまま機能する。
///
/// モデルには行を書き直させず、チャンクごとに「誤変換の表記 → 正しい表記」の
/// ペアだけを報告させ、置換はコード側で行う。行まるごとの書き直しは、行の
/// 切り落とし・隣の行とのすり替わり・修正の当たり外れが大きいことを実測済み。
/// 失敗したチャンクは原文のまま残す(清書は読みやすさ優先の派生物なので、
/// 欠けるより直らない方がまし)。
enum TranscriptCleaner {
    enum CleanerError: LocalizedError {
        case unavailable(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .failed(let reason): return reason
            }
        }
    }

    /// 1チャンクに入れる行数と文字数の上限。オンデバイスモデルは入出力合計の
    /// コンテキストが小さいため、要約(1500字)より控えめに取る。
    private static let chunkMaxLines = 15
    private static let chunkMaxChars = 900
    /// 出力は誤変換ペアのリストだけなので、行の書き直し(1200)より小さくてよい。
    private static let maxResponseTokens = 500
    /// 直前のチャンクから文脈として見せる行数(直させはしない)。
    private static let contextLineCount = 3

    @Generable
    fileprivate struct Corrections {
        @Guide(description: "見つけた誤変換。無ければ空のリスト", .maximumCount(10))
        var fixes: [Fix]
    }

    @Generable
    fileprivate struct Fix {
        @Guide(description: "誤変換された表記。会話の本文に書かれている通りに")
        var wrong: String

        @Guide(description: "直した表記")
        var right: String
    }

    /// 用語集・ヒントを指示文に入れる際の上限。オンデバイスモデルのコンテキストが
    /// 小さいため、長すぎる分は頭から切る(チャンク本文の入る余地を必ず残す)。
    private static let maxHintChars = 400

    private static let instructions = """
        あなたは会話の文字起こしの校正係です。音声認識が誤変換した表記を見つけ、
        「誤変換された表記(wrong)」と「本来の表記(right)」の組で報告します。
        会話の話題や用語集が与えられた場合、それに音が似た言葉は誤変換の可能性が高いので、
        その語への修正を報告します(例: 話題が格闘ゲームなら「残ギ」→「ザンギ」)。
        文脈から確信できる誤変換だけを報告し、言い換え・要約・敬語化はしません。
        誤変換は「同じ音への別の当て字」なので、wrong と right は読みの音が似ている組だけにします。
        wrong は本文に書かれている通りの表記にします。誤変換が無ければ空のリストを返します。
        """

    /// ユーザーの指示(ヒント)と用語集を、各チャンクのプロンプト先頭に置くブロックにする。
    /// 指示文(instructions)側に入れると小さいモデルはほぼ無視することを実測済みのため、
    /// 直す本文と同じプロンプトに置いて注意を向けさせる。
    private static func hintBlock(glossary: String, hints: String) -> String {
        var block = ""
        let hints = String(hints.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxHintChars))
        if !hints.isEmpty {
            block += "会話の話題(この文脈で誤変換を直す):\n\(hints)\n\n"
        }
        let glossary = String(
            glossary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxHintChars))
        if !glossary.isEmpty {
            block += "用語集(音が似た言葉はこの語の誤変換なので直す):\n\(glossary)\n\n"
        }
        return block
    }

    /// transcript 全体を清書し、同じ「[時刻] 話者: 本文」形式で返す。
    /// glossary は設定の用語集(全セッション共通、「語: 説明」形式)、
    /// hints はこのセッションの清書への指示(話題や直し方の希望)。
    /// progress には処理済みチャンクの割合(0〜1)を渡す。
    static func clean(
        transcript: String, glossary: String = "", hints: String = "",
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> String {
        if let reason = OnDeviceModel.unavailableReason() {
            throw CleanerError.unavailable(reason)
        }

        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let chunks = chunkIndices(of: lines)
        guard !chunks.isEmpty else {
            throw CleanerError.failed("清書できる発言がありません")
        }

        let hintBlock = hintBlock(glossary: glossary, hints: hints)
        var cleaned = lines
        var succeededChunks = 0
        for (index, chunk) in chunks.enumerated() {
            if let results = await cleanChunk(lines: lines, range: chunk, hintBlock: hintBlock) {
                for (lineIndex, text) in results {
                    cleaned[lineIndex] = replaceBody(of: lines[lineIndex], with: text)
                }
                succeededChunks += 1
            }
            await progress?(Double(index + 1) / Double(chunks.count))
        }
        guard succeededChunks > 0 else {
            throw CleanerError.failed("清書に失敗しました。もう一度お試しください")
        }
        return cleaned.joined(separator: "\n")
    }

    /// 発話行だけをチャンクに割る(空行や形式外の行は清書対象にしない)。
    /// 各チャンクは「行 index の配列」。行数と文字数の両方で上限を掛ける。
    private static func chunkIndices(of lines: [String]) -> [[Int]] {
        var chunks: [[Int]] = []
        var current: [Int] = []
        var currentChars = 0
        for (index, line) in lines.enumerated() {
            guard splitLine(line) != nil else { continue }
            if !current.isEmpty,
                current.count >= chunkMaxLines || currentChars + line.count > chunkMaxChars
            {
                chunks.append(current)
                current = []
                currentChars = 0
            }
            current.append(index)
            currentChars += line.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// 1チャンクの誤変換ペアをモデルから集め、範囲内の行へ適用する。
    /// 返り値は (行 index, 置換後の本文)。生成に失敗したら nil(原文のまま残す)。
    private static func cleanChunk(
        lines: [String], range: [Int], hintBlock: String
    ) async -> [(Int, String)]? {
        var body = ""
        for lineIndex in range {
            guard let (_, speaker, text) = splitLine(lines[lineIndex]) else { continue }
            body += "(\(speaker)): \(text)\n"
        }

        var context = ""
        if let first = range.first, first > 0 {
            let head = lines[..<first].suffix(contextLineCount)
                .compactMap { splitLine($0).map { "\($0.speaker): \($0.text)" } }
            if !head.isEmpty {
                context = "直前の会話(文脈として読むだけで、探す対象ではない):\n" + head.joined(separator: "\n") + "\n\n"
            }
        }

        let prompt = """
            \(hintBlock)\(context)誤変換を探す会話((話者): 本文):
            \(body)
            """

        let options = GenerationOptions(maximumResponseTokens: maxResponseTokens)
        // decodingFailure はサンプリングの非決定性に賭けて1回だけやり直す(要約側と同じ知見)。
        for _ in 0..<2 {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(
                    to: prompt, generating: Corrections.self, options: options)
                return apply(fixes: response.content.fixes, to: lines, range: range)
            } catch let error as LanguageModelSession.GenerationError {
                if case .decodingFailure = error { continue }
                // guardrail・コンテキスト超過などはこのチャンクを原文のまま残す。
                return nil
            } catch {
                return nil
            }
        }
        return nil
    }

    /// 誤変換ペアをチャンク内の行に適用する。1文字だけの wrong は誤爆しやすいので
    /// 捨て、長い wrong から先に置換する(「残ギ使い」と「残ギ」が両方報告された時に
    /// 短い方が先に潰さないように)。変わった行だけを行単位の検査(sane)に通す。
    private static func apply(fixes: [Fix], to lines: [String], range: [Int]) -> [(Int, String)] {
        let valid = fixes.filter { fix in
            fix.wrong.count >= 2 && !fix.right.isEmpty && fix.right != fix.wrong
                && fix.right.count <= fix.wrong.count * 3 + 2
                // 語の後半をただ削っただけの組は修正ではない。
                && !fix.wrong.hasPrefix(fix.right)
                && soundsAlike(fix.wrong, fix.right)
        }
        .sorted { $0.wrong.count > $1.wrong.count }
        guard !valid.isEmpty else { return [] }

        var results: [(Int, String)] = []
        for lineIndex in range {
            guard let (_, _, original) = splitLine(lines[lineIndex]) else { continue }
            var text = original
            for fix in valid {
                text = text.replacingOccurrences(of: fix.wrong, with: fix.right)
            }
            text = normalizePunctuation(text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard text != original, !text.isEmpty, sane(text, original: lines[lineIndex]) else {
                continue
            }
            results.append((lineIndex, text))
        }
        return results
    }

    /// モデルの暴走を弾く。清書は「同じ発言の表記直し」なので、原文と長さも文字も
    /// 大きくは変わらないはず。実際に観測した暴走は3種:
    /// 後半の切り落とし・隣の行の内容の混入(番号ズレ)・隣の行を吸収した膨張。
    private static func sane(_ text: String, original: String) -> Bool {
        guard let (_, _, body) = splitLine(original) else { return false }
        if text.count * 3 > body.count * 4 + 30 { return false }
        if text.count * 3 < body.count * 2 { return false }
        if similarity(text, body) < 0.5 { return false }
        // 原文の先頭部分と完全一致(=末尾を削っただけ)は誤変換の修正ではありえない。
        if text.count < body.count, body.hasPrefix(text) { return false }
        // 逆に末尾へ足しただけの場合、句読点の補いだけは許す(それ以外は続きの捏造)。
        if text.count > body.count, text.hasPrefix(body),
            text.dropFirst(body.count).contains(where: { !"。、？！?!.,".contains($0) })
        {
            return false
        }
        return true
    }

    /// 誤変換は「同じ音への別の当て字」なので、wrong と right の読みは必ず近い。
    /// 読みが遠い組は言い換え(モデルの創作)とみなして捨てる。実測した創作の例:
    /// 「タメ波動→テクニック波動」「うんまあ→普通」。
    /// 比較は変わった部分だけで行う。「いや、いらない→いや、必要ない」のように
    /// 前後に同じ文字が付くと、全体の読みは似てしまい言い換えを見逃すため。
    private static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let (diffA, diffB) = strippedDifference(a, b)
        if diffA.isEmpty || diffB.isEmpty {
            // 純粋な挿入/削除(ザンギ→ザンギエフ 等)は差分の読みを比べられないので
            // 全体の読みで判定する。
            return similarity(reading(a), reading(b)) >= 0.5
        }
        return similarity(reading(diffA), reading(diffB)) >= 0.5
    }

    /// 先頭と末尾の共通部分を取り除き、双方の「変わった部分」だけを返す。
    private static func strippedDifference(_ a: String, _ b: String) -> (String, String) {
        var a = Array(a), b = Array(b)
        while let first = a.first, first == b.first {
            a.removeFirst()
            b.removeFirst()
        }
        while let last = a.last, last == b.last {
            a.removeLast()
            b.removeLast()
        }
        return (String(a), String(b))
    }

    /// 漢字かな交じりをローマ字読みへ潰す(macOS の transliteration が漢字も読む)。
    private static func reading(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return (mutable as String).lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// 文字の重なり具合(0〜1)。同じ文字(重複込み)が双方に何割あるか。
    /// 誤変換の修正は行の一部しか変えないため高くなり、別の行の内容への
    /// すり替わりはほぼ 0 になる。
    private static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for ch in a { counts[ch, default: 0] += 1 }
        var common = 0
        for ch in b where counts[ch, default: 0] > 0 {
            counts[ch, default: 0] -= 1
            common += 1
        }
        return Double(common) / Double(max(a.count, b.count))
    }

    /// モデルが日本語の文中に混ぜてくる半角句読点を全角へ戻す。
    /// 直前が日本語の文字の時だけ変換する(数字や英語の「18.5」「U.S.」は触らない)。
    private static func normalizePunctuation(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for ch in text {
            if let prev = previous, isJapanese(prev), ch == "." || ch == "," {
                let replaced: Character = ch == "." ? "。" : "、"
                result.append(replaced)
                previous = replaced
                continue
            }
            result.append(ch)
            previous = ch
        }
        return result
    }

    private static func isJapanese(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x309F,  // ひらがな
            0x30A0...0x30FF,  // カタカナ(ーを含む)
            0x4E00...0x9FFF,  // 漢字
            0x3005:  // 々
            return true
        default:
            return false
        }
    }

    /// 「[時刻] 話者: 本文」を分解する。形式外の行は nil。
    private static func splitLine(_ line: String) -> (stamp: String, speaker: String, text: String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let stamp = String(line[line.index(after: line.startIndex)..<close])
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let speaker = String(rest[..<colon])
        let text = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty, !text.isEmpty else { return nil }
        return (stamp, speaker, text)
    }

    /// 行の本文だけを清書後のものに置き換える(時刻・話者はそのまま)。
    private static func replaceBody(of line: String, with text: String) -> String {
        guard let (stamp, speaker, _) = splitLine(line) else { return line }
        return "[\(stamp)] \(speaker): \(text)"
    }
}
