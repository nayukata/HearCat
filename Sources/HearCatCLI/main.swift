import Foundation
import HearCatKit

// アプリ(常駐エンジン)へ命令を送るだけの薄い CLI。音声には触らない。
// agent skill(Claude Code)からの操作口として、出力はパース前提のシンプルな行にする。

let usage = """
使い方:
  hearcat start [--no-record] [--no-transcribe]  セッションを開始する(アプリ未起動なら起動する)
  hearcat stop                                   セッションを停止して保存する
  hearcat status                                 現在の状態を表示する
  hearcat latest                                 最新の文字起こしファイルのパスを表示する
  hearcat set record on|off                      録音だけを切り替える
  hearcat set transcribe on|off                  文字起こしだけを切り替える
  hearcat set autostart on|off                   ログイン時の自動起動を切り替える
  hearcat sessions [--folder <name>]             セッション一覧を TSV で出す
  hearcat read [<session>] [--summary|--cleaned] [--tail <N>]
                                                 原文/要約/清書を stdout に出す
  hearcat write-cleaned [<session>]              標準入力の清書を cleaned.md に書く(原文には触れない)
  hearcat write-summary [<session>]              標準入力の要約を summary.md に書く(原文には触れない)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func send(_ request: IPCRequest) -> IPCResponse? {
    try? IPCClient.send(request)
}

/// アプリを起動してソケットが開くまで待つ。導入済みでない場合は false を返す。
func launchAppAndWait() -> Bool {
    func open(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g"] + arguments
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    // bundle ID は LaunchServices 未登録(導入直後など)だと引けないため、既知のパスへフォールバックする。
    var launched = open(["-b", SessionStore.bundleIdentifier])
    if !launched {
        let candidates = [
            "\(NSHomeDirectory())/Applications/HearCat.app",
            "/Applications/HearCat.app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if open([path]) {
                launched = true
                break
            }
        }
    }
    guard launched else { return false }
    // 起動直後はソケットがまだ無い。開くまで最大15秒リトライする。
    for _ in 0..<50 {
        if send(IPCRequest(command: .status)) != nil { return true }
        Thread.sleep(forTimeInterval: 0.3)
    }
    return false
}

func printStatus(_ status: SessionEngine.Status) {
    if status.active {
        print("状態: セッション進行中")
        print("録音: \(status.recording ? "オン" : "オフ")")
        print("文字起こし: \(status.transcribing ? "オン" : "オフ")")
        if let path = status.transcriptPath { print("transcript: \(path)") }
        if let dir = status.sessionDirectory { print("session: \(dir)") }
        if let error = status.systemAudioError { print("注意: \(error)") }
    } else {
        print("状態: 待機中")
    }
}

func requireResponse(_ request: IPCRequest) -> IPCResponse {
    guard let response = send(request) else {
        fail("アプリ(HearCat.app)が起動していません。`hearcat start` で起動できます。")
    }
    guard response.ok else {
        fail("エラー: \(response.error ?? "不明")")
    }
    return response
}

/// セッション指定を SessionInfo に解決する。ID / ディレクトリ名 / フルパスの
/// いずれでも受ける。空 or nil なら最新セッションを返す。write-cleaned と
/// read で共用する。
func resolveSession(_ query: String?) -> SessionInfo? {
    guard let query, !query.isEmpty else { return SessionStore.latest() }
    return SessionStore.list().first {
        $0.id == query
            || $0.directory.lastPathComponent == query
            || $0.directory.path == query
    }
}

/// 引数から --tail <N> を取り出して残りを返す。値が数値でなければエラーで終了。
func extractTail(_ args: [String]) -> (tail: Int?, rest: [String]) {
    var rest = args
    var tail: Int?
    if let index = rest.firstIndex(of: "--tail") {
        guard index + 1 < rest.count, let n = Int(rest[index + 1]), n > 0 else {
            fail("--tail には 1 以上の整数を指定してください。")
        }
        tail = n
        rest.removeSubrange(index...(index + 1))
    }
    return (tail, rest)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(64)
}
arguments.removeFirst()

switch command {
case "start":
    let record = !arguments.contains("--no-record")
    let transcribe = !arguments.contains("--no-transcribe")
    if send(IPCRequest(command: .status)) == nil {
        guard launchAppAndWait() else {
            fail("HearCat.app を起動できません。install.sh で導入されているか確認してください。")
        }
    }
    let response = requireResponse(IPCRequest(command: .start, record: record, transcribe: transcribe))
    print("開始しました")
    if let status = response.status { printStatus(status) }

case "stop":
    let response = requireResponse(IPCRequest(command: .stop))
    print("停止しました")
    if let path = response.latestTranscript { print("transcript: \(path)") }

case "status":
    if let response = send(IPCRequest(command: .status)) {
        guard response.ok, let status = response.status else {
            fail("エラー: \(response.error ?? "不明")")
        }
        printStatus(status)
    } else {
        print("状態: アプリ未起動")
    }

case "latest":
    // 最新の transcript はファイルシステムから直接分かるため、アプリ未起動でも答えられる。
    if let response = send(IPCRequest(command: .latest)),
       response.ok, let path = response.latestTranscript {
        print(path)
    } else if let transcript = SessionStore.latest()?.transcriptURL {
        print(transcript.path)
    } else {
        fail("文字起こしファイルがまだありません")
    }

case "set":
    guard arguments.count == 2, let on = ["on": true, "off": false][arguments[1]],
          ["record", "transcribe", "autostart"].contains(arguments[0]) else {
        fail(usage)
    }
    // autostart の登録はアプリ内でしか行えないため、未起動なら起動して届ける。
    // record/transcribe はセッション中の操作なので、未起動ならそのままエラーでよい。
    if arguments[0] == "autostart", send(IPCRequest(command: .status)) == nil {
        guard launchAppAndWait() else {
            fail("HearCat.app を起動できません。install.sh で導入されているか確認してください。")
        }
    }
    let request = switch arguments[0] {
    case "record": IPCRequest(command: .set, record: on)
    case "transcribe": IPCRequest(command: .set, transcribe: on)
    default: IPCRequest(command: .set, autostart: on)
    }
    let response = requireResponse(request)
    print("切り替えました")
    if let status = response.status { printStatus(status) }

case "sessions":
    // セッション一覧。TSV(id\t開始日時 ISO8601\tセッション名\tフォルダ) で出す。
    // agent がパースしやすい列区切り + ヘッダ無し。フォルダで絞れる。
    var folder: String?
    if let index = arguments.firstIndex(of: "--folder") {
        guard index + 1 < arguments.count else {
            fail("--folder にフォルダ名を指定してください。")
        }
        folder = arguments[index + 1]
    }
    let formatter = ISO8601DateFormatter()
    for session in SessionStore.list() {
        if let folder, session.folder != folder { continue }
        let cols = [
            session.id, formatter.string(from: session.startDate),
            session.name, session.folder ?? "",
        ]
        print(cols.joined(separator: "\t"))
    }

case "read":
    // 原文/要約/清書のいずれかを stdout に出す。ファイルアクセスは CLI に集約し、
    // skill 側は built-in Read を使わない前提。
    var (tail, rest) = extractTail(arguments)
    var kind = "transcript"
    if let index = rest.firstIndex(of: "--summary") {
        kind = "summary"
        rest.remove(at: index)
    }
    if let index = rest.firstIndex(of: "--cleaned") {
        if kind != "transcript" {
            fail("--summary と --cleaned は同時に指定できません。")
        }
        kind = "cleaned"
        rest.remove(at: index)
    }
    let query = rest.first
    guard let session = resolveSession(query) else {
        fail("セッションが見つかりません: \(query ?? "(最新)")")
    }
    let url: URL? = {
        switch kind {
        case "summary": return session.summaryURL
        case "cleaned": return session.directory.appendingPathComponent("cleaned.md")
        default: return session.transcriptURL
        }
    }()
    guard let url, FileManager.default.fileExists(atPath: url.path) else {
        fail("\(kind) が存在しません: セッション \(session.id)")
    }
    let text: String
    do {
        text = try String(contentsOf: url, encoding: .utf8)
    } catch {
        fail("読み込みに失敗しました: \(error.localizedDescription)")
    }
    if let tail {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let sliced = lines.suffix(tail).joined(separator: "\n")
        print(sliced)
    } else {
        print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
    }

case "write-cleaned":
    // 標準入力で受けた清書テキストを、指定 or 最新セッションの cleaned.md へ書く。
    // 書き込み先はハードコードで、agent が指示を誤っても原文 <id>.md には届かない。
    let query = arguments.first
    guard let session = resolveSession(query) else {
        fail("セッションが見つかりません: \(query ?? "(最新)")")
    }
    // stdin を EOF まで読む(パイプでもリダイレクトでもここで完結する)。
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        fail("標準入力が空です。清書テキストをパイプで渡してください。")
    }
    let out = session.directory.appendingPathComponent("cleaned.md")
    // 万一 out が transcript や audio と同じパスに解決されたら止める(パス正規化の穴埋め)。
    let forbidden = [session.transcriptURL, session.audioURL].compactMap {
        $0?.standardizedFileURL.path
    }
    if forbidden.contains(out.standardizedFileURL.path) {
        fail("書き込み先が原文と衝突するため中止しました: \(out.path)")
    }
    do {
        try text.write(to: out, atomically: true, encoding: .utf8)
    } catch {
        fail("書き込みに失敗しました: \(error.localizedDescription)")
    }
    print(out.path)

case "write-summary":
    // 標準入力で受けた要約テキストを、指定 or 最新セッションの summary.md へ書く。
    // 書き込み先はハードコードで、agent が指示を誤っても原文 <id>.md には届かない。
    let query = arguments.first
    guard let session = resolveSession(query) else {
        fail("セッションが見つかりません: \(query ?? "(最新)")")
    }
    // stdin を EOF まで読む(パイプでもリダイレクトでもここで完結する)。
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        fail("標準入力が空です。要約テキストをパイプで渡してください。")
    }
    let out = session.directory.appendingPathComponent("summary.md")
    // 万一 out が transcript や audio と同じパスに解決されたら止める(パス正規化の穴埋め)。
    let forbidden = [session.transcriptURL, session.audioURL].compactMap {
        $0?.standardizedFileURL.path
    }
    if forbidden.contains(out.standardizedFileURL.path) {
        fail("書き込み先が原文と衝突するため中止しました: \(out.path)")
    }
    do {
        try text.write(to: out, atomically: true, encoding: .utf8)
    } catch {
        fail("書き込みに失敗しました: \(error.localizedDescription)")
    }
    print(out.path)

default:
    print(usage)
    exit(64)
}
