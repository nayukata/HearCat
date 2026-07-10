import Foundation

/// アプリ(常駐エンジン)と CLI の間の通信メッセージ。
/// Unix ドメインソケット上で「1行 JSON のリクエスト → 1行 JSON のレスポンス」を1往復して閉じる。
public enum IPCCommand: String, Codable, Sendable {
    case start
    case stop
    case status
    case latest
    case set
}

public struct IPCRequest: Codable, Sendable {
    public var command: IPCCommand
    /// start: 録音の初期状態(省略時 true)。set: 録音の切り替え先。
    public var record: Bool?
    /// start: 文字起こしの初期状態(省略時 true)。set: 文字起こしの切り替え先。
    public var transcribe: Bool?
    /// set: ログイン時の自動起動(ログイン項目)の切り替え先。
    public var autostart: Bool?

    public init(
        command: IPCCommand, record: Bool? = nil, transcribe: Bool? = nil,
        autostart: Bool? = nil
    ) {
        self.command = command
        self.record = record
        self.transcribe = transcribe
        self.autostart = autostart
    }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: SessionEngine.Status?
    /// latest コマンドの答え。最新セッションの transcript のパス。
    public var latestTranscript: String?

    public init(
        ok: Bool, error: String? = nil,
        status: SessionEngine.Status? = nil, latestTranscript: String? = nil
    ) {
        self.ok = ok
        self.error = error
        self.status = status
        self.latestTranscript = latestTranscript
    }
}
