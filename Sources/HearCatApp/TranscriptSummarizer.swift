import Foundation
import FoundationModels

/// 文字起こしをオンデバイス LLM (Apple Intelligence / FoundationModels) で要約する。
/// オンデバイスモデルはコンテキストが小さい(公称値は非公開、通説で約4096トークン)ため、
/// 「区間ごとに要約 → 縮むまで繰り返す → 最後に統合要約」の多段構えにし、
/// それでも上限を超えたらチャンクを半分にして1回だけやり直す。
///
/// 最終要約・区間要約とも自由文プロンプトではなく @Generable の構造化生成を使う。
/// Markdown への整形はアプリ側で行うため、見出しの粒度や重複はモデルの気まぐれに左右されない。
enum TranscriptSummarizer {
    enum SummarizerError: LocalizedError {
        case unavailable(String)
        case guardrailBlocked
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .guardrailBlocked:
                return "Apple のオンデバイスモデルの安全機能により、この内容は要約できませんでした。政治・医療・暴力表現などを含む話題で起こることがあります"
            case .generationFailed(let reason): return reason
            }
        }
    }

    /// 区間要約の結果。箇条書きの生テキストではなく配列で受け取り、整形はアプリ側で行う。
    /// points の件数は .count で構造的に縛る。上限がないと1441字の入力に対し出力が
    /// 4089トークンまで暴走し、コンテキスト超過を起こした実測がある(下限を切ると逆に1点だけの手抜きになる)。
    @Generable
    fileprivate struct SectionSummary {
        @Guide(description: "この区間で話された内容の要点。1項目1〜2文で、何がどう話されたかまで簡潔に書く", .count(2...8))
        var points: [String]
    }

    /// 最終統合要約の結果。Markdown の見出し構成はこの構造から機械的に組み立てる。
    @Generable
    fileprivate struct MeetingSummary {
        @Guide(description: "会議全体の概要。話の流れがわかる2〜3文")
        var overview: String

        @Guide(description: "主な論点。1項目1論点で、何がどう議論されたかまで書く。重要な順に並べる", .maximumCount(7))
        var topics: [String]

        @Guide(description: "会議で合意・確定した事項のみ。作業の進捗報告や状況説明は含めない。なければ空配列", .maximumCount(10))
        var decisions: [String]

        @Guide(description: "実行可能なアクションを「〜する」の形で書く。なければ空配列", .maximumCount(10))
        var todos: [String]
    }

    /// 1回のプロンプトに入れる本文の最大文字数。指示文と応答分の余白を残した控えめな値。
    private static let chunkLimit = 1500

    /// 出力トークンの上限。.count/.maximumCount と二重に効かせて暴走を止める保険。
    private static let sectionMaxResponseTokens = 600
    private static let meetingMaxResponseTokens = 1000

    /// guardrail 等で落ちた区間を分割サルベージする際の下限サイズと再帰深さの上限。
    /// これより細かく割っても文脈が失われて要約の質が落ちるだけなので、ここで諦める。
    private static let minSplitFragmentSize = 300
    private static let maxSplitDepth = 2

    private static let instructions = """
        あなたは会議の書記です。日本語の文字起こしを読み、重要な内容を日本語で構造化してまとめます。
        文字起こしは「[時刻] 話者: 発言」の形式で、話者は「自分」と「相手」の2種類です。
        誤変換が含まれることがあるため、文脈から意味を補って読み取ってください。
        相槌・雑談・挨拶など内容のない発言は無視してください。
        同じ内容を複数の項目に重複させないでください。
        「〜について議論されました」のような中身のない要約は禁止です。何がどう議論・決定されたかを具体的に書いてください。
        項目の文中ではかぎ括弧(「」)や引用符("")を使わないでください。
        """

    static func summarize(transcript: String) async throws -> String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw SummarizerError.unavailable(describe(reason))
        }

        do {
            return try await summarize(transcript, limit: chunkLimit)
        } catch let error as LanguageModelSession.GenerationError {
            // コンテキスト上限の正確な値は非公開のため、超過したら半分のチャンクで一度だけ再試行する。
            guard case .exceededContextWindowSize = error else {
                throw mapGenerationError(error)
            }
            do {
                return try await summarize(transcript, limit: chunkLimit / 2)
            } catch let retryError as LanguageModelSession.GenerationError {
                throw mapGenerationError(retryError)
            }
        }
    }

    private static func summarize(_ transcript: String, limit: Int) async throws -> String {
        var content = transcript
        var skippedSectionCount = 0
        // 上限に収まるまで「区間要約」で縮める。長い会議では統合前の区間要約自体が
        // 上限を超えるため、1段では足りない。
        while content.count > limit {
            let chunks = split(content, limit: limit)
            // 区間ごとの要約は独立だが、オンデバイスモデルは並列実行の利得がないため直列に回す。
            var partials: [String] = []
            for chunk in chunks {
                let (points, skipped) = try await resolveSection(chunk, depth: 0)
                if !points.isEmpty {
                    partials.append(points.map { "- \($0)" }.joined(separator: "\n"))
                }
                skippedSectionCount += skipped
            }
            if partials.isEmpty {
                throw SummarizerError.guardrailBlocked
            }
            let reduced = partials.joined(separator: "\n\n")
            // 要約しても縮まない場合は打ち切る(無限ループ防止)。超過すれば上位の再試行に回る。
            if reduced.count >= content.count {
                content = reduced
                break
            }
            content = reduced
        }

        let meeting: MeetingSummary
        do {
            meeting = try await respondMeeting(prompt: """
                以下は会議の内容です。概要・主な論点・決定事項・TODO をまとめてください。

                \(content)
                """)
        } catch let error as LanguageModelSession.GenerationError {
            if case .guardrailViolation = error {
                throw SummarizerError.guardrailBlocked
            }
            throw error
        }

        var markdown = format(meeting)
        if skippedSectionCount > 0 {
            markdown += "\n\n> 一部の内容(\(skippedSectionCount)か所)は要約できませんでした。"
                + "Apple のオンデバイスモデルの安全機能により、政治・医療・暴力表現などを含む話題は要約が拒否されることがあります"
        }
        return markdown
    }

    /// 1区間を要約する。guardrailViolation / refusal / exceededContextWindowSize が出た場合は
    /// 区間を丸ごと捨てる前に、行境界でほぼ半分の2断片に分けて再挑戦する。
    /// 実測: 1500字の区間内にある1文が guardrail に触れるだけで区間全体(約1500字)が
    /// 失われていた。ゲーム雑談の火力・攻撃などの語彙でも発動する程度に Apple の安全機能は
    /// 過敏なため、分割して巻き添え範囲を1文の周辺だけに縮める。
    /// 分割してもなお失敗する場合、minSplitFragmentSize 未満に割れる、または maxSplitDepth を
    /// 超える時点で打ち切り、その断片だけをスキップ扱いにする。
    private static func resolveSection(_ chunk: String, depth: Int) async throws -> (points: [String], skipped: Int) {
        do {
            let summary = try await respondSection(prompt: sectionPrompt(chunk))
            return (summary.points, 0)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .exceededContextWindowSize, .refusal:
                break
            default:
                throw error
            }
            let halves = splitInHalf(chunk)
            guard depth < maxSplitDepth, chunk.count >= minSplitFragmentSize * 2, halves.count == 2 else {
                return ([], 1)
            }
            var points: [String] = []
            var skipped = 0
            for half in halves {
                let result = try await resolveSection(half, depth: depth + 1)
                points += result.points
                skipped += result.skipped
            }
            return (points, skipped)
        }
    }

    private static func sectionPrompt(_ chunk: String) -> String {
        """
        会議の内容の一部です。この内容で話された要点をまとめてください。

        \(chunk)
        """
    }

    /// 行境界でできるだけ半分に近い2断片に分ける(発話の途中で切らない)。
    /// 改行のない1行だけの断片はこれ以上分割できないため、その場合は1個の配列を返す
    /// (呼び出し元がこれを検知して分割を諦める)。
    private static func splitInHalf(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return [text] }
        let half = text.count / 2
        var runningCount = 0
        var splitIndex = lines.count - 1
        for (i, line) in lines.enumerated() {
            runningCount += line.count + 1
            if runningCount >= half {
                splitIndex = i
                break
            }
        }
        let first = lines[0...splitIndex].joined(separator: "\n")
        let second = lines[(splitIndex + 1)...].joined(separator: "\n")
        return second.isEmpty ? [first] : [first, second]
    }

    private static func format(_ meeting: MeetingSummary) -> String {
        var sections: [String] = []
        sections.append("## 概要\n\(meeting.overview)")
        sections.append("## 主な論点\n" + bulletList(meeting.topics))
        sections.append("## 決定事項\n" + bulletList(meeting.decisions, emptyText: "なし"))
        sections.append("## TODO・宿題\n" + bulletList(meeting.todos, emptyText: "なし"))
        return sections.joined(separator: "\n\n")
    }

    private static func bulletList(_ items: [String], emptyText: String = "なし") -> String {
        guard !items.isEmpty else { return emptyText }
        return items.map { "- \($0)" }.joined(separator: "\n")
    }

    /// decodingFailure の実測: モデルが正しい points 配列をほぼ完成させたところで
    /// JSON の閉じ引用符 `"` を日本語のかぎ括弧 `」` と書き間違え、その後 JSON の外に
    /// 無関係な幻覚テキストを maximumResponseTokens まで垂れ流すケースが12区間中5区間で発生した。
    /// 中身自体は良質なことが多いため、サンプリングの非決定性に賭けて1回だけ構造化生成を
    /// リトライし、それでも駄目なら自由文で要点だけ取り出すフォールバックに落とす。
    private static func respondSection(prompt: String) async throws -> SectionSummary {
        let options = GenerationOptions(maximumResponseTokens: sectionMaxResponseTokens)
        for _ in 0..<2 {
            // 呼び出しごとに新しいセッションを使う(履歴を持ち越すとコンテキストを圧迫するため)。
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: SectionSummary.self, options: options)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                guard case .decodingFailure = error else { throw error }
            }
        }
        return try await respondSectionAsFreeText(prompt: prompt, options: options)
    }

    /// 構造化生成が2回連続で decodingFailure になった区間向けのフォールバック。
    /// 区間要約はこの後さらに統合要約の入力になるだけなので、構造がやや緩くても実害がない。
    private static func respondSectionAsFreeText(prompt: String, options: GenerationOptions) async throws -> SectionSummary {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt + "\n\n箇条書きで、1行1要点、各行1〜2文、最大8行で答えてください。",
            options: options
        )
        return SectionSummary(points: parseBulletLines(response.content))
    }

    /// フォールバック応答の "- " / "・" / "* " / "• " などの行頭記号を剥がして要点の配列にする。
    private static func parseBulletLines(_ text: String) -> [String] {
        let bulletPrefixes = ["- ", "・", "* ", "• "]
        var points: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if let prefix = bulletPrefixes.first(where: trimmed.hasPrefix) {
                trimmed = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
            guard !trimmed.isEmpty else { continue }
            points.append(trimmed)
            if points.count >= 8 { break }
        }
        return points
    }

    /// 統合要約は最終出力のフォーマット保証が必要なため、区間要約と違って自由文フォールバックはしない。
    /// decodingFailure はサンプリングの非決定性に賭けて最大2回リトライし、なお失敗したらエラーにする。
    private static func respondMeeting(prompt: String) async throws -> MeetingSummary {
        let options = GenerationOptions(maximumResponseTokens: meetingMaxResponseTokens)
        for _ in 0..<3 {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: MeetingSummary.self, options: options)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                guard case .decodingFailure = error else { throw error }
            }
        }
        throw SummarizerError.generationFailed("要約の生成に失敗しました。もう一度お試しください")
    }

    /// 行単位で limit 文字以内のかたまりに分ける(発話の途中で切らない)。
    private static func split(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [""] : chunks
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "この Mac はオンデバイスモデル(Apple Intelligence)に対応していません"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence が無効です。システム設定で有効にしてください"
        case .modelNotReady:
            return "モデルの準備中です。しばらくしてからもう一度お試しください"
        @unknown default:
            return "オンデバイスモデルを利用できません"
        }
    }

    /// GenerationError を英語のまま UI に漏らさず、日本語の SummarizerError に変換する。
    /// guardrailViolation は呼び出し元(区間要約/統合要約)で個別ハンドリング済みのため、
    /// ここに来るのはそれ以外の全区間失敗やその他のエラーケース。
    private static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> Error {
        switch error {
        case .guardrailViolation:
            return SummarizerError.guardrailBlocked
        case .exceededContextWindowSize:
            return SummarizerError.generationFailed("文字起こしが長すぎて要約できませんでした")
        case .assetsUnavailable:
            return SummarizerError.generationFailed("オンデバイスモデルのデータが利用できません。しばらくしてからもう一度お試しください")
        case .rateLimited:
            return SummarizerError.generationFailed("リクエストが集中しています。しばらくしてからもう一度お試しください")
        case .concurrentRequests:
            return SummarizerError.generationFailed("他の処理でモデルが使用中です。しばらくしてからもう一度お試しください")
        case .unsupportedLanguageOrLocale:
            return SummarizerError.generationFailed("この言語・ロケールには対応していません")
        case .unsupportedGuide, .decodingFailure:
            return SummarizerError.generationFailed("要約の生成に失敗しました")
        case .refusal:
            return SummarizerError.guardrailBlocked
        @unknown default:
            return SummarizerError.generationFailed("要約の生成に失敗しました")
        }
    }
}
