import Foundation

/// 要約を生成したエンジンの種別。表示にのみ使う識別子で、生成ロジック本体
/// (オンデバイスの TranscriptSummarizer、エージェント CLI の AgentSummarizer。
/// いずれも別モジュール/アプリ側)には依存しない。
///
/// 要約の生成時点でこの値を summary.engine (SessionStore.writeSummaryEngine 参照)へ
/// 永続化する。表示のたびに「今の設定」から推測すると、設定を後から変えた時に
/// 過去の要約の表示が実態と食い違うため、生成時点の値をそのまま固定する。
/// ファイルが無い(この機能より前に生成された過去の要約)場合は SessionInfo.summaryEngine が
/// nil を返すので、呼び出し側は推測でチップを埋めないこと。
public enum SummaryEngine: String, Sendable {
    case appleIntelligence
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}
