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
/// チャンクごとに @Generable の構造化生成で「行番号 + 清書本文」を受け取り、
/// 番号で原文の行と突き合わせる。失敗したチャンクは原文のまま残す
/// (清書は読みやすさ優先の派生物なので、欠けるより直らない方がまし)。
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
    /// コンテキストが小さく、清書は入力とほぼ同じ長さの出力を要するため、
    /// 要約(1500字)より控えめに取る。
    private static let chunkMaxLines = 15
    private static let chunkMaxChars = 900
    private static let maxResponseTokens = 1200
    /// 直前のチャンクから文脈として見せる行数(直させはしない)。
    private static let contextLineCount = 3

    @Generable
    fileprivate struct CleanedLines {
        @Guide(description: "清書した行。入力と同じ行番号で、全行ぶん返す", .maximumCount(15))
        var lines: [CleanedLine]
    }

    @Generable
    fileprivate struct CleanedLine {
        @Guide(description: "入力の行番号")
        var number: Int

        @Guide(description: "清書後の発言本文。行番号・時刻・話者名は含めない")
        var text: String
    }

    private static let instructions = """
        あなたは会話の文字起こしの校正係です。音声認識の誤変換を、会話の文脈から本来の言葉に直します。
        発言は話し言葉のまま残し、要約・言い換え・敬語化はしません。
        確信できる誤変換だけを直し、不明瞭な部分はそのまま残します。
        発言の意味・語尾・長さを大きく変えてはいけません。
        出力の本文に行番号・時刻・話者名を含めてはいけません。
        """

    /// transcript 全体を清書し、同じ「[時刻] 話者: 本文」形式で返す。
    /// progress には処理済みチャンクの割合(0〜1)を渡す。
    static func clean(
        transcript: String, progress: (@MainActor (Double) -> Void)? = nil
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

        var cleaned = lines
        var succeededChunks = 0
        for (index, chunk) in chunks.enumerated() {
            if let results = await cleanChunk(lines: lines, range: chunk) {
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

    /// 1チャンクを清書する。返り値は (行 index, 清書本文)。失敗したら nil(原文のまま残す)。
    private static func cleanChunk(lines: [String], range: [Int]) async -> [(Int, String)]? {
        // 番号はチャンク内で 1 から振り直す(小さい数字の方がモデルが取り違えない)。
        var numbered: [Int: Int] = [:]  // チャンク内番号 → 行 index
        var body = ""
        for (offset, lineIndex) in range.enumerated() {
            guard let (_, speaker, text) = splitLine(lines[lineIndex]) else { continue }
            numbered[offset + 1] = lineIndex
            body += "\(offset + 1) (\(speaker)): \(text)\n"
        }

        var context = ""
        if let first = range.first, first > 0 {
            let head = lines[..<first].suffix(contextLineCount)
                .compactMap { splitLine($0).map { "\($0.speaker): \($0.text)" } }
            if !head.isEmpty {
                context = "直前の会話(文脈として読むだけで、直さない):\n" + head.joined(separator: "\n") + "\n\n"
            }
        }

        let prompt = """
            \(context)清書する発言(番号 (話者): 本文):
            \(body)
            """

        let options = GenerationOptions(maximumResponseTokens: maxResponseTokens)
        // decodingFailure はサンプリングの非決定性に賭けて1回だけやり直す(要約側と同じ知見)。
        for _ in 0..<2 {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(
                    to: prompt, generating: CleanedLines.self, options: options)
                var results: [(Int, String)] = []
                for line in response.content.lines {
                    guard let lineIndex = numbered[line.number] else { continue }
                    let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, sane(text, original: lines[lineIndex]) else { continue }
                    results.append((lineIndex, text))
                }
                return results
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

    /// モデルの暴走(要約・膨張・話者名の混入)を弾く。清書は原文と同程度の長さのはず。
    private static func sane(_ text: String, original: String) -> Bool {
        guard let (_, _, body) = splitLine(original) else { return false }
        if text.count > body.count * 2 + 10 { return false }
        if text.count < body.count / 3 { return false }
        return true
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
