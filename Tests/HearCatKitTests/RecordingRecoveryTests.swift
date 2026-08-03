import AVFoundation
import Foundation
import Testing

@testable import HearCatKit

/// 起動時の残骸回収の検証。SessionStore.rootDirectory には触れず、専用の一時ディレクトリを
/// sessionsDirectory 引数で渡す(他のテストと保存先の取り合いにならないように)。
struct RecordingRecoveryTests {
    private let sampleRate = SessionRecorder.sampleRate
    private let blockFrames = 4800

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let ptr = buffer.floatChannelData![0]
        for i in 0..<samples.count { ptr[i] = samples[i] }
        return buffer
    }

    private func sineSamples(count: Int, amplitude: Float, frequency: Double) -> [Float] {
        (0..<count).map { i in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    private func tempSessionsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 強制終了で残った生ファイル(.aac)を、通常の停止と同じ最終形式(.m4a)へ変換して消す。
    @Test func 書きかけの生ファイルをm4aへ変換して消す() async throws {
        let sessionsDir = try tempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }

        let sessionDir = sessionsDir.appendingPathComponent("2026-01-01_000000", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let url = sessionDir.appendingPathComponent("2026-01-01_000000.m4a")

        // close() を呼ばずに SessionRecorder で実際に書き、「強制終了で残った生ファイル」を再現する。
        let recorder = SessionRecorder(url: url, includesSystemChannel: false)
        let tone = sineSamples(count: blockFrames, amplitude: 0.05, frequency: 220)
        for _ in 0..<10 { await recorder.appendMic(makeBuffer(tone)) }

        let stagingURL = SessionRecorder.stagingURL(for: url)
        #expect(FileManager.default.fileExists(atPath: stagingURL.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let results = await RecordingRecovery.recoverAll(sessionsDirectory: sessionsDir)

        #expect(results.count == 1)
        #expect(results.first?.succeeded == true)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    /// 対になる .m4a が既にある .aac は、正常に変換が終わっている(削除だけ失敗した等)
    /// 可能性があるため、上書きせず回収対象から外す。
    @Test func 対になるm4aが既にあれば回収対象にしない() async throws {
        let sessionsDir = try tempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }

        let sessionDir = sessionsDir.appendingPathComponent("2026-01-01_000000", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let url = sessionDir.appendingPathComponent("2026-01-01_000000.m4a")
        let stagingURL = SessionRecorder.stagingURL(for: url)
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        FileManager.default.createFile(atPath: stagingURL.path, contents: Data([0]))

        let results = await RecordingRecovery.recoverAll(sessionsDirectory: sessionsDir)

        #expect(results.isEmpty)
        #expect(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    /// sessions 直下だけでなく、プロジェクトフォルダ配下(1階層下)の .aac も拾う。
    @Test func プロジェクトフォルダ配下の生ファイルも拾う() async throws {
        let sessionsDir = try tempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }

        let sessionDir = sessionsDir
            .appendingPathComponent("お客様A", isDirectory: true)
            .appendingPathComponent("2026-01-01_000000", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let url = sessionDir.appendingPathComponent("2026-01-01_000000.m4a")

        let recorder = SessionRecorder(url: url, includesSystemChannel: false)
        let tone = sineSamples(count: blockFrames, amplitude: 0.05, frequency: 220)
        for _ in 0..<10 { await recorder.appendMic(makeBuffer(tone)) }

        let results = await RecordingRecovery.recoverAll(sessionsDirectory: sessionsDir)

        #expect(results.count == 1)
        #expect(results.first?.succeeded == true)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
