import Foundation

/// 起動時に、前回の異常終了(強制終了・クラッシュ)で変換されずに残った録音の生ファイル
/// (.aac, ADTS の AAC 生ストリーム。SessionRecorder が録音中に書く一時形式)を拾い、
/// 通常の停止(SessionRecorder.close())と同じ最終形式(.m4a)へ変換する。
///
/// なぜ必要か: SessionRecorder は録音中 .aac に書き、stop() の正常経路でだけ .m4a へ
/// 変換する(SessionRecorder の型 doc comment を参照)。アプリが強制終了すると .m4a への
/// 変換が走らないまま .aac だけが残り、SessionInfo.audioURL / audioOtherURL(.m4a しか
/// 探さない)から見えなくなる。次回起動時にここで拾って揃える。
public enum RecordingRecovery {
    /// 変換を試みた1件の結果。
    public struct Result: Sendable, Equatable {
        public let stagingURL: URL
        public let finalURL: URL
        public let succeeded: Bool
    }

    /// sessions ディレクトリ配下を走査し、対になる .m4a がまだ無い .aac をすべて .m4a へ
    /// 変換する。変換に失敗したファイルは削除せずそのまま残す(次回起動時にまた拾う。
    /// SessionRecorder.close() と同じ「データを消さないことを最優先」の方針)。
    @discardableResult
    public static func recoverAll(
        sessionsDirectory: URL = SessionStore.sessionsDirectory
    ) async -> [Result] {
        var results: [Result] = []
        for stagingURL in findOrphanedStagingFiles(in: sessionsDirectory) {
            let finalURL = stagingURL.deletingPathExtension().appendingPathExtension("m4a")
            let ok = await SessionRecorder.convertRecording(from: stagingURL, to: finalURL)
            if ok {
                try? FileManager.default.removeItem(at: stagingURL)
            } else {
                errorLog("残骸の録音を回収できません(\(stagingURL.lastPathComponent))")
            }
            results.append(Result(stagingURL: stagingURL, finalURL: finalURL, succeeded: ok))
        }
        return results
    }

    /// sessionsDirectory 配下を再帰的に走査し、対になる .m4a が無い .aac を集める。
    /// セッションディレクトリの深さ(sessions 直下 / プロジェクトフォルダ1階層)を
    /// 前提にせず再帰で探すことで、規約が変わっても取りこぼさないようにする。
    static func findOrphanedStagingFiles(in sessionsDirectory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "aac" else { continue }
            let finalURL = url.deletingPathExtension().appendingPathExtension("m4a")
            guard !fm.fileExists(atPath: finalURL.path) else { continue }
            found.append(url)
        }
        return found
    }
}
