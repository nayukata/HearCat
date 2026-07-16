import Foundation
import Observation
import os

/// ヘッドレスの AI エージェント CLI(claude / codex)で高精度要約を作る。
/// オンデバイス(TranscriptSummarizer)と違い、文字起こしが外部サービスへ送信されるため、
/// 呼び出し側(SessionDetailView)で初回同意を取ってから使うこと。
enum AgentCLI: String, CaseIterable, Sendable, Hashable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// command -v で探すバイナリ名。
    fileprivate var binaryName: String { rawValue }

    /// command -v が失敗した場合に見に行く定番のインストール先。
    /// GUI アプリはログインシェルの解決すら失敗することがあるため、最後の砦として持つ。
    fileprivate var fallbackPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .claude:
            return [
                "\(home)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
        case .codex:
            return [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "\(home)/.npm-global/bin/codex",
                "\(home)/.local/bin/codex",
            ]
        }
    }
}

/// CLI バイナリの実体パス解決。GUI アプリは PATH が細い(ログインシェルの
/// .zshrc 等を経由しない)ため、まずログインシェルに `command -v` を引かせ、
/// それも失敗したら定番パスの実在確認へ落ちる。
enum AgentCLIResolver {
    static func resolve(_ cli: AgentCLI) async -> String? {
        if let found = await resolveViaLoginShell(cli.binaryName) {
            return found
        }
        return cli.fallbackPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func resolveViaLoginShell(_ binaryName: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v \(binaryName)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (output?.isEmpty == false) ? output : nil)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

/// 検出済みエージェント CLI の一覧。アプリ起動後にバックグラウンドで1回だけ検出し、
/// 以後は @Observable なキャッシュとして UI から読む(zsh -lc は数百 ms かかり得るため、
/// ボタンを出すたびに検出し直すと UI がもたつく)。
@MainActor
@Observable
final class AgentCLIDetector {
    static let shared = AgentCLIDetector()

    private(set) var availableCLIs: [AgentCLI] = []
    private var detected = false

    private init() {}

    func detectIfNeeded() {
        guard !detected else { return }
        detected = true
        Task {
            var found: [AgentCLI] = []
            for cli in AgentCLI.allCases where await AgentCLIResolver.resolve(cli) != nil {
                found.append(cli)
            }
            availableCLIs = found
        }
    }
}

enum AgentSummarizeError: LocalizedError {
    case notInstalled(AgentCLI)
    case notAuthenticated(AgentCLI)
    case noTranscript
    case timedOut
    case failed(exitCode: Int32, stderr: String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled(let cli):
            return "\(cli.displayName) CLI が見つかりません。導入してから再度お試しください"
        case .notAuthenticated(let cli):
            return "\(cli.displayName) にログインしていません。ターミナルでログインしてから再度お試しください"
        case .noTranscript:
            return "文字起こしがありません"
        case .timedOut:
            return "要約の生成がタイムアウトしました(5分)"
        case .failed(let exitCode, let stderr):
            let summary = stderr.isEmpty ? "" : ": \(stderr)"
            return "要約の生成に失敗しました(終了コード \(exitCode))\(summary)"
        case .emptyOutput:
            return "要約の生成に失敗しました(応答が空でした)"
        }
    }
}

/// エージェント CLI へ渡すプロンプトの組み立て。
private enum AgentSummarizePrompt {
    static func build(referenceFolder: String?) -> String {
        var parts = [
            "会議の文字起こし(標準入力で渡されます)を読み、議事録品質の要約を作ってください。",
            "音声認識による誤変換(固有名詞・技術用語など)は、文脈から正しい表記に直してください。",
        ]
        if referenceFolder != nil {
            parts.append(
                "カレントディレクトリは、この会議に関連する資料やコードの置き場所です。"
                    + "用語や固有名詞の確認に加えて、議論の文脈や前提を正しく理解するために読み取り参照してかまいません。"
                    + "ただし、要約に書いてよいのは文字起こしに出てきた内容だけです。"
                    + "資料にしか書かれていない情報を要約に足さないでください。ファイルの変更・作成はしないでください。")
        }
        parts.append(
            """
            出力は次の4セクションで構成される Markdown だけにしてください。前置きや後書きは書かないこと。
            ## 概要
            ## 話題ごとのまとめ
            (### で話題ごとに見出しを立てて分ける。雑談は末尾に回す)
            ## 決定事項
            (実際に合意されたものだけ。なければ「(なし)」)
            ## TODO・宿題
            (担当が分かれば「(担当: X)」を付ける)
            """)
        parts.append("文字起こしに書かれていないことを書かないでください(捏造禁止)。不確かな内容は書かないでください。")
        return parts.joined(separator: "\n\n")
    }
}

/// エージェント CLI での要約実行。claude / codex の差分(引数の組み立て・出力の取り出し方)を
/// このファイル内に閉じ込める。
enum AgentSummarizer {
    private static let timeout: TimeInterval = 300

    static func summarize(
        using cli: AgentCLI, transcript: String, referenceFolder: String?
    ) async throws -> String {
        guard let binaryPath = await AgentCLIResolver.resolve(cli) else {
            throw AgentSummarizeError.notInstalled(cli)
        }

        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("hearcat-agent-summary-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments(
            for: cli,
            prompt: AgentSummarizePrompt.build(referenceFolder: referenceFolder),
            referenceFolder: referenceFolder,
            outputFile: outputFile)
        if let referenceFolder {
            process.currentDirectoryURL = URL(fileURLWithPath: referenceFolder)
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let result = try await withTaskCancellationHandler {
            try await run(
                process: process, transcript: transcript,
                stdinPipe: stdinPipe, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        } onCancel: {
            process.terminate()
        }

        guard result.exitCode == 0 else {
            if isAuthError(result.stderr) {
                throw AgentSummarizeError.notAuthenticated(cli)
            }
            throw AgentSummarizeError.failed(exitCode: result.exitCode, stderr: summarize(stderr: result.stderr))
        }

        let rawOutput: String
        switch cli {
        case .claude:
            rawOutput = result.stdout
        case .codex:
            // codex はログが標準出力に混ざるため、最終メッセージだけを書かせた一時ファイルを読む。
            rawOutput = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
        }

        let formatted = extractMarkdown(rawOutput)
        guard !formatted.isEmpty else {
            throw AgentSummarizeError.emptyOutput
        }
        return formatted
    }

    private static func arguments(
        for cli: AgentCLI, prompt: String, referenceFolder: String?, outputFile: URL
    ) -> [String] {
        switch cli {
        case .claude:
            var args = ["-p", prompt, "--output-format", "text"]
            // referenceFolder が無ければ許可ツールのフラグ自体を渡さない
            // (ヘッドレスでは未許可のツールは自動拒否されるため、そのままで安全)。
            if referenceFolder != nil {
                args += ["--allowedTools", "Read", "Grep", "Glob"]
            }
            return args
        case .codex:
            // codex は git リポジトリ外での実行を既定で拒否する
            // ("Not inside a trusted directory and --skip-git-repo-check was not specified.")。
            // 関連フォルダは git 管理とは限らず(資料フォルダ等)、未設定時はアプリの
            // cwd になるため、いずれの場合も常に付ける。read-only サンドボックスは
            // 別途指定済みで書き込みは防いでいるため、安全性は変わらない。
            var args = ["exec", "--sandbox", "read-only", "--skip-git-repo-check"]
            if let referenceFolder {
                args += ["-C", referenceFolder]
            }
            args += ["-o", outputFile.path, prompt]
            return args
        }
    }

    private static func run(
        process: Process, transcript: String,
        stdinPipe: Pipe, stdoutPipe: Pipe, stderrPipe: Pipe
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let stdout = OutputBuffer()
            let stderr = OutputBuffer()

            let resumeOnce: @Sendable (Result<(exitCode: Int32, stdout: String, stderr: String), Error>) -> Void = { result in
                let shouldResume = resumed.withLock { done in
                    let wasDone = done
                    done = true
                    return !wasDone
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                stdout.append(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderr.append(handle.availableData)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                resumeOnce(.success((
                    exitCode: proc.terminationStatus,
                    stdout: String(data: stdout.snapshot(), encoding: .utf8) ?? "",
                    stderr: String(data: stderr.snapshot(), encoding: .utf8) ?? ""
                )))
            }

            do {
                try process.run()
            } catch {
                resumeOnce(.failure(error))
                return
            }

            if let data = transcript.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                resumeOnce(.failure(AgentSummarizeError.timedOut))
            }
        }
    }

    /// 標準出力・標準エラーの蓄積用バッファ。readabilityHandler は GCD の内部キューから
    /// 呼ばれるため、Sendable な形でロックしながら溜める。
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Data())
        func append(_ chunk: Data) { lock.withLock { $0.append(chunk) } }
        func snapshot() -> Data { lock.withLock { $0 } }
    }

    private static func isAuthError(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("login") || lowered.contains("authentication") || lowered.contains("unauthorized")
    }

    /// エラーメッセージに載せる stderr の要約(長大なログをそのまま出さない)。
    private static func summarize(stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
    }

    /// 本文は「## 概要」で始まる想定。前置きが混ざっていたら最初の「## 」以降だけを採用する。
    private static func extractMarkdown(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "## ") else { return trimmed }
        return String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
