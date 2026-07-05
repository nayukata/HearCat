import Foundation

/// 複数チャンネルの確定セグメントを1ファイルへ直列に追記する。
/// actor にすることで、自分/相手の2系統が同時に届いても行が壊れない(書き込み競合の防止)。
/// 文字起こしファイルの1行。行頭の時刻から録音内の再生位置を割り出すために使う。
public struct TranscriptLine: Identifiable, Sendable {
    /// 行番号(表示順の安定 ID)。
    public let id: Int
    /// 行頭の時刻表示(例 "12:34:56")。時刻の無い行(ヘッダや空行)は nil。
    public let stamp: String?
    /// 時刻を除いた本文(「話者: 発言」)。時刻の無い行は行全体。
    public let body: String
    /// セッション開始からの経過秒。時刻の無い行は nil。
    public let offset: TimeInterval?
}

/// TranscriptWriter が書く「[HH:mm:ss] 話者: 発言」形式を読み戻す側。
/// 形式の知識が書き手と読み手で食い違わないよう、同じファイルに置く。
public enum TranscriptParser {
    public static func lines(from text: String, sessionStart: Date) -> [TranscriptLine] {
        let comps = Calendar.current.dateComponents(
            [.hour, .minute, .second], from: sessionStart)
        let startSec = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
        return text.components(separatedBy: "\n").enumerated().map { index, line in
            guard let (stamp, body) = split(line) else {
                return TranscriptLine(id: index, stamp: nil, body: line, offset: nil)
            }
            let parts = stamp.split(separator: ":").compactMap { Int($0) }
            var offset = parts[0] * 3600 + parts[1] * 60 + parts[2] - startSec
            // 行の時刻は時分秒だけなので、日をまたいだセッションでは開始より小さく見える。
            if offset < 0 { offset += 24 * 3600 }
            return TranscriptLine(
                id: index, stamp: stamp, body: body, offset: TimeInterval(offset))
        }
    }

    /// 「[HH:mm:ss] 本文」を (時刻, 本文) に分ける。形式に合わない行は nil。
    private static func split(_ line: String) -> (stamp: String, body: String)? {
        guard line.hasPrefix("["), line.count >= 11 else { return nil }
        let stamp = String(line.dropFirst().prefix(8))
        let rest = line.dropFirst(10)
        let parts = stamp.split(separator: ":")
        guard parts.count == 3, parts.allSatisfy({ $0.count == 2 && Int($0) != nil }),
              line[line.index(line.startIndex, offsetBy: 9)] == "]"
        else { return nil }
        return (stamp, String(rest).trimmingCharacters(in: .whitespaces))
    }
}

public actor TranscriptWriter {
    private let fileURL: URL
    private let handle: FileHandle
    private let timeFormatter: DateFormatter

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: fileURL)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        self.timeFormatter = f
    }

    public func writeHeader(sessionStart: Date) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        write("# 文字起こし \(df.string(from: sessionStart))\n\n")
    }

    public func append(_ segment: TranscriptSegment) {
        write("[\(timeFormatter.string(from: segment.timestamp))] \(segment.speaker): \(segment.text)\n")
    }

    public func close() {
        try? handle.close()
    }

    private func write(_ line: String) {
        handle.write(Data(line.utf8))
        // 追記のたびに flush して、録音中でも AI(Claude Code)が最新を読めるようにする。
        try? handle.synchronize()
    }
}
