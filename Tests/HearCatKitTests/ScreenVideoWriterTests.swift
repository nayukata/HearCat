@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit
import Testing

@testable import HearCatKit

/// 画面録画の書き出し(ScreenVideoWriter)の検証。実機の画面収録には触れず、合成した
/// フレームと差し替えた時計(秒単位で進める)で、時間軸・音声・強制終了後の再生を見る。

/// 差し替え用の時計。テストが進めた分だけ進む。
final class FakeHostClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double

    init(start: Double = 1000) { seconds = start }

    var time: CMTime { lock.withLock { CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) } }
    func advance(to value: Double) { lock.withLock { seconds = value } }
    var now: @Sendable () -> CMTime { { [self] in time } }
}

/// 単色の BGRA フレーム。色をフレームごとに変えて、エンコーダに同一画像として扱われないようにする。
func makeTestPixelBuffer(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(shade), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

func makeTestFrame(
    at seconds: Double, width: Int = 320, height: Int = 180, shade: UInt8 = 128
) -> ScreenFrame {
    ScreenFrame(
        pixelBuffer: makeTestPixelBuffer(width: width, height: height, shade: shade),
        presentationTime: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
}

func makeTestVideoURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
}

struct VideoFacts {
    let isPlayable: Bool
    let duration: Double
    let videoTrackCount: Int
    let audioTrackCount: Int
    let size: CGSize
    let audioDuration: Double
}

func inspectVideo(_ url: URL) async throws -> VideoFacts {
    let asset = AVURLAsset(url: url)
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    let size = try await video.first?.load(.naturalSize) ?? .zero
    let audioRange = try await audio.first?.load(.timeRange)
    return VideoFacts(
        isPlayable: try await asset.load(.isPlayable),
        duration: try await asset.load(.duration).seconds,
        videoTrackCount: video.count, audioTrackCount: audio.count, size: size,
        audioDuration: audioRange?.duration.seconds ?? 0)
}

/// 音声トラックを PCM に復号して、区間ごとの RMS を返す。
func audioRMS(of url: URL, intervals: [ClosedRange<Double>]) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
    reader.add(output)
    reader.startReading()
    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        samples.append(contentsOf: data)
    }
    return intervals.map { interval in
        let start = max(0, Int(interval.lowerBound * 48_000))
        let end = min(samples.count, Int(interval.upperBound * 48_000))
        guard end > start else { return 0 }
        return rmsLevel(Array(samples[start..<end]))
    }
}

struct ScreenVideoWriterTests {
    /// seconds 秒ぶんを fps で、from から流す(時計も進める)。
    private func feed(
        _ writer: ScreenVideoWriter, clock: FakeHostClock, from: Double, seconds: Double,
        fps: Double = 10, width: Int = 320, height: Int = 180
    ) {
        let count = Int(seconds * fps)
        for i in 0..<count {
            let t = from + Double(i) / fps
            clock.advance(to: t)
            writer.append(makeTestFrame(at: t, width: width, height: height, shade: UInt8(i % 200)))
        }
    }

    @Test func フレームが一度も来なければファイルを作らない() async {
        let url = makeTestVideoURL()
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: true, now: clock.now)

        writer.pauseVideo()
        writer.appendAudio([Float](repeating: 0.1, count: 4800))
        writer.setAudioActive(false)
        clock.advance(to: 1005)
        let ok = await writer.close()

        #expect(ok)
        #expect(!writer.hasOpenedFile)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func オフの区間を詰めて1本にまとめる() async throws {
        let url = makeTestVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: false, now: clock.now)

        feed(writer, clock: clock, from: 1000, seconds: 1)
        clock.advance(to: 1001)
        writer.pauseVideo()
        // 10秒のオフ。この間に来たフレームの扱いは呼び出し側(取得元の停止)が防ぐ。
        feed(writer, clock: clock, from: 1011, seconds: 1)
        clock.advance(to: 1012)
        let ok = await writer.close()

        #expect(ok)
        let facts = try await inspectVideo(url)
        #expect(facts.isPlayable)
        #expect(facts.videoTrackCount == 1)
        #expect(facts.audioTrackCount == 1)
        // 壁時計では 12 秒だが、オフの 10 秒は入らない。
        #expect(abs(facts.duration - 2.0) < 0.3)
        #expect(abs(facts.audioDuration - facts.duration) < 0.1)
    }

    @Test func 再オンで対象の大きさが変わっても同じファイルに縦横比を保って続く() async throws {
        let url = makeTestVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: false, now: clock.now)

        feed(writer, clock: clock, from: 1000, seconds: 1, width: 320, height: 180)
        clock.advance(to: 1001)
        writer.pauseVideo()
        // 縦長の対象(180x320)。出力の 320x180 の枠に収める。
        feed(writer, clock: clock, from: 1002, seconds: 1, width: 180, height: 320)
        clock.advance(to: 1003)
        let ok = await writer.close()

        #expect(ok)
        let facts = try await inspectVideo(url)
        #expect(facts.isPlayable)
        // 最初の対象の大きさで固定される。
        #expect(facts.size == CGSize(width: 320, height: 180))
        #expect(abs(facts.duration - 2.0) < 0.3)
    }

    @Test func 録音オンの間だけ実音が入りオフの間は無音で映像と同じ長さになる() async throws {
        let url = makeTestVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: false, now: clock.now)

        // 0-1秒: 録音オフ、1-2秒: 録音オン(440Hz)、2-3秒: 録音オフ。
        feed(writer, clock: clock, from: 1000, seconds: 1)
        clock.advance(to: 1001)
        writer.setAudioActive(true)
        let tone = toneSignal(sampleCount: 48_000, frequencies: [440], sampleRate: 48_000)
        for block in 0..<10 {
            clock.advance(to: 1001 + Double(block + 1) * 0.1)
            writer.appendAudio(Array(tone[block * 4800..<(block + 1) * 4800]))
            writer.append(makeTestFrame(at: 1001 + Double(block) * 0.1, shade: UInt8(block)))
        }
        clock.advance(to: 1002)
        writer.setAudioActive(false)
        feed(writer, clock: clock, from: 1002, seconds: 1)
        clock.advance(to: 1003)
        let ok = await writer.close()

        #expect(ok)
        let facts = try await inspectVideo(url)
        #expect(abs(facts.audioDuration - facts.duration) < 0.1)
        let rms = try await audioRMS(of: url, intervals: [0.1...0.9, 1.1...1.9, 2.1...2.9])
        #expect(rms[0] < 0.001)
        #expect(rms[1] > 0.1)
        #expect(rms[2] < 0.001)
    }

    @Test func 録画だけオンで録音が無くても音声トラックは映像と同じ長さの無音になる() async throws {
        let url = makeTestVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: false, now: clock.now)

        feed(writer, clock: clock, from: 1000, seconds: 2)
        clock.advance(to: 1002)
        _ = await writer.close()

        let facts = try await inspectVideo(url)
        #expect(facts.audioTrackCount == 1)
        #expect(abs(facts.audioDuration - facts.duration) < 0.1)
    }

    /// 書き途中のファイルを複製して(強制終了後に残るものと同じ状態)、確定済みの断片まで
    /// 再生できることを確かめる。movieFragmentInterval を外すと、ここが落ちる。
    @Test func 書き込み途中のファイルでも確定済みの分までは再生できる() async throws {
        let url = makeTestVideoURL()
        let killed = makeTestVideoURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: killed)
        }
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: true, now: clock.now)

        // 断片(5秒)を何回か跨ぐ長さを流す。
        for i in 0..<200 {
            let t = 1000 + Double(i) / 10
            clock.advance(to: t)
            writer.append(makeTestFrame(at: t, shade: UInt8(i % 200)))
            writer.appendAudio([Float](repeating: 0.05, count: 4800))
            // 実時間より速く流すとエンコーダの入力が詰まってフレームが捨てられるため、間を置く。
            try await Task.sleep(for: .milliseconds(8))
        }
        try await Task.sleep(for: .seconds(1))
        try FileManager.default.copyItem(at: url, to: killed)
        // close していないため、複製は索引の確定を経ていない。
        let facts = try await inspectVideo(killed)
        #expect(facts.isPlayable)
        #expect(facts.duration > 4)
        #expect(facts.videoTrackCount == 1)

        clock.advance(to: 1020)
        _ = await writer.close()
    }

    /// 画面が動かない間はフレームが来ない。直前のフレームを書き足さないと映像トラックが
    /// 進まず、断片が確定しないまま強制終了後に再生できなくなる(実測)。実時間で流す。
    @Test func 静止した画面で話し続けて強制終了しても再生できる() async throws {
        let url = makeTestVideoURL()
        let killed = makeTestVideoURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: killed)
        }
        let writer = ScreenVideoWriter(url: url, audioActive: true)
        writer.append(makeTestFrame(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds))
        for _ in 0..<90 {
            writer.appendAudio([Float](repeating: 0.05, count: 4800))
            try await Task.sleep(for: .milliseconds(100))
        }
        try FileManager.default.copyItem(at: url, to: killed)
        let facts = try await inspectVideo(killed)
        #expect(facts.isPlayable)
        #expect(facts.duration > 4)
        _ = await writer.close()
    }

    @Test func オフの区間を挟んでも前の区間の音声の補正が次の区間の先頭の実音を捨てない() async throws {
        let url = makeTestVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: true, now: clock.now)

        clock.advance(to: 1000)
        writer.append(makeTestFrame(at: 1000))
        // 音声を時計よりわずかに速く流し、映像より 0.5 秒以上進ませる(10 秒の窓の後に捨てる分が積まれる)。
        for i in 0...107 {
            clock.advance(to: 1000 + Double(i) * 0.095)
            writer.appendAudio([Float](repeating: 0, count: 4800))
        }
        clock.advance(to: 1010.2)
        writer.pauseVideo()

        // 次の区間の先頭 0.3 秒だけ実音。音声は映像より先に進んでいるので 10.8 秒付近に入る。
        clock.advance(to: 1100)
        writer.append(makeTestFrame(at: 1100))
        let tone = toneSignal(sampleCount: 14_400, frequencies: [440], sampleRate: 48_000)
        for block in 0..<3 {
            writer.appendAudio(Array(tone[block * 4800..<(block + 1) * 4800]))
        }
        writer.appendAudio([Float](repeating: 0, count: 48_000))
        clock.advance(to: 1101.5)
        _ = await writer.close()

        // 音声は 10.8 秒(108 ブロック)まで進んでいる。その直後の 0.3 秒に実音が残っていること。
        let rms = try await audioRMS(of: url, intervals: [10.86...11.06])
        #expect(rms[0] > 0.1)
    }

    @Test func 録音オン中に音声が長く届かなければ映像に合わせて無音で埋める() async throws {
        let url = makeTestVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: true, now: clock.now)

        clock.advance(to: 1000)
        writer.append(makeTestFrame(at: 1000))
        for second in 1...25 {
            clock.advance(to: 1000 + Double(second))
            writer.keepAlive()
            try await Task.sleep(for: .milliseconds(15))
        }
        _ = await writer.close()

        let facts = try await inspectVideo(url)
        #expect(abs(facts.audioDuration - facts.duration) < 3.5)
        #expect(facts.audioDuration > 20)
    }

    @Test func keepAliveで先に進んだ時刻より古い実フレームも捨てずに書く() async throws {
        let url = makeTestVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: false, now: clock.now)

        clock.advance(to: 1000)
        writer.append(makeTestFrame(at: 1000))
        clock.advance(to: 1002)
        writer.keepAlive()
        // 取得時刻は keepAlive の時刻より前。
        writer.append(makeTestFrame(at: 1001.5, shade: 200))
        clock.advance(to: 1003)
        _ = await writer.close()

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        #expect(count >= 3)
    }

    @Test func 停止の起点を記録した後は画を書き足さず動画の末尾は停止の起点までで止まる() async throws {
        let url = makeTestVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: false, now: clock.now)

        clock.advance(to: 1000)
        writer.append(makeTestFrame(at: 1000))
        clock.advance(to: 1002)
        writer.markEnd()
        // 録音の後片付けで close が遅れる間に、時計だけが進む。
        clock.advance(to: 1010)
        writer.keepAlive()
        writer.append(makeTestFrame(at: 1010, shade: 200))
        _ = await writer.close()

        let facts = try await inspectVideo(url)
        #expect(facts.duration > 1.5)
        #expect(facts.duration < 3)
    }

    @Test func 書き込みに失敗すると一度だけ通知して以後は何もしない() async {
        // 存在しないディレクトリには書けない(ディスクが書けない場合の代用)。
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/video.mov")
        let clock = FakeHostClock()
        let writer = ScreenVideoWriter(url: url, audioActive: false, now: clock.now)
        let count = LockedCounter()
        writer.setOnFailure { count.increment() }

        feed(writer, clock: clock, from: 1000, seconds: 1)
        let ok = await writer.close()

        #expect(count.value == 1)
        #expect(writer.isFailed)
        #expect(!ok)
    }

    @Test func 取得サイズは偶数に丸め長辺の上限に収まる() {
        let large = ScreenCaptureSource.captureSize(
            contentSize: CGSize(width: 3456, height: 2234), pointPixelScale: 2)
        #expect(max(large.width, large.height) <= ScreenCaptureSource.maxLongSide)
        #expect(large.width % 2 == 0 && large.height % 2 == 0)
        // 縦横比は保たれる(丸めの誤差内)。
        #expect(abs(Double(large.width) / Double(large.height) - 3456.0 / 2234.0) < 0.01)

        let odd = ScreenCaptureSource.captureSize(
            contentSize: CGSize(width: 801, height: 601), pointPixelScale: 1)
        #expect(odd.width == 800 && odd.height == 600)

        let empty = ScreenCaptureSource.captureSize(contentSize: .zero, pointPixelScale: 2)
        #expect(empty.width >= 2 && empty.height >= 2)
    }

    @Test func システム側の停止はエラーコードで理由に分類される() {
        func reason(_ code: SCStreamError.Code) -> ScreenRecordingStopReason {
            ScreenRecordingStopReason(error: NSError(domain: SCStreamErrorDomain, code: code.rawValue))
        }
        #expect(reason(.userDeclined) == .permissionDenied)
        #expect(reason(.userStopped) == .targetGone)
        #expect(reason(.noWindowList) == .targetGone)
        #expect(reason(.systemStoppedStream) == .targetGone)
        if case .other = reason(.internalError) {} else { Issue.record("その他に分類されない") }
        if case .other = ScreenRecordingStopReason(error: NSError(domain: "x", code: 1)) {
        } else {
            Issue.record("他ドメインのエラーがその他に分類されない")
        }
    }
}

/// 失敗通知の回数を数える(通知はロックを持った状態の別スレッドから来る)。
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
