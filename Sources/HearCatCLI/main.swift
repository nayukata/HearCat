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
          ["record", "transcribe"].contains(arguments[0]) else {
        fail(usage)
    }
    let request = arguments[0] == "record"
        ? IPCRequest(command: .set, record: on)
        : IPCRequest(command: .set, transcribe: on)
    let response = requireResponse(request)
    print("切り替えました")
    if let status = response.status { printStatus(status) }

default:
    print(usage)
    exit(64)
}
