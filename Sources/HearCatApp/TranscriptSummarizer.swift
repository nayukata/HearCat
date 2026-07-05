import Foundation
import FoundationModels

/// 文字起こしをオンデバイス LLM (Apple Intelligence / FoundationModels) で要約する。
/// オンデバイスモデルはコンテキストが小さい(公称値は非公開、通説で約4096トークン)ため、
/// 「区間ごとに要約 → 縮むまで繰り返す → 最後に統合要約」の多段構えにし、
/// それでも上限を超えたらチャンクを半分にして1回だけやり直す。
enum TranscriptSummarizer {
    enum SummarizerError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            }
        }
    }

    /// 1回のプロンプトに入れる本文の最大文字数。指示文と応答分の余白を残した控えめな値。
    private static let chunkLimit = 1500

    private static let instructions = """
        あなたは会議の書記です。日本語の文字起こしを読み、重要な内容を日本語で簡潔にまとめます。
        文字起こしは「[時刻] 話者: 発言」の形式で、話者は「自分」と「相手」の2種類です。
        誤変換が含まれることがあるため、文脈から意味を補って読み取ってください。
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
            if case .exceededContextWindowSize = error {
                return try await summarize(transcript, limit: chunkLimit / 2)
            }
            throw error
        }
    }

    private static func summarize(_ transcript: String, limit: Int) async throws -> String {
        var content = transcript
        // 上限に収まるまで「区間要約」で縮める。長い会議では統合前の区間要約自体が
        // 上限を超えるため、1段では足りない。
        while content.count > limit {
            let chunks = split(content, limit: limit)
            // 区間ごとの要約は独立だが、オンデバイスモデルは並列実行の利得がないため直列に回す。
            var partials: [String] = []
            for (index, chunk) in chunks.enumerated() {
                let partial = try await respond(prompt: """
                    会議の内容の一部(区間 \(index + 1)/\(chunks.count))です。\
                    この区間で話された内容の要点を箇条書きでまとめてください。

                    \(chunk)
                    """)
                partials.append(partial)
            }
            let reduced = partials.joined(separator: "\n\n")
            // 要約しても縮まない場合は打ち切る(無限ループ防止)。超過すれば上位の再試行に回る。
            if reduced.count >= content.count {
                content = reduced
                break
            }
            content = reduced
        }
        return try await respond(prompt: """
            以下は会議の内容です。次の構成で要約を作ってください。
            - 概要: 2〜3文
            - 主な論点: 箇条書き
            - 決定事項: 箇条書き(なければ「なし」)
            - TODO・宿題: 箇条書き(なければ「なし」)

            \(content)
            """)
    }

    private static func respond(prompt: String) async throws -> String {
        // 呼び出しごとに新しいセッションを使う(履歴を持ち越すとコンテキストを圧迫するため)。
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
