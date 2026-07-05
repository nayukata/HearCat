import Foundation

/// 1セッション(=1会議)ぶんの成果物の置き場所。
/// ディレクトリ名がセッション ID で、中身は固定ファイル名の transcript.md / audio.m4a / summary.md。
public struct SessionInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let directory: URL
    public let startDate: Date

    public var transcriptURL: URL? { existing("transcript.md") }
    /// 録音(モノラル、自分と相手のミックス)。録音オフのセッションには無い。
    public var audioURL: URL? { existing("audio.m4a") }
    public var summaryURL: URL? { existing("summary.md") }

    private func existing(_ name: String) -> URL? {
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// セッションの保存先(Application Support)と IPC ソケットのパスを一元管理する。
/// アプリと CLI が同じパスを見ることが IPC 成立の前提なので、ここ以外にパスを書かない。
public enum SessionStore {
    public static let bundleIdentifier = "dev.nayukata.hearcat"

    /// セッションディレクトリ名 = セッション ID のフォーマット。
    private static let idFormat = "yyyy-MM-dd_HHmmss"

    public static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearCat", isDirectory: true)
    }

    /// 旧名(sharingan)時代の保存先からの引っ越し。アプリ起動時に1回呼ぶ。
    /// 新しい保存先がまだ無い場合にだけ、ディレクトリごと移動する。
    public static func migrateLegacyStorage() {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sharingan", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: rootDirectory.path) else {
            return
        }
        do {
            try fm.moveItem(at: legacy, to: rootDirectory)
            // 移動してきた旧ソケットファイルは無効なので消す(サーバー起動時に作り直される)。
            try? fm.removeItem(at: rootDirectory.appendingPathComponent("control.sock"))
        } catch {
            FileHandle.standardError.write(Data("旧保存先の引っ越しに失敗: \(error)\n".utf8))
        }
    }

    public static var sessionsDirectory: URL {
        rootDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Unix ドメインソケットのパス。sockaddr_un の 104 バイト制限に収まる長さであること。
    public static var socketPath: String {
        rootDirectory.appendingPathComponent("control.sock").path
    }

    private static func makeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = idFormat
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// 新しいセッションディレクトリを作って返す。
    public static func createSessionDirectory(startDate: Date) throws -> URL {
        let dir = sessionsDirectory.appendingPathComponent(
            makeFormatter().string(from: startDate), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 全セッションを新しい順で返す。
    public static func list() -> [SessionInfo] {
        let formatter = makeFormatter()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents
            .compactMap { url -> SessionInfo? in
                guard let date = formatter.date(from: url.lastPathComponent) else { return nil }
                return SessionInfo(id: url.lastPathComponent, directory: url, startDate: date)
            }
            .sorted { $0.startDate > $1.startDate }
    }

    /// 最新のセッション(録音中のものを含む)。
    public static func latest() -> SessionInfo? {
        list().first
    }

    public static func delete(_ session: SessionInfo) throws {
        try FileManager.default.removeItem(at: session.directory)
    }
}
