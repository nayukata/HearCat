import Foundation
import HearCatKit

/// 履歴一覧の行に添える1行プレビューの取り置き。
///
/// プレビューは要約(無ければ文字起こし)をディスクから読んで作るため、行を描くたびに
/// 読み直すわけにはいかない。@Observable にしないのは、辞書1つの書き換えで一覧の全行が
/// 描き直しの対象になってしまうため。各行は自分の @State に受け取る。
@MainActor
final class SessionPreviewCache {
    static let shared = SessionPreviewCache()

    /// プレビューをどこから作ったか。文字起こし由来のものは、あとから要約ができた時に
    /// 作り直す必要があるため区別する。
    private enum Source {
        case summary
        case transcript
        /// 読めるものが何も無かった。次に聞かれたらもう一度見にいく
        /// (停止直後は、最後の発話の書き込みが一覧の更新より遅れることがある)。
        case none
    }

    private struct Entry {
        let text: String?
        let source: Source
    }

    private var entries: [String: Entry] = [:]

    /// 1行プレビュー。まだ無ければディスクから読む。
    func preview(for session: SessionInfo) async -> String? {
        if let entry = entries[session.id] {
            let stale = entry.source == .none
                || (entry.source == .transcript && session.summaryURL != nil)
            if !stale { return entry.text }
        }
        let summaryURL = session.summaryURL
        let transcriptURL = session.transcriptURL
        let entry = await Task.detached(priority: .utility) {
            Self.load(summaryURL: summaryURL, transcriptURL: transcriptURL)
        }.value
        entries[session.id] = entry
        return entry.text
    }

    /// 一覧から消えたセッションの分を捨てる。削除だけでなく、名前変更やグループ移動でも
    /// ID(保存先のパス)が変わるため、古い ID の分がそのまま残り続ける。
    func retain(ids: Set<String>) {
        guard entries.count > ids.count else { return }
        entries = entries.filter { ids.contains($0.key) }
    }

    private nonisolated static func load(summaryURL: URL?, transcriptURL: URL?) -> Entry {
        if let summaryURL, let markdown = try? String(contentsOf: summaryURL, encoding: .utf8),
            let line = SummaryParser.previewLine(markdown) {
            return Entry(text: line, source: .summary)
        }
        if let transcriptURL, let text = try? String(contentsOf: transcriptURL, encoding: .utf8),
            let line = TranscriptParser.firstUtterance(from: text) {
            return Entry(text: line, source: .transcript)
        }
        return Entry(text: nil, source: .none)
    }
}
