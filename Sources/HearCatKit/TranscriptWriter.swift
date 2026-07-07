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
        return bodyLines(from: text).enumerated().map { index, line in
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

    /// コピー機能など、TranscriptLine への変換を経ずに整形済みの本文だけが必要な場面向け。
    public static func bodyText(from text: String) -> String {
        bodyLines(from: text).joined(separator: "\n")
    }

    /// 旧バージョンが書いていたヘッダー行(廃止済み)と、それに続く空行を取り除く。
    /// ヘッダーの無い新形式のファイルでは何も落とさない。
    private static func bodyLines(from text: String) -> [String] {
        Array(text.components(separatedBy: "\n")
            .drop(while: { $0.isEmpty || $0.hasPrefix("# 文字起こし") }))
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
    /// これまで書いたセグメント。順序が入れ替わって届いた時にファイルを
    /// 並べ直して書き戻すために持つ。
    private var segments: [TranscriptSegment] = []

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: fileURL)
    }

    public func append(_ segment: TranscriptSegment) {
        // タイムスタンプは発話開始時刻で、確定までの遅延はチャンネルごとに違うため、
        // 発話順と届く順が入れ替わることがある。ファイルは発話時刻順を保つ。
        // 通常(順序どおり)は追記だけで済ませ、入れ替わった時だけ全体を書き直す
        // (1セッション高々数百行なので書き直しは十分軽い)。
        if let last = segments.last, last.timestamp > segment.timestamp {
            let index = segments.lastIndex(where: { $0.timestamp <= segment.timestamp }).map { $0 + 1 } ?? 0
            segments.insert(segment, at: index)
            rewrite()
        } else {
            segments.append(segment)
            write(Self.line(for: segment) + "\n")
        }
    }

    private func rewrite() {
        let content = segments.map { Self.line(for: $0) + "\n" }.joined()
        try? handle.truncate(atOffset: 0)
        try? handle.seek(toOffset: 0)
        handle.write(Data(content.utf8))
        try? handle.synchronize()
    }

    public func close() {
        try? handle.close()
    }

    private func write(_ line: String) {
        handle.write(Data(line.utf8))
        // 追記のたびに flush して、録音中でも AI(Claude Code)が最新を読めるようにする。
        try? handle.synchronize()
    }

    /// ファイルに書く行の書式。ライブ画面のコピー機能が、まだファイルに書かれていない
    /// 確定分を同じ形式で複製するためにも参照する(書式の知識を1箇所にまとめる)。
    public static func line(for segment: TranscriptSegment) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "[\(f.string(from: segment.timestamp))] \(segment.speaker): \(segment.text)"
    }
}
