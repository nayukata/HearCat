import Foundation
import os

/// codex CLI での「関連資料との照合」ストリーミング実行。claude 版(AgentCodeImpactStream)と
/// 公開 API・イベント型(CodeImpactStreamEvent)は共用するが、NDJSON のスキーマ・
/// セッション継続の引数・標準入力の扱いが claude と大きく異なるため、実行経路自体は
/// このファイルに分けて閉じ込める。
///
/// codex exec --json が出す NDJSON(実測: codex-cli 0.144.4)の要点:
/// - 本文は `item.completed` の `item.type == "agent_message"` でのみ届く
///   (claude の content_block_delta のような文字単位のデルタは無い。複数の
///   agent_message が段落として順に届き得るので、届いた順に連結する)。
/// - セッション ID は `thread.started` の `thread_id`(新規会話・resume のどちらでも
///   同じイベントが出る)。
/// - `item.type == "error"` は警告ノイズであることがある(実測: skill 記述の短縮通知)。
///   本文には混ぜない。
///
/// 実機での実測: codex は回答が実質 1 個の agent_message でまとめて届くため、受信した
/// テキストをそのまま即時に textDelta として流すと「一瞬で全部表示」になりストリーミング感が
/// 無い。TypewriterEmitter がこれをアプリ側で一定のペースに分け直して発火する
/// (タイプライター表示)。
enum AgentCodexImpactStream {
    private static let timeout: TimeInterval = 300

    /// ストリーミングでの実行 attempt の種類。resume → fresh の一方向にしか遷移せず、
    /// claude 版のような多段フォールバック(オプション単位の組み合わせ)は無いため、
    /// enum 1 つで足りる。
    private enum AttemptKind {
        /// 指定したセッション ID で継続する。
        case resume(String)
        /// 新規会話として実行する(resume が無かった、または resume が失敗した場合)。
        case fresh
    }

    /// codex はストリーミングが成立する経路として resume 1 回・fresh 1 回の最大 2 回までしか
    /// 試さない(resume 失敗 → fresh、fresh 失敗 → 非ストリーミングの一括実行、の一方向の遷移
    /// だけなので、claude 版の maxAttempts のような組み合わせ爆発は無い)。この定数自体は
    /// ループの上限として使うのではなく、attemptKinds の要素数がここを超えないことの
    /// ドキュメントとして置いている。
    private static let maxAttempts = 2

    /// - Parameters: AgentCodeImpactStream.run と同じ意味(claude 版のドキュメント参照)。
    ///   incrementalTranscript・resumeSessionID・decisionContext の扱いも同一。
    /// - Returns: 抽出済み Markdown と、今回判明したセッション ID(resume・fresh とも失敗して
    ///   非ストリーミングへ落ちた場合は nil)。
    static func run(
        model: String?,
        transcript: String,
        incrementalTranscript: String?,
        referenceFolder: String?,
        question: String?,
        previousResult: String?,
        decisionContext: String?,
        resumeSessionID: String?,
        transcriptCharacterLimit: Int = AgentCodeImpactAnalyzer.maximumTranscriptCharacters,
        isGroupTarget: Bool = false,
        onEvent: @escaping @Sendable (CodeImpactStreamEvent) -> Void
    ) async throws -> (result: String, sessionID: String?) {
        guard let binaryPath = await AgentCLIResolver.resolve(.codex) else {
            throw AgentSummarizeError.notInstalled(.codex)
        }

        // referenceFolder の存在確認は claude 版(AgentCodeImpactStream)と同じ理由・同じ扱い。
        let validatedReferenceFolder: String? = {
            guard let referenceFolder else { return nil }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: referenceFolder, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? referenceFolder : nil
        }()
        let hasReferenceFolder = validatedReferenceFolder != nil

        let fullTranscript = AgentCodeImpactAnalyzer.recentTranscript(
            from: transcript, limit: transcriptCharacterLimit)

        var attemptKinds: [AttemptKind] = []
        if let resumeSessionID {
            attemptKinds.append(.resume(resumeSessionID))
        }
        attemptKinds.append(.fresh)
        assert(attemptKinds.count <= maxAttempts)

        for (index, kind) in attemptKinds.enumerated() {
            try Task.checkCancellation()
            // 2 回目(resume 失敗後の fresh)は、直前の attempt で積んだ部分テキストを
            // 引き継がない(claude 版と同じ約束)。
            if index > 0 { onEvent(.reset) }

            let resumeSessionIDForAttempt: String?
            switch kind {
            case .resume(let id): resumeSessionIDForAttempt = id
            case .fresh: resumeSessionIDForAttempt = nil
            }
            let isResuming = resumeSessionIDForAttempt != nil

            // 標準入力とプロンプトの継続状態は、この attempt が resume かどうかから
            // 都度導出する(claude 版と同じ理屈: fallback で resume を落とした次の attempt では
            // 自動的に全量 + 非継続プロンプトへ切り替わる)。
            let stdinTranscript: String
            let continuity: AgentCodeImpactAnalyzer.TranscriptContinuity
            if isResuming {
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
                hasReferenceFolder: hasReferenceFolder, decisionContext: decisionContext,
                isGroupTarget: isGroupTarget)

            let arguments = arguments(
                prompt: prompt, model: model, resumeSessionID: resumeSessionIDForAttempt,
                hasReferenceFolder: hasReferenceFolder, referenceFolder: validatedReferenceFolder)

            // fresh は codex exec 自身が stdin を <stdin> ブロックとしてプロンプト末尾に
            // 自動添付する(buildPrompt の「標準入力で渡される」という文言はこの前提で書かれている)。
            // resume は PROMPT 引数を "-" にして、指示文と文字起こしをまとめて 1 本の
            // テキストとして標準入力に渡すため、resumeStdinPayload で埋め込み位置を明示する。
            let stdinPayload = isResuming
                ? resumeStdinPayload(prompt: prompt, transcript: stdinTranscript)
                : stdinTranscript

            let outcome = try await runOnce(
                binaryPath: binaryPath,
                arguments: arguments,
                stdinPayload: stdinPayload,
                // resume は -C を受け付けないため cwd(currentDirectoryURL)で指定する。
                // fresh は -C 引数(arguments 側)で指定しているが、既存の非ストリーミング経路
                // (AgentSummarizer.execute)も referenceFolder があれば常に cwd を設定しており、
                // 挙動を揃えるためここでも同じく設定する(-C と cwd が両方効いても実害は無い)。
                cwd: validatedReferenceFolder,
                onEvent: onEvent)

            if outcome.exitCode == 0, let resultText = outcome.resultText,
                !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // 質問応答は要約と違い、「## 」見出しから書き始めない応答もそのまま本文として
                // 表示したいため、claude 版と同じく緩い extractCodeImpactMarkdown を使う。
                guard let formatted = AgentSummarizer.extractCodeImpactMarkdown(resultText) else {
                    throw AgentSummarizeError.unexpectedOutput(
                        excerpt: AgentSummarizer.excerpt(from: resultText))
                }
                // resume の thread.started は同じ thread_id を返すはずだが、万一届かなかった
                // 場合に備えて、継続に使った ID へフォールバックする。
                return (formatted, outcome.sessionID ?? resumeSessionIDForAttempt)
            }

            // codex は診断を stderr に出す(claude と違い stdout 側に紛れ込むことは無いが、
            // 判定コードは共有できるので AgentSummarizer.isAuthError をそのまま使う)。
            if AgentSummarizer.isAuthError(outcome.diagnostics) {
                throw AgentSummarizeError.notAuthenticated(.codex)
            }

            // この attempt は失敗。resume だった場合は次の fresh attempt へ、fresh だった場合は
            // ループを抜けて非ストリーミングの一括実行へ落ちる(kind に応じた分岐は不要で、
            // ループが最後の要素なら自然にここで終わる)。
        }

        // resume・fresh とも失敗した(または最初から resume が無く fresh だけで失敗した)。
        // 既存の非ストリーミング経路(AgentCodeImpactAnalyzer.analyze)へ完全に落ちる。
        // セッションは継続できないため、次回は新規会話として扱う(呼び出し側が sessionID: nil を見る)。
        onEvent(.reset)
        onEvent(.activity("従来方式で調査中…"))
        let text = try await AgentSummarizer.execute(
            using: .codex,
            input: fullTranscript,
            referenceFolder: referenceFolder,
            prompt: AgentCodeImpactAnalyzer.buildPrompt(
                question: question, previousResult: previousResult, continuity: .fresh,
                hasReferenceFolder: hasReferenceFolder, decisionContext: decisionContext,
                isGroupTarget: isGroupTarget),
            outputPrefix: "code-impact-stream-fallback",
            model: model,
            extraction: AgentSummarizer.extractCodeImpactMarkdown)
        return (text, nil)
    }

    /// resume 時、標準入力に埋め込む添付位置の一文。buildPrompt 自体の文言
    /// (「標準入力で渡される...文字起こし」)は新規会話(codex が stdin を <stdin> ブロックとして
    /// 自動添付する場合)を前提に書かれているため変更しない。resume はその自動添付が働かない
    /// (実測: パイプ stdin をプロンプトへ添付しない)ので、この一文と区切りだけを追加で埋め込む。
    private static let resumeTranscriptAttachmentNote =
        "文字起こしは、この後に続く「----- 文字起こし -----」から「----- 文字起こしここまで -----」の間に埋め込まれています。"

    private static func resumeStdinPayload(prompt: String, transcript: String) -> String {
        """
        \(prompt)

        \(resumeTranscriptAttachmentNote)

        ----- 文字起こし -----
        \(transcript)
        ----- 文字起こしここまで -----
        """
    }

    private static func arguments(
        prompt: String,
        model: String?,
        resumeSessionID: String?,
        hasReferenceFolder: Bool,
        referenceFolder: String?
    ) -> [String] {
        if let resumeSessionID {
            // resume サブコマンドは -s/--sandbox と -C を受け付けない(実測)。サンドボックスは
            // -c サブキーで渡し、資料フォルダは呼び出し元で cwd(currentDirectoryURL)指定する。
            // PROMPT 引数は "-" にして、指示文と文字起こしをまとめた本文を標準入力から渡す
            // (resume はパイプ stdin を自動添付しないため、"-" でなければ何も読まれない)。
            var args = [
                "exec", "resume", resumeSessionID, "--json", "--skip-git-repo-check",
                "-c", "sandbox_mode=\"read-only\"",
            ]
            if let model {
                args += ["--model", model]
            }
            args.append("-")
            return args
        }

        var args = ["exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check"]
        if let model {
            args += ["--model", model]
        }
        if hasReferenceFolder, let referenceFolder {
            args += ["-C", referenceFolder]
        }
        args.append(prompt)
        return args
    }

    // MARK: - 1 回分の Process 実行

    private struct AttemptOutcome {
        let exitCode: Int32
        let resultText: String?
        let sessionID: String?
        /// stderr + stdout(生の NDJSON)。認証エラー判定と失敗時の診断表示の両方に使う。
        let diagnostics: String
    }

    private static func runOnce(
        binaryPath: String,
        arguments: [String],
        stdinPayload: String,
        cwd: String?,
        onEvent: @escaping @Sendable (CodeImpactStreamEvent) -> Void
    ) async throws -> AttemptOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.environment = AgentProcessEnvironment.make(binaryPath: binaryPath)
        process.arguments = arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // タイプライター表示のペース配分はこの attempt 専用(次の attempt へは持ち越さない)。
        // 生成は runOnce の外側(async な自分自身の scope)にしておき、continuation が
        // resume した後もここから drain 待ち・discard を呼べるようにする。
        let emitter = TypewriterEmitter(onEvent: onEvent)

        let outcome = try await withTaskCancellationHandler {
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
                let state = CodexStreamParseState()

                stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let chunk = fileHandle.availableData
                    guard !chunk.isEmpty else { return }
                    rawStdout.append(chunk)
                    for line in lineSplitter.append(chunk) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        handle(ndjsonLine: trimmed, state: state, emitter: emitter, onEvent: onEvent)
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    rawStderr.append(fileHandle.availableData)
                }

                // タイムアウト・cancel の扱いは AgentCodeImpactStream.runOnce と同じ理屈
                // (DispatchWorkItem を明示 cancel しないとクロージャがタイムアウト時刻まで残る、
                // 未起動プロセスへの terminate() はクラッシュする、の 2 点)。
                nonisolated(unsafe) let timeoutWork = DispatchWorkItem {
                    guard process.isRunning else { return }
                    process.terminate()
                    resumeOnce(.failure(AgentSummarizeError.timedOut(minutes: Int(timeout / 60), partialOutput: nil)))
                }

                process.terminationHandler = { proc in
                    timeoutWork.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    let diagnostics = [
                        String(data: rawStderr.snapshot(), encoding: .utf8) ?? "",
                        String(data: rawStdout.snapshot(), encoding: .utf8) ?? "",
                    ]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                    let snapshot = state.snapshot()
                    // ここではタイプライターの drain 待ちをしない(この時点ではまだ成功か失敗かの
                    // 判定に使う AttemptOutcome を作っただけ)。drain・discard の判断は continuation の
                    // 外側(この関数の下部)で行う。
                    resumeOnce(
                        .success(
                            AttemptOutcome(
                                exitCode: proc.terminationStatus,
                                resultText: snapshot.resultText,
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

                if let data = stdinPayload.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                try? stdinPipe.fileHandleForWriting.close()

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
            // ユーザーの中止はタイプ中でも直ちに反映したいので、discardPending() を
            // ここでも呼ぶ(下の checkCancellation より早く、プロセス終了を待たずに効く)。
            // discardPending() は同期のロック操作だけなので、この非同期でない
            // onCancel(任意スレッドから呼ばれる)から呼んでも安全。
            emitter.discardPending()
        }

        // withTaskCancellationHandler の外側に出た時点で既にキャンセル済みなら、
        // (プロセスは正常終了扱いで outcome が返ってきていても)これ以上タイプさせず、
        // drain 待ちにも進まない。
        guard !Task.isCancelled else {
            emitter.discardPending()
            throw CancellationError()
        }

        let trimmedResult = outcome.resultText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if outcome.exitCode == 0, !trimmedResult.isEmpty {
            // 成功した attempt だけ、タイプライター表示のキューが尽きるまで待つ。これにより
            // run() が戻る = 画面の表示が完結した時点になり、AppModel が確定ターンとして積む
            // 結果と、画面にタイプ済みのテキストが一致する(戻った直後に全文へ差し替わる
            // ちらつきが起きない)。ユーザーがこの待機中にキャンセルすると、waitUntilDrained()
            // 内の Task.sleep が CancellationError を投げてここで抜ける。
            try await emitter.waitUntilDrained()
        } else {
            // 失敗した attempt(次の attempt か非ストリーミングへフォールバックする)は、
            // 未消化の型書きを見せ続ける意味が無いので即座に捨てる。呼び出し元(run())が
            // この直後に出す .reset より前に、ここで確実に止めておく。
            emitter.discardPending()
        }
        return outcome
    }

    /// NDJSON 1 行分のパースとイベント発火。JSONSerialization での最低限のパースに留める
    /// (claude 版の handle(ndjsonLine:) と同じ方針)。
    private static func handle(
        ndjsonLine line: String,
        state: CodexStreamParseState,
        emitter: TypewriterEmitter,
        onEvent: @escaping @Sendable (CodeImpactStreamEvent) -> Void
    ) {
        guard let data = line.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case "thread.started":
            guard let threadID = json["thread_id"] as? String, !threadID.isEmpty else { return }
            state.setSessionID(threadID)
            onEvent(.sessionID(threadID))

        case "item.started":
            guard let item = json["item"] as? [String: Any],
                let activityText = activityLine(for: item)
            else { return }
            onEvent(.activity(activityText))

        case "item.completed":
            // agent_message だけを本文として拾う。error は警告ノイズのことがあるため混ぜない
            // (item.type をここで明示的に絞っているので、他の item 種別・error は自然に無視される)。
            guard let item = json["item"] as? [String: Any],
                item["type"] as? String == "agent_message",
                let text = item["text"] as? String, !text.isEmpty
            else { return }
            // 確定結果(state)には即時に積むが、画面への表示(onEvent)はここでは発火せず
            // emitter に積んでペース配分する(タイプライター表示)。
            state.appendParagraph(text)
            emitter.enqueue(text + "\n\n")

        default:
            break
        }
    }

    /// item.started 1 件から進捗表示用の 1 行を組み立てる。claude 版の activityLine
    /// (Read/Grep/Glob だけ特別扱いし、他はツール名だけ)と同じ粒度に合わせる。
    private static func activityLine(for item: [String: Any]) -> String? {
        guard let type = item["type"] as? String else { return nil }
        switch type {
        case "command_execution":
            guard let command = item["command"] as? String, !command.isEmpty else { return "コマンド実行" }
            let singleLine = command.replacingOccurrences(of: "\n", with: " ")
            return singleLine.count > 60 ? "実行: \(singleLine.prefix(60))…" : "実行: \(singleLine)"
        // agent_message は textDelta 側(item.completed)で扱うため進捗行としては出さない。
        // error も本文と同様、進捗行に混ぜない(ノイズのことがあるため)。
        case "agent_message", "error":
            return nil
        default:
            return type
        }
    }
}

/// codex の NDJSON パース結果(セッション ID・agent_message の連結)を貯める。
/// readabilityHandler の背景キューから書き込み、terminationHandler から読み出すのでロックで守る。
/// claude 版の StreamParseState と違い、result は「成功/失敗」の宣言が無いイベントスキーマ
/// なので、agent_message を段落として溜めて呼び出し側(run)で「空なら失敗」と判定する。
private final class CodexStreamParseState: @unchecked Sendable {
    private struct Snapshot {
        var sessionID: String?
        var paragraphs: [String] = []
    }
    private let lock = OSAllocatedUnfairLock(initialState: Snapshot())

    func setSessionID(_ id: String) {
        lock.withLock { $0.sessionID = id }
    }

    func appendParagraph(_ text: String) {
        lock.withLock { $0.paragraphs.append(text) }
    }

    func snapshot() -> (sessionID: String?, resultText: String?) {
        lock.withLock { snapshot in
            let joined = snapshot.paragraphs.joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (snapshot.sessionID, joined.isEmpty ? nil : joined)
        }
    }
}

/// codex の agent_message は文字単位のデルタが届かず 1 メッセージがまとめて届く(claude の
/// content_block_delta と違う)。届いたその場で丸ごと textDelta を発火すると「一瞬で全部表示」に
/// なりストリーミング感が無いため、受信済みテキストをこのエミッタで一定のペースに分けて
/// 発火し直す(タイプライター表示)。確定結果(CodexStreamParseState)には即時に積むので、
/// このエミッタが遅延・破棄しても最終的な戻り値の正しさには影響しない(あくまで表示の
/// ペース配分だけを担う)。
///
/// 1 本の直列ポンプ(Task.detached)がキューを消費し、tickInterval ごとに 1 塊を .textDelta
/// として発火する。呼び出し(enqueue)は NDJSON の読み取りキュー(単一の背景キュー)から
/// 同期的に行われるため、複数の agent_message が届いても積む順序 = 消費する順序になる。
private final class TypewriterEmitter: @unchecked Sendable {
    /// 1 塊を発火する間隔。
    private static let tickInterval: TimeInterval = 0.03
    /// 1 塊あたりの既定文字数。tickInterval と組み合わせると 24 / 0.03s ≒ 800 文字/秒になり、
    /// 要件の「30ms ごとに 20〜25 文字、体感 800 文字/秒前後」に収まる。
    private static let baseChunkSize = 24
    /// 1 メッセージ(agent_message 1 件)の表示にかけてよい時間の上限。baseChunkSize のまま
    /// 出すと長文ほど表示時間が伸びてしまう(タイプライター表示は「動いている感」を出すための
    /// 演出であり、長文を遅く読ませることが目的ではない)。この上限を超える長さのメッセージは、
    /// 上限に収まるよう塊サイズを比例して大きくする。
    private static let maxDurationPerMessage: TimeInterval = 6.0

    private struct State {
        /// 積まれたジョブ(agent_message 1 件 = 1 ジョブ)。ジョブ内はチャンク済みの配列。
        var jobs: [[Substring]] = []
        /// ポンプ(消費側の Task)が動いているか。enqueue が最初の 1 件で起動し、
        /// キューが尽きたら自分で false に戻す(常駐タイマーにしない)。
        var pumpRunning = false
        /// discardPending() 済みか。true の間は新規 enqueue を無視する
        /// (プロセス終了後に取りこぼしで遅れて届いた場合の保険。通常は起きない)。
        var stopped = false
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let onEvent: @Sendable (CodeImpactStreamEvent) -> Void

    init(onEvent: @escaping @Sendable (CodeImpactStreamEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// agent_message 1 件を受け取る。その場では発火せず、あらかじめ塊に分割してキューへ積む
    /// (呼び出し元の item.completed の到着順がそのまま表示順になる)。
    func enqueue(_ text: String) {
        let chunks = Self.split(text)
        guard !chunks.isEmpty else { return }
        let shouldStartPump = lock.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.jobs.append(chunks)
            guard !state.pumpRunning else { return false }
            state.pumpRunning = true
            return true
        }
        guard shouldStartPump else { return }
        startPump()
    }

    /// 1 メッセージの表示が maxDurationPerMessage に収まる最小の塊サイズ(baseChunkSize 以上)で
    /// 分割する。Character 単位(String の既定の走査)で切るため、日本語の合字や絵文字の
    /// grapheme クラスタを壊さない。
    private static func split(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        let maxTicks = max(1, Int((maxDurationPerMessage / tickInterval).rounded(.down)))
        let requiredChunkSize = Int((Double(text.count) / Double(maxTicks)).rounded(.up))
        let chunkSize = max(baseChunkSize, requiredChunkSize)

        var chunks: [Substring] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(text[index..<end])
            index = end
        }
        return chunks
    }

    /// キューの消費役。ジョブが尽きたら pumpRunning を false に戻して自然終了する
    /// (次の enqueue が来たら改めて 1 つ起動する)。
    private func startPump() {
        Task.detached { [self] in
            while true {
                let next: Substring? = self.lock.withLock { state -> Substring? in
                    while let firstJobIsEmpty = state.jobs.first?.isEmpty, firstJobIsEmpty {
                        state.jobs.removeFirst()
                    }
                    guard !state.jobs.isEmpty else {
                        state.pumpRunning = false
                        return nil
                    }
                    return state.jobs[0].removeFirst()
                }
                guard let next else { return }
                self.onEvent(.textDelta(String(next)))
                // discardPending() 済みならここで即終了する(次の tick を待たない)。
                if self.lock.withLock({ $0.stopped }) { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }
        }
    }

    /// 未消化のジョブを即座に捨ててポンプを止める。以後の enqueue も無視する
    /// (失敗した attempt・ユーザーによるキャンセル時に呼ぶ)。同期のロック操作だけなので、
    /// 任意のスレッド(onCancel 等)から呼んでも安全。
    func discardPending() {
        lock.withLock { state in
            state.jobs = []
            state.stopped = true
        }
    }

    /// キューが尽きるまで待つ(成功した attempt の直後にだけ呼ぶ)。tickInterval 間隔の
    /// ポーリングだが、値が 30ms とごく短いためビジーウェイトにはならない。呼び出し元の
    /// Task がキャンセルされると Task.sleep が CancellationError を投げてここで抜ける
    /// (型書きの途中でも直ちに止まる)。
    func waitUntilDrained() async throws {
        while true {
            let idle = lock.withLock { state in state.jobs.isEmpty && !state.pumpRunning || state.stopped }
            if idle { return }
            try await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
        }
    }
}
