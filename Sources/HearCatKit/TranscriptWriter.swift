import Foundation

/// 複数チャンネルの確定セグメントを1ファイルへ直列に追記する。
/// actor にすることで、自分/相手の2系統が同時に届いても行が壊れない(書き込み競合の防止)。
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
