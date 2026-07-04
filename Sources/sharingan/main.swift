@preconcurrency import AVFoundation
import Foundation
import Speech

// 会話は日本語ベース。英語の技術用語が混ざる想定だが locale は ja-JP 固定にして精度を優先する。
let locale = Locale(identifier: "ja-JP")

func stderrPrint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// SFSpeechRecognizer.requestAuthorization の完了ハンドラは TCC が背景スレッドで呼ぶ。
// main.swift のトップレベルは main actor 分離なので、そこで継続を直接受けると
// 「背景スレッドなのに main actor を要求」してランタイムが trap する。
// nonisolated なグローバル関数に切り出して、分離要求を外す。
func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
        }
    }
}

// 出力先: 第1引数でファイルパスを渡せる(背景実行のラッパーが録音先を決め打ちできるように)。
// 省略時は <カレントディレクトリ>/transcripts/<日時>.md を「1セッション=1ファイル」にする。
let fileManager = FileManager.default
let sessionStart = Date()
let fileURL: URL
if CommandLine.arguments.count > 1 {
    fileURL = URL(fileURLWithPath: CommandLine.arguments[1])
    try? fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
} else {
    let outDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        .appendingPathComponent("transcripts", isDirectory: true)
    try? fileManager.createDirectory(at: outDir, withIntermediateDirectories: true)
    let nameFormatter = DateFormatter()
    nameFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
    nameFormatter.locale = Locale(identifier: "en_US_POSIX")
    fileURL = outDir.appendingPathComponent("\(nameFormatter.string(from: sessionStart)).md")
}

// --- 認可(音声認識とマイク) ---
let speechAuth = await requestSpeechAuthorization()
if speechAuth != .authorized {
    stderrPrint("音声認識が許可されていません (status: \(speechAuth.rawValue))。システム設定 > プライバシーとセキュリティ > 音声認識 を確認してください。")
}
let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
if !micGranted {
    stderrPrint("マイクが許可されていません。システム設定 > プライバシーとセキュリティ > マイク を確認してください。")
}

// --- 出力(writer)と、両チャンネルが確定文を集約する単一ストリーム ---
let writer = try TranscriptWriter(fileURL: fileURL)
await writer.writeHeader(sessionStart: sessionStart)

let (segmentStream, segmentSink) = AsyncStream<TranscriptSegment>.makeStream()
let consoleFormatter = DateFormatter()
consoleFormatter.dateFormat = "HH:mm:ss"
consoleFormatter.locale = Locale(identifier: "en_US_POSIX")

// 1本の消費タスクで直列に書くことで、自分/相手が同時でも順序と行が保たれる。
let writeTask = Task {
    for await segment in segmentStream {
        await writer.append(segment)
        print("[\(consoleFormatter.string(from: segment.timestamp))] \(segment.speaker): \(segment.text)")
    }
}

// --- 自分(マイク) ---
let mine = ChannelTranscriber(speaker: "自分", locale: locale, sink: segmentSink)
try await mine.start()
let mic = MicSource()
try mic.start()
let micPump = Task { for await item in mic.buffers { mine.feed(item.buffer) } }
stderrPrint("● 録音開始: 自分のマイクを文字起こし中…")

// --- 相手(システム音声) ---
// 署名なしビルドなどで失敗しても、自分のマイクだけで継続できるようにする。
let theirs = ChannelTranscriber(speaker: "相手", locale: locale, sink: segmentSink)
var systemSource: SystemAudioSource?
var theirsPump: Task<Void, Never>?
do {
    try await theirs.start()
    let system = SystemAudioSource()
    try system.start()
    systemSource = system
    theirsPump = Task { for await item in system.buffers { theirs.feed(item.buffer) } }
    stderrPrint("● 相手(システム音声)も文字起こし中…")
} catch {
    stderrPrint("システム音声の取得を開始できませんでした: \(error)")
    stderrPrint("（署名なしビルドだと無音で失敗します。自分のマイクのみで継続します）")
}

stderrPrint("停止するには Ctrl-C。保存先: \(fileURL.path)")

// --- 停止シグナルで末尾を確定してから終了する ---
// SIGINT は前景の Ctrl-C 用。SIGTERM は背景実行(ラッパー経由)からの停止用。
// 背景プロセスはシェルの仕様で SIGINT が無視されるため、TERM も必ず受ける。
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    Task {
        mic.stop()
        systemSource?.stop()
        micPump.cancel()
        theirsPump?.cancel()
        await mine.stop()
        await theirs.stop()
        segmentSink.finish()
        _ = await writeTask.value
        await writer.close()
        stderrPrint("\n保存しました: \(fileURL.path)")
        exit(0)
    }
}
sigintSource.resume()

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    Task {
        mic.stop()
        systemSource?.stop()
        micPump.cancel()
        theirsPump?.cancel()
        await mine.stop()
        await theirs.stop()
        segmentSink.finish()
        _ = await writeTask.value
        await writer.close()
        stderrPrint("\n保存しました: \(fileURL.path)")
        exit(0)
    }
}
sigtermSource.resume()

// 停止シグナルが来るまで、非同期 main タスクを終了させずに生かし続ける。
// top-level await と dispatchMain() は併用不可(main executor が競合して trap する)ため、
// dispatchMain ではなく無限 sleep でタスクを保持する。停止は上のシグナルハンドラが exit する。
while true {
    try? await Task.sleep(for: .seconds(3600))
}
