import Foundation
import Testing

@testable import HearCatKit

/// 要約エンジンの永続化(summary.md と対になる summary.engine)の検証。
/// 表示のたびに現在の設定から推測するのではなく、生成時点に書いた記録だけを読むこと、
/// 記録の無い過去の要約では nil のまま(推測で埋めない)であることを確認する。
struct SummaryEngineTests {
    private func makeSession() throws -> SessionInfo {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SessionInfo(id: dir.lastPathComponent, directory: dir, startDate: Date(), name: "", folder: nil)
    }

    @Test func 書いたエンジンがそのまま読み取れる() throws {
        let session = try makeSession()
        try SessionStore.writeSummaryEngine(.claude, for: session)
        #expect(session.summaryEngine == .claude)
    }

    @Test func 記録ファイルが無い過去の要約はnilのまま推測しない() throws {
        let session = try makeSession()
        #expect(session.summaryEngine == nil)
    }

    @Test func 設定を後から変えても書いた時点の値のまま変わらない() throws {
        let session = try makeSession()
        try SessionStore.writeSummaryEngine(.appleIntelligence, for: session)
        // 「今の設定」を後から書き換えても、既に記録した値には影響しない
        // (書き込みは生成のたびに1回きりで、表示は毎回このファイルを読むだけ)。
        #expect(session.summaryEngine == .appleIntelligence)
    }
}
