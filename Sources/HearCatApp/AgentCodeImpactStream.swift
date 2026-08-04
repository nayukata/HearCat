import Foundation
import os

/// claude CLI のストリーミング実行(照合専用)から届く通知。
/// 呼び出し側(AppModel)は MainActor へ載せ替えてから状態を更新するため、
/// このクロージャ自体は @Sendable でよい。
enum CodeImpactStreamEvent: Sendable {
    /// system/init または result イベントから拾ったセッション ID。
    /// 会話を継続する(--resume)ために AppModel 側が保存する。
    case sessionID(String)
    /// assistant のテキスト応答の断片(120ms 程度に間引き済み)。
    case textDelta(String)
    /// ツール利用など、進捗として見せてよい 1 行(例: "Read: AppModel.swift")。
    case activity(String)
    /// フォールバックで実行をやり直す合図。直前の attempt で溜まった部分テキストは
    /// 引き継がず、受け取った側は codeImpactPartialText 等をクリアすること。
    case reset
}

/// claude CLI での「関連資料との照合」ストリーミング実行。
/// 要約と共用の AgentSummarizer.execute(非ストリーミング)は変えず、
/// このファイルに専用の実行経路を閉じ込める。codex はストリーミング/セッション継続の
/// 対象外(呼び出し側が従来の AgentCodeImpactAnalyzer.analyze を使う)。
enum AgentCodeImpactStream {
    private static let timeout: TimeInterval = 300
    /// 「unknown option」等での段階的フォールバックを含めても、合計の実行回数を
    /// この値までに制限する(組み合わせ次第で再実行が連鎖しても無限にしないため)。
    private static let maxAttempts = 3
    /// textDelta をまとめて通知する間隔。トークン単位で大量に届くため、そのまま
    /// 都度 UI へ流すと更新が過密になる。
    private static let textDeltaFlushInterval: TimeInterval = 0.12

    /// 1 回の実行で有効にする引数の組み合わせ。段階的フォールバックのたびに
    /// このどれかを falseにして(または resumeSessionID を落として)再実行する。
    private struct AttemptConfig {
        var includePartialMessages: Bool
        var includeSettingSources: Bool
        var resumeSessionID: String?
    }

    private enum FallbackDecision {
        /// 引数を変えてストリーミングのまま再実行する。
        case retry(AttemptConfig)
        /// ストリーミング自体を諦め、既存の非ストリーミング経路(AgentSummarizer.execute)へ落ちる。
        case fallbackToText
    }

    /// - Parameters:
    ///   - transcript: 未加工の文字起こし全体。AgentCodeImpactAnalyzer.recentTranscript で
    ///     直近部分に切ってから標準入力へ渡す(analyze() と同じ扱い)。
    ///   - resumeSessionID: 継続したい claude セッション ID。nil なら新規会話。
    ///   - onEvent: ストリーム中の通知。@Sendable(バックグラウンドの読み取りキューから呼ぶ)。
    /// - Returns: 抽出済み Markdown と、今回判明したセッション ID(セッションが尽きて
    ///   非ストリーミングへ落ちた場合は nil)。
    static func run(
        model: String?,
        transcript: String,
        referenceFolder: String?,
        prompt: String,
        resumeSessionID: String?,
        onEvent: @escaping @Sendable (CodeImpactStreamEvent) -> Void
    ) async throws -> (result: String, sessionID: String?) {
        guard let binaryPath = await AgentCLIResolver.resolve(.claude) else {
            throw AgentSummarizeError.notInstalled(.claude)
        }

        // referenceFolder が nil(資料フォルダ未紐付け)なら文字起こしだけで実行する。
        // 紐付けている場合でも、フォルダが移動・削除されていれば AgentSummarizer.execute と
        // 同じ扱い: cwd 指定と --allowedTools を諦めて続行する(照合の入口である
        // codeImpactContext() で存在確認済みだが、実行までの間に消える可能性はゼロではないため
        // 二重に見る)。
        let validatedReferenceFolder: String? = {
            guard let referenceFolder else { return nil }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: referenceFolder, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? referenceFolder : nil
        }()

        let trimmedTranscript = AgentCodeImpactAnalyzer.recentTranscript(from: transcript)

        var config = AttemptConfig(
            includePartialMessages: true,
            includeSettingSources: true,
            resumeSessionID: resumeSessionID)
        var attempts = 0
        var lastDiagnostics = ""
        var lastExitCode: Int32 = -1

        while attempts < maxAttempts {
            attempts += 1
            if attempts > 1 { onEvent(.reset) }

            let arguments = arguments(
                prompt: prompt, model: model, config: config,
                hasReferenceFolder: validatedReferenceFolder != nil)

            let outcome = try await runOnce(
                binaryPath: binaryPath,
                arguments: arguments,
                transcript: trimmedTranscript,
                referenceFolder: validatedReferenceFolder,
                onEvent: onEvent)

            if outcome.exitCode == 0 {
                guard outcome.resultSuccess, let resultText = outcome.resultText,
                    !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw AgentSummarizeError.unexpectedOutput(
                        excerpt: AgentSummarizer.excerpt(from: outcome.diagnostics))
                }
                guard let formatted = AgentSummarizer.extractMarkdown(resultText) else {
                    throw AgentSummarizeError.unexpectedOutput(
                        excerpt: AgentSummarizer.excerpt(from: resultText))
                }
                return (formatted, outcome.sessionID)
            }

            lastDiagnostics = outcome.diagnostics
            lastExitCode = outcome.exitCode

            // claude はログイン切れを標準出力側に出すことがある(AgentSummarizer.execute と同じ理由)。
            // 引数を変えても直らない失敗なので、フォールバックを試さずここで確定させる。
            if AgentSummarizer.isAuthError(lastDiagnostics) {
                throw AgentSummarizeError.notAuthenticated(.claude)
            }

            guard attempts < maxAttempts,
                let decision = nextFallback(diagnostics: lastDiagnostics, config: config)
            else {
                throw AgentSummarizeError.failed(
                    exitCode: lastExitCode, stderr: AgentSummarizer.summarize(stderr: lastDiagnostics))
            }

            switch decision {
            case .retry(let nextConfig):
                config = nextConfig
            case .fallbackToText:
                onEvent(.reset)
                onEvent(.activity("従来方式で調査中…"))
                let text = try await AgentSummarizer.execute(
                    using: .claude,
                    input: trimmedTranscript,
                    referenceFolder: referenceFolder,
                    prompt: prompt,
                    outputPrefix: "code-impact-stream-fallback",
                    model: model)
                return (text, nil)
            }
        }

        throw AgentSummarizeError.failed(
            exitCode: lastExitCode, stderr: AgentSummarizer.summarize(stderr: lastDiagnostics))
    }

    /// 診断出力(stderr + stdout)から、次に何を変えて再実行すべきかを決める。
    /// 上から順に判定し、最初に当てはまったものを採用する(設計メモの 1〜4 と対応)。
    private static func nextFallback(diagnostics: String, config: AttemptConfig) -> FallbackDecision? {
        let lower = diagnostics.lowercased()

        // 1. --include-partial-messages 自体を知らない古い claude。stream-json は維持したまま
        //    このオプションだけ外す(assistant/result イベントは残るので進捗と最終出力は取れる)。
        if config.includePartialMessages, lower.contains("unknown option"),
            lower.contains("--include-partial-messages")
        {
            var next = config
            next.includePartialMessages = false
            return .retry(next)
        }

        // 2. stream-json / --verbose 自体が unknown option。ストリーミングを諦め、
        //    既存の非ストリーミング経路(text 出力)へ落ちる。
        if lower.contains("unknown option"), lower.contains("stream-json") || lower.contains("--verbose") {
            return .fallbackToText
        }

        // 3. --setting-sources を知らない古い claude(AgentSummarizer.execute と同じ理屈)。
        if config.includeSettingSources, lower.contains("unknown option"),
            lower.contains("--setting-sources")
        {
            var next = config
            next.includeSettingSources = false
            return .retry(next)
        }

        // 4. --resume 付きの実行が失敗(セッション期限切れ等)。原因の切り分けはせず、
        //    resume を付けていて失敗した、というだけで一度だけ resume 無しに落とす。
        if config.resumeSessionID != nil {
            var next = config
            next.resumeSessionID = nil
            return .retry(next)
        }

        return nil
    }

    private static func arguments(
        prompt: String,
        model: String?,
        config: AttemptConfig,
        hasReferenceFolder: Bool
    ) -> [String] {
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        if config.includePartialMessages {
            args.append("--include-partial-messages")
        }
        if let model {
            args += ["--model", model]
        }
        if let resumeSessionID = config.resumeSessionID {
            args += ["--resume", resumeSessionID]
        }
        // referenceFolder が無ければ許可ツールのフラグ自体を渡さない(AgentSummarizer.execute と同じ)。
        if hasReferenceFolder {
            args += ["--allowedTools", "Read", "Grep", "Glob"]
        }
        if config.includeSettingSources {
            args += ["--setting-sources", "project"]
        }
        return args
    }

    // MARK: - 1 回分の Process 実行

    private struct AttemptOutcome {
        let exitCode: Int32
        let resultText: String?
        let resultSuccess: Bool
        let sessionID: String?
        /// stderr + stdout。フォールバック判定と失敗時のエラーメッセージ両方に使う。
        let diagnostics: String
    }

    private static func runOnce(
        binaryPath: String,
        arguments: [String],
        transcript: String,
        referenceFolder: String?,
        onEvent: @escaping @Sendable (CodeImpactStreamEvent) -> Void
    ) async throws -> AttemptOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.environment = AgentProcessEnvironment.make(binaryPath: binaryPath)
        process.arguments = arguments
        if let referenceFolder {
            process.currentDirectoryURL = URL(fileURLWithPath: referenceFolder)
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let resumeOnce: @Sendable (Result<AttemptOutcome, Error>) -> Void = { result in
                    let shouldResume = resumed.withLock { done in
                        let wasDone = done
                        done = true
                        return !wasDone
                    }
                    guard shouldResume else { return }
                    continuation.resume(with: result)
                }

                let rawStdout = AgentOutputBuffer()
                let rawStderr = AgentOutputBuffer()
                let lineSplitter = NDJSONLineSplitter()
                let state = StreamParseState()
                let throttler = TextDeltaThrottler(interval: textDeltaFlushInterval) { text in
                    onEvent(.textDelta(text))
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let chunk = fileHandle.availableData
                    guard !chunk.isEmpty else { return }
                    rawStdout.append(chunk)
                    for line in lineSplitter.append(chunk) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        handle(ndjsonLine: trimmed, state: state, throttler: throttler, onEvent: onEvent)
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    rawStderr.append(fileHandle.availableData)
                }

                // タイムアウト監視を DispatchWorkItem にしておき、プロセスが先に正常終了した場合は
                // terminationHandler の先頭で cancel する。cancel しないと、キュー上に積んだこの
                // クロージャ(process・resumeOnce 等を捕捉している)がタイムアウト時刻まで
                // 最大 300 秒残り続けてしまう。
                // DispatchWorkItem 自体は Sendable 適合が無いため、@Sendable な
                // terminationHandler から cancel() する箇所で警告が出る。cancel() は
                // Apple のドキュメント上どのスレッドから呼んでも安全なため、ここでは
                // nonisolated(unsafe) で明示的に安全性を引き受ける。
                nonisolated(unsafe) let timeoutWork = DispatchWorkItem {
                    guard process.isRunning else { return }
                    process.terminate()
                    resumeOnce(.failure(AgentSummarizeError.timedOut))
                }

                process.terminationHandler = { proc in
                    timeoutWork.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    throttler.flush()
                    let diagnostics = [
                        String(data: rawStderr.snapshot(), encoding: .utf8) ?? "",
                        String(data: rawStdout.snapshot(), encoding: .utf8) ?? "",
                    ]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                    let snapshot = state.snapshot()
                    resumeOnce(
                        .success(
                            AttemptOutcome(
                                exitCode: proc.terminationStatus,
                                resultText: snapshot.resultText,
                                resultSuccess: snapshot.resultSuccess,
                                sessionID: snapshot.sessionID,
                                diagnostics: diagnostics)))
                }

                do {
                    try process.run()
                } catch {
                    timeoutWork.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    resumeOnce(.failure(error))
                    return
                }

                if let data = transcript.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                try? stdinPipe.fileHandleForWriting.close()

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// NDJSON 1 行分のパースとイベント発火。JSONSerialization での最低限のパースに留める
    /// (claude の stream-json スキーマ全体を型で持つのは過剰なため)。
    private static func handle(
        ndjsonLine line: String,
        state: StreamParseState,
        throttler: TextDeltaThrottler,
        onEvent: @escaping @Sendable (CodeImpactStreamEvent) -> Void
    ) {
        guard let data = line.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case "system":
            guard json["subtype"] as? String == "init",
                let sessionID = json["session_id"] as? String, !sessionID.isEmpty
            else { return }
            state.setSessionID(sessionID)
            onEvent(.sessionID(sessionID))

        case "stream_event":
            guard let event = json["event"] as? [String: Any],
                event["type"] as? String == "content_block_delta",
                let delta = event["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String, !text.isEmpty
            else { return }
            throttler.add(text)

        case "assistant":
            guard let message = json["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { return }
            for item in content where item["type"] as? String == "tool_use" {
                guard let activityText = activityLine(for: item) else { continue }
                onEvent(.activity(activityText))
            }

        case "result":
            if json["subtype"] as? String == "success" {
                if let sessionID = json["session_id"] as? String, !sessionID.isEmpty {
                    state.setSessionID(sessionID)
                    onEvent(.sessionID(sessionID))
                }
                state.setResult(text: json["result"] as? String, success: true)
            } else {
                state.setResult(text: json["result"] as? String, success: false)
            }

        default:
            break
        }
    }

    /// tool_use 1 件から進捗表示用の 1 行を組み立てる。
    /// Read: 最終パス成分、Grep/Glob: パターンをそのまま添える。未知のツールは名前だけ。
    private static func activityLine(for toolUse: [String: Any]) -> String? {
        guard let name = toolUse["name"] as? String else { return nil }
        let input = toolUse["input"] as? [String: Any]
        switch name {
        case "Read":
            guard let path = input?["file_path"] as? String else { return name }
            return "Read: \((path as NSString).lastPathComponent)"
        case "Grep":
            guard let pattern = input?["pattern"] as? String else { return name }
            return "Grep: \(pattern)"
        case "Glob":
            guard let pattern = input?["pattern"] as? String else { return name }
            return "Glob: \(pattern)"
        default:
            return name
        }
    }
}

/// NDJSON の 1 行分の切り出し。readabilityHandler は任意のチャンク境界で呼ばれ、行の
/// 途中で途切れることがあるため、改行が来るまで内部バッファに溜める。
/// 呼び出しは同一 Pipe の readabilityHandler(単一の背景キュー)からのみだが、
/// 型としては複数キューから呼ばれても壊れないようロックで守っておく。
private final class NDJSONLineSplitter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Data())

    func append(_ chunk: Data) -> [String] {
        lock.withLock { buffer in
            buffer.append(chunk)
            var lines: [String] = []
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
            }
            return lines
        }
    }
}

/// NDJSON パース結果(セッション ID・最終 result)を貯める。readabilityHandler の
/// 背景キューから書き込み、terminationHandler から読み出すのでロックで守る。
private final class StreamParseState: @unchecked Sendable {
    private struct Snapshot {
        var sessionID: String?
        var resultText: String?
        var resultSuccess = false
    }
    private let lock = OSAllocatedUnfairLock(initialState: Snapshot())

    func setSessionID(_ id: String) {
        lock.withLock { $0.sessionID = id }
    }

    func setResult(text: String?, success: Bool) {
        lock.withLock {
            $0.resultText = text
            $0.resultSuccess = success
        }
    }

    func snapshot() -> (sessionID: String?, resultText: String?, resultSuccess: Bool) {
        lock.withLock { ($0.sessionID, $0.resultText, $0.resultSuccess) }
    }
}

/// textDelta のトークン単位の連投を間引く。最初の 1 件が来たら interval 秒後の
/// flush を 1 回だけ予約し、それまでに届いた分をまとめて 1 回の通知にする。
/// (デバウンスではなくスロットリング: 予約中に届いた分も同じ回で flush される)
private final class TextDeltaThrottler: @unchecked Sendable {
    private struct State {
        var buffer = ""
        var scheduled = false
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let interval: TimeInterval
    private let onFlush: @Sendable (String) -> Void

    init(interval: TimeInterval, onFlush: @escaping @Sendable (String) -> Void) {
        self.interval = interval
        self.onFlush = onFlush
    }

    func add(_ text: String) {
        let shouldSchedule = lock.withLock { state -> Bool in
            state.buffer += text
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.flush()
        }
    }

    /// 予約を待たずに即座に吐き出す。プロセス終了時の取りこぼし防止用。
    func flush() {
        let text = lock.withLock { state -> String in
            let text = state.buffer
            state.buffer = ""
            state.scheduled = false
            return text
        }
        guard !text.isEmpty else { return }
        onFlush(text)
    }
}
