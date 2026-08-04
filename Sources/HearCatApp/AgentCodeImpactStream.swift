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
    /// フォールバックの判定材料(includePartialMessages / includeSettingSources /
    /// includeTools / resumeSessionID)が 4 種類あるため、単純な直列の組み合わせでも
    /// 3 では足りないケースがあり得る分だけ余裕を持たせている。
    private static let maxAttempts = 4
    /// textDelta をまとめて通知する間隔。トークン単位で大量に届くため、そのまま
    /// 都度 UI へ流すと更新が過密になる。
    private static let textDeltaFlushInterval: TimeInterval = 0.12

    /// 1 回の実行で有効にする引数の組み合わせ。段階的フォールバックのたびに
    /// このどれかを falseにして(または resumeSessionID を落として)再実行する。
    private struct AttemptConfig {
        var includePartialMessages: Bool
        var includeSettingSources: Bool
        /// --tools を付けるか。古い claude CLI が --tools 自体を知らない場合に限り false へ落とす
        /// (unknown option フォールバック)。false の間はツール制限が効かなくなるため、
        /// この経路に落ちたことが分かるよう arguments() 側でコメントしている。
        var includeTools: Bool
        var resumeSessionID: String?
    }

    private enum FallbackDecision {
        /// 引数を変えてストリーミングのまま再実行する。
        case retry(AttemptConfig)
        /// ストリーミング自体を諦め、既存の非ストリーミング経路(AgentSummarizer.execute)へ落ちる。
        case fallbackToText
    }

    /// - Parameters:
    ///   - transcript: 未加工の文字起こし全体。継続しない(または差分を渡せない)場合は
    ///     AgentCodeImpactAnalyzer.recentTranscript で直近部分に切ってから標準入力へ渡す
    ///     (analyze() と同じ扱い)。
    ///   - incrementalTranscript: 呼び出し側(AppModel)が resumeSessionID との継続を前提に
    ///     あらかじめ計算した差分(前回送信済み位置以降)。nil なら「差分は使わず transcript の
    ///     全量を渡す」の合図(新規会話・送信済み位置が不明・異常時など)。空文字列は
    ///     「差分計算はできたが前回以降に新しい発話が無かった」を表し、そのまま空で送る。
    ///     resumeSessionID が nil の場合(新規会話)は無視する。
    ///   - question / previousResult: プロンプト組み立て用。継続の有無・差分の有無に応じた
    ///     resumeNote の出し分けは、この関数の中で AgentCodeImpactAnalyzer.buildPrompt に
    ///     都度渡す(呼び出し側で 1 度だけ組んで固定しない)。段階的フォールバックで
    ///     resumeSessionID を落として再実行する際に、標準入力とプロンプトの継続状態を
    ///     必ず一致させるため(差分文字列を新規会話に渡す事故を防ぐ)。
    ///   - resumeSessionID: 継続したい claude セッション ID。nil なら新規会話。
    ///   - onEvent: ストリーム中の通知。@Sendable(バックグラウンドの読み取りキューから呼ぶ)。
    /// - Returns: 抽出済み Markdown と、今回判明したセッション ID(セッションが尽きて
    ///   非ストリーミングへ落ちた場合は nil)。
    static func run(
        model: String?,
        transcript: String,
        incrementalTranscript: String?,
        referenceFolder: String?,
        question: String?,
        previousResult: String?,
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
        // 二重に見る)。プロンプト内の hasReferenceFolder もこの検証後の値に揃え、
        // 「資料を読める」と言いながら --allowedTools を渡していない、という食い違いを防ぐ。
        let validatedReferenceFolder: String? = {
            guard let referenceFolder else { return nil }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: referenceFolder, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? referenceFolder : nil
        }()
        let hasReferenceFolder = validatedReferenceFolder != nil

        let fullTranscript = AgentCodeImpactAnalyzer.recentTranscript(from: transcript)

        var config = AttemptConfig(
            includePartialMessages: true,
            includeSettingSources: true,
            includeTools: true,
            resumeSessionID: resumeSessionID)
        var attempts = 0
        var lastDiagnostics = ""
        var lastExitCode: Int32 = -1

        while attempts < maxAttempts {
            // キャンセル済みなら新しい attempt(プロセス起動)を始めない。起動直前の
            // キャンセルは onCancel 側の isRunning ガードが受け持ち、ここは再試行の隙間で
            // 届いたキャンセルを拾う。
            try Task.checkCancellation()
            attempts += 1
            if attempts > 1 { onEvent(.reset) }

            // 標準入力とプロンプトの継続状態は、この attempt の config.resumeSessionID から
            // 都度導出する。fallback で resumeSessionID を落とした次の attempt では
            // isResumingAttempt が false になり、自動的に全量 + 非継続プロンプトへ切り替わる。
            let isResumingAttempt = config.resumeSessionID != nil
            let stdinTranscript: String
            let continuity: AgentCodeImpactAnalyzer.TranscriptContinuity
            if isResumingAttempt {
                if let incrementalTranscript {
                    stdinTranscript = incrementalTranscript
                    let isEmpty = incrementalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    continuity = isEmpty ? .resumedNoDelta : .resumedWithDelta
                } else {
                    stdinTranscript = fullTranscript
                    continuity = .resumedFullResend
                }
            } else {
                stdinTranscript = fullTranscript
                continuity = .fresh
            }
            let prompt = AgentCodeImpactAnalyzer.buildPrompt(
                question: question, previousResult: previousResult, continuity: continuity,
                hasReferenceFolder: hasReferenceFolder)

            let arguments = arguments(
                prompt: prompt, model: model, config: config,
                hasReferenceFolder: hasReferenceFolder)

            let outcome = try await runOnce(
                binaryPath: binaryPath,
                arguments: arguments,
                transcript: stdinTranscript,
                referenceFolder: validatedReferenceFolder,
                onEvent: onEvent)

            if outcome.exitCode == 0 {
                guard outcome.resultSuccess, let resultText = outcome.resultText,
                    !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw AgentSummarizeError.unexpectedOutput(
                        excerpt: AgentSummarizer.excerpt(from: outcome.diagnostics))
                }
                // 質問応答は要約と違い、「## 」見出しから書き始めない応答(本文から書き始めて
                // 途中に「## 根拠と補足」だけが続く等)もそのまま本文として表示したいため、
                // 厳格な extractMarkdown ではなく緩い extractCodeImpactMarkdown を使う。
                guard let formatted = AgentSummarizer.extractCodeImpactMarkdown(resultText) else {
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
                // 非ストリーミング(AgentSummarizer.execute)は --resume を持たないため、
                // 継続は完全に切れる。標準入力は全量、プロンプトも非継続用に組み直す
                // (直前の attempt が差分プロンプトを使っていた場合でも、ここで必ず上書きする)。
                let text = try await AgentSummarizer.execute(
                    using: .claude,
                    input: fullTranscript,
                    referenceFolder: referenceFolder,
                    prompt: AgentCodeImpactAnalyzer.buildPrompt(
                        question: question, previousResult: previousResult, continuity: .fresh,
                        hasReferenceFolder: hasReferenceFolder),
                    outputPrefix: "code-impact-stream-fallback",
                    model: model,
                    extraction: AgentSummarizer.extractCodeImpactMarkdown)
                return (text, nil)
            }
        }

        throw AgentSummarizeError.failed(
            exitCode: lastExitCode, stderr: AgentSummarizer.summarize(stderr: lastDiagnostics))
    }

    /// 診断出力(stderr + stdout)から、次に何を変えて再実行すべきかを決める。
    /// 上から順に判定し、最初に当てはまったものを採用する(設計メモの 1〜5 と対応)。
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

        // 4. --tools を知らない古い claude。この経路に落ちるとツール制限そのものが効かなくなるが、
        //    --allowedTools(資料フォルダありの場合のみ)は残っているので、無条件に何でも
        //    使えるわけではない(権限プロンプトの追加は防げても、禁止はできない旧来の状態に戻るだけ)。
        if config.includeTools, lower.contains("unknown option"), lower.contains("--tools") {
            var next = config
            next.includeTools = false
            return .retry(next)
        }

        // 5. --resume 付きの実行が失敗(セッション期限切れ等)。原因の切り分けはせず、
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
        // --allowedTools は許可ルールの「追加」であり、他のツールを禁止しない。
        // --setting-sources で読み込むプロジェクト設定(資料フォルダ側の .claude/settings.json 等)に
        // Bash 等の許可があれば、それだけで通ってしまう。利用可能なツールそのものを固定するのは
        // --tools の役目なので、読み取り専用ツールだけに絞る(資料フォルダが無ければ Read すら
        // 与えず、文字起こしだけで答えさせる設計に合わせて全ツールを無効化する)。
        if config.includeTools {
            args += ["--tools", hasReferenceFolder ? "Read,Grep,Glob" : ""]
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
            // キャンセルはプロセス起動前(Task が既にキャンセル済みだと、このハンドラは
            // 登録と同時に即実行される)や終了後にも届く。未起動の Process への terminate() は
            // NSInvalidArgumentException でアプリごと落ちるため(送信直後の即キャンセルで
            // 実クラッシュあり)、起動して動いている間だけシグナルを送る。
            guard process.isRunning else { return }
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
