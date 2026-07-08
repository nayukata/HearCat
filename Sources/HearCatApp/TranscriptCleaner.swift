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
        @Guide(description: "誤変換された表記。本文に書かれている通り、変わる言葉だけを短く")
        var wrong: String

        @Guide(description: "直した表記")
        var right: String
    }

    /// 誤変換ペアの wrong の長さ上限。長いフレーズのペアを許すと、行の大部分を
    /// 巻き込んだ書き換え(言い換えの混入)ができてしまい、読みの比較も薄まる。
    private static let fixMaxLength = 12
    /// 同じチャンクを観点を変えて複数回見せ、見つけたペアの和集合を取る(同じ wrong は
    /// 先勝ち)。同じプロンプトの繰り返しはほぼ同じ答えしか返さないため、回数でなく
    /// 観点で散らす。temperature は 0.6 に下げてブレを抑える(0.8 は junk が増えた)。
    private static let passFocuses = [
        "",
        "特に、漢字の同音異義語への誤変換(講座↔口座、保証↔保障、機械↔機会 のような変換ミス)を疑って探してください。\n\n",
        "特に、カタカナ語・固有名詞・専門用語の誤変換を疑って探してください。\n\n",
    ]

    /// 用語集・ヒントを指示文に入れる際の上限。オンデバイスモデルのコンテキストが
    /// 小さいため、長すぎる分は頭から切る(チャンク本文の入る余地を必ず残す)。
    private static let maxHintChars = 400

    private static let instructions = """
        あなたは会話の文字起こしの校正係です。音声認識が誤変換した表記を見つけ、
        「誤変換された表記(wrong)」と「本来の表記(right)」の組で報告します。
        音声認識は音を正しく拾えても、同じ音の別の言葉に変換してしまいがちです。
        各行を読み、文脈に合わない言葉があれば、同じ音で文脈に合う言葉への修正を報告します。
        例: 銀行の話で「講座を開設」→「口座を開設」、話題が格闘ゲームなら「残ギ」→「ザンギ」。
        会話の話題や用語集が与えられた場合、それに音が似た言葉もその語へ直します。
        言い換え・要約・敬語化はしません。wrong と right は読みの音が似ている組だけにします。
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

        let options = GenerationOptions(
            temperature: 0.6, maximumResponseTokens: maxResponseTokens)
        var collected: [Fix] = []
        var seenWrongs = Set<String>()
        var succeededPasses = 0
        for focus in passFocuses {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(
                    to: focus + prompt, generating: Corrections.self, options: options)
                succeededPasses += 1
                for fix in response.content.fixes where seenWrongs.insert(fix.wrong).inserted {
                    collected.append(fix)
                }
            } catch {
                // decodingFailure・guardrail などはこのパスを捨てて次へ
                // (サンプリングの非決定性に賭ける。要約側と同じ知見)。
                continue
            }
        }
        guard succeededPasses > 0 else { return nil }
        return apply(fixes: collected, to: lines, range: range)
    }

    /// 誤変換ペアをチャンク内の行に適用する。1文字だけの wrong は誤爆しやすいので
    /// 捨て、長い wrong から先に置換する(「残ギ使い」と「残ギ」が両方報告された時に
    /// 短い方が先に潰さないように)。変わった行だけを行単位の検査(sane)に通す。
    private static func apply(fixes: [Fix], to lines: [String], range: [Int]) -> [(Int, String)] {
        let valid = fixes.filter { fix in
            fix.wrong.count >= 2 && fix.wrong.count <= fixMaxLength
                && !fix.right.isEmpty && fix.right != fix.wrong
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
    /// 「タメ波動→テクニック波動」「信託→保険」「去年→昨年」。
    private static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let aChars = Array(a), bChars = Array(b)
        var prefix = 0
        while prefix < min(aChars.count, bChars.count), aChars[prefix] == bChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(aChars.count, bChars.count) - prefix,
            aChars[aChars.count - 1 - suffix] == bChars[bChars.count - 1 - suffix]
        {
            suffix += 1
        }
        let diffA = aChars[prefix..<(aChars.count - suffix)]
        let diffB = bChars[prefix..<(bChars.count - suffix)]
        let punctuation = Set("。、．，？！?!., 　")
        if diffB.isEmpty {
            // 純粋な削除(してきたよ→したよ)は発言の省略なので、句読点を消す
            // だけの場合(上が。って→上がって)しか認めない。
            return diffA.allSatisfy { punctuation.contains($0) }
        }
        if diffA.isEmpty {
            // 純粋な挿入は発言に無い言葉の付け足し。句読点の補いか、読みが
            // ほぼ変わらない小さな補正(クバネテス→クバネティス)だけ認める。
            return diffB.allSatisfy { punctuation.contains($0) }
                || similarity(reading(a), reading(b)) >= 0.85
        }
        // 置き換えは読みで比べる。漢字1文字の読みは隣の文字で決まるため
        // (進められた/勧められた は「進め/勧め」まで見て初めて同音と分かる)、
        // 差分の前後に1文字ずつ文脈を足してから読みを取る。ペア全体で比べないのは、
        // 「丁度いい期会→丁度いい集会」のように前後の同じ文字が読みの違いを薄めるため。
        let contextA = String(
            aChars[max(0, prefix - 1)..<min(aChars.count, aChars.count - suffix + 1)])
        let contextB = String(
            bChars[max(0, prefix - 1)..<min(bChars.count, bChars.count - suffix + 1)])
        return similarity(reading(contextA), reading(contextB)) >= 0.7
    }

    /// 漢字かな交じりを日本語のローマ字読みへ潰す(振り仮名を振る macOS の API)。
    /// kCFStringTransformToLatin は漢字を中国語のピンインで読んでしまい
    /// (信託→xintuo、保険→baoxian が似た読み扱いになる)、同音異義の判定に
    /// 使えないことを実測済み。濁点・半濁点は聞き間違えやすいので清音へ寄せる
    /// (ゴンボ/コンボ を同音扱いにする)。
    private static func reading(_ text: String) -> String {
        let cf = text as CFString
        var romaji = ""
        if let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cf, CFRangeMake(0, CFStringGetLength(cf)),
            kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        {
            while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
                if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
                {
                    romaji += latin
                } else {
                    let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                    romaji += (CFStringCreateWithSubstring(nil, cf, range) as String?) ?? ""
                }
            }
        }
        if romaji.isEmpty { romaji = text }
        romaji = romaji.applyingTransform(.stripDiacritics, reverse: false) ?? romaji
        romaji = romaji.lowercased().replacingOccurrences(of: " ", with: "")
        let voicingFold: [Character: Character] = [
            "g": "k", "z": "s", "d": "t", "b": "h", "p": "h", "j": "s", "f": "h",
        ]
        return String(romaji.map { voicingFold[$0] ?? $0 })
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
