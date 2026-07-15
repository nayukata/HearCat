import Foundation
import HearCatSummarize

/// オンデバイス要約(TranscriptSummarizer)の品質検証用 CLI。
/// アプリを起動せず、文字起こしのテキストファイルを渡すだけで要約パイプラインを繰り返し試せる。
/// 開発検証専用で .app には同梱しない。

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func logToStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("使い方: summarize-lab <文字起こしファイルのパス>")
}

let path = arguments[1]
let transcript: String
do {
    transcript = try String(contentsOfFile: path, encoding: .utf8)
} catch {
    fail("ファイルを読み込めませんでした: \(path)\n\(error.localizedDescription)")
}

let startedAt = Date()
do {
    let markdown = try await TranscriptSummarizer.summarize(transcript: transcript, log: logToStderr)
    let elapsed = Date().timeIntervalSince(startedAt)
    logToStderr("所要時間: \(String(format: "%.1f", elapsed))秒")
    print(markdown)
} catch {
    let elapsed = Date().timeIntervalSince(startedAt)
    logToStderr("所要時間: \(String(format: "%.1f", elapsed))秒")
    fail("要約に失敗しました: \(error.localizedDescription)")
}
