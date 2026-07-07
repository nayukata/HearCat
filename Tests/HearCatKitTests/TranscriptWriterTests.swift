import Foundation
import Testing

@testable import HearCatKit

struct TranscriptWriterTests {
    private func makeTempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcript.md")
    }

    @Test func 発話時刻順に届いた確定はそのまま追記される() async throws {
        let url = try makeTempURL()
        let writer = try TranscriptWriter(fileURL: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        await writer.append(TranscriptSegment(speaker: "自分", text: "先の発話", timestamp: base))
        await writer.append(TranscriptSegment(speaker: "相手", text: "後の発話", timestamp: base.addingTimeInterval(5)))
        await writer.close()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("先の発話"))
        #expect(lines[1].contains("後の発話"))
    }

    @Test func 順序が入れ替わって届いた確定も発話時刻順でファイルに残る() async throws {
        let url = try makeTempURL()
        let writer = try TranscriptWriter(fileURL: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 確定までの遅延がチャンネルごとに違うと、後の発話が先に届くことがある。
        await writer.append(TranscriptSegment(speaker: "相手", text: "後の発話", timestamp: base.addingTimeInterval(10)))
        await writer.append(TranscriptSegment(speaker: "自分", text: "先の発話", timestamp: base))
        await writer.append(TranscriptSegment(speaker: "相手", text: "さらに後の発話", timestamp: base.addingTimeInterval(20)))
        await writer.close()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains("先の発話"))
        #expect(lines[1].contains("後の発話"))
        #expect(lines[2].contains("さらに後の発話"))
    }
}
