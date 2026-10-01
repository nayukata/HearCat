@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit
import Testing

@testable import HearCatKit

/// テスト用のフェイク音源(マイク/システム音声)。何も流さず、開始と停止だけ受ける。
private final class QuietAudioSource: SessionEngine.AudioBufferSource {
    let buffers: AsyncStream<SendableBuffer>
    private let continuation: AsyncStream<SendableBuffer>.Continuation

    init() { (buffers, continuation) = AsyncStream<SendableBuffer>.makeStream() }
    func start() throws {}
    func stop() { continuation.finish() }
}

private actor QuietTranscriber: SessionEngine.ChannelTranscribing {
    func start() async throws {}
    func feed(_ buffer: AVAudioPCMBuffer) {}
    func stop() async {}
}

/// テスト用のフェイクの画面取得元。実機の画面収録(許可と署名が要る)には触れず、
/// テストが指示したタイミングで合成フレームを流し、失敗を起こす。
private final class FakeScreenSource: ScreenFrameSource, @unchecked Sendable {
    let frames: AsyncStream<ScreenFrame>
    private let continuation: AsyncStream<ScreenFrame>.Continuation
    private let lock = NSLock()
    private var onFailure: (@Sendable (ScreenRecordingStopReason) -> Void)?
    private var _stopCount = 0
    var startError: (any Error)?
    var startDelay: Duration?
    var hangsOnStop = false
    /// 開始の待ち中に stop が呼ばれたら、実機の取得元と同じく開始を取り消しのエラーで終える。
    var failsStartIfStopped = false

    init() { (frames, continuation) = AsyncStream<ScreenFrame>.makeStream() }

    var stopCount: Int { lock.withLock { _stopCount } }

    func setOnFailure(_ handler: @escaping @Sendable (ScreenRecordingStopReason) -> Void) {
        lock.withLock { onFailure = handler }
    }

    func start(target: ScreenTarget) async throws {
        if let startDelay { try? await Task.sleep(for: startDelay) }
        if failsStartIfStopped, stopCount > 0 {
            continuation.finish()
            throw ScreenCaptureError.stoppedWhileStarting
        }
        if let startError {
            continuation.finish()
            throw startError
        }
    }

    func stop() async {
        lock.withLock { _stopCount += 1 }
        if hangsOnStop { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
        continuation.finish()
    }

    /// 実時間のホスト時計で、interval ごとに count 枚流す。
    func emit(count: Int, interval: Duration = .milliseconds(100)) async {
        for i in 0..<count {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            continuation.yield(
                ScreenFrame(
                    pixelBuffer: makeTestPixelBuffer(width: 320, height: 180, shade: UInt8(i % 200)),
                    presentationTime: now))
            try? await Task.sleep(for: interval)
        }
    }

    /// システム側から止められた状況を起こす。
    func fail(_ reason: ScreenRecordingStopReason) {
        let handler = lock.withLock { onFailure }
        continuation.finish()
        handler?(reason)
    }
}

/// 作った取得元を覚えておく入れ物(ファクトリは同期クロージャなのでロックで包む)。
private final class SourceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [FakeScreenSource] = []
    /// 新しく作る取得元へ最初に適用する設定。
    var configure: @Sendable (FakeScreenSource) -> Void = { _ in }

    func make() -> FakeScreenSource {
        let source = FakeScreenSource()
        configure(source)
        lock.withLock { sources.append(source) }
        return source
    }
    var all: [FakeScreenSource] { lock.withLock { sources } }
    var last: FakeScreenSource { lock.withLock { sources.last! } }
}

/// 画面録画の組み込み(SessionEngine)の検証。権限・音源・文字起こし・保存先はすべて
/// フェイクへ差し替え、本番の保存先と実機の画面収録には触れない。
@MainActor
struct ScreenRecordingEngineTests {
    private let target = ScreenTarget(filter: nil)

    private struct Harness {
        let engine: SessionEngine
        let root: URL
        let sources: SourceBox
        let events: EventLog
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SessionHealthEvent] = []
        func add(_ event: SessionHealthEvent) { lock.withLock { items.append(event) } }
        var all: [SessionHealthEvent] { lock.withLock { items } }
    }

    private func makeHarness() throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenRecordingEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sources = SourceBox()
        let events = EventLog()
        let engine = SessionEngine()
        engine.micSourceFactory = { _ in QuietAudioSource() }
        engine.systemAudioSourceFactory = { QuietAudioSource() }
        engine.selfTranscriberFactory = { _, _ in QuietTranscriber() }
        engine.otherTranscriberFactory = { _, _ in QuietTranscriber() }
        engine.requestSpeechAuthorization = { .authorized }
        engine.requestMicAccess = { true }
        engine.sessionDirectoryFactory = { _, _, _ in
            let dir = root.appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        engine.screenFrameSourceFactory = { sources.make() }
        engine.onHealthEvent = { events.add($0) }
        return Harness(engine: engine, root: root, sources: sources, events: events)
    }

    private func movFiles(in directory: String) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "mov" }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 基本

    @Test func 録画を一度もオンにしなければ動画ファイルはできない() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: true, transcribe: false)
        let directory = try #require(h.engine.status.sessionDirectory)
        #expect(!h.engine.status.screenRecording)
        await h.engine.stop()

        #expect(movFiles(in: directory).isEmpty)
        #expect(h.sources.all.isEmpty)
    }

    @Test func オンからオフからオンで1本の動画にまとまりオフの間は詰まる() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: true, transcribe: false)
        let directory = try #require(h.engine.status.sessionDirectory)

        try await h.engine.startScreenRecording(target: target)
        #expect(h.engine.status.screenRecording)
        await h.sources.last.emit(count: 6)
        try await h.engine.stopScreenRecording()
        #expect(!h.engine.status.screenRecording)

        // オフの間は動画に入らない。
        try await Task.sleep(for: .milliseconds(1500))

        // 対象を渡さない再オンは、前の対象でそのまま再開する。
        #expect(h.engine.canResumeScreenRecording)
        try await h.engine.startScreenRecording(target: nil)
        #expect(h.engine.status.screenRecording)
        await h.sources.last.emit(count: 6)
        await h.engine.stop()

        let files = movFiles(in: directory)
        #expect(files.count == 1)
        let facts = try await inspectVideo(try #require(files.first))
        #expect(facts.isPlayable)
        #expect(facts.videoTrackCount == 1)
        #expect(facts.audioTrackCount == 1)
        // 壁時計では 3 秒以上。オフの 1.5 秒が詰まって 1.2 秒前後になる。
        #expect(facts.duration > 0.8 && facts.duration < 2.0)
        #expect(abs(facts.audioDuration - facts.duration) < 0.15)
        #expect(h.engine.status.screenRecording == false)
    }

    @Test func セッション外の呼び出しはエラーになる() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        func isNotActive(_ error: any Error) -> Bool {
            if case EngineError.notActive = error { return true }
            return false
        }
        do {
            try await h.engine.startScreenRecording(target: target)
            Issue.record("セッション外の開始がエラーにならない")
        } catch {
            #expect(isNotActive(error))
        }
        do {
            try await h.engine.stopScreenRecording()
            Issue.record("セッション外の停止がエラーにならない")
        } catch {
            #expect(isNotActive(error))
        }

        // 停止後も同じ。
        try await h.engine.start(record: false, transcribe: false)
        await h.engine.stop()
        await #expect(throws: EngineError.self) { try await h.engine.startScreenRecording(target: target) }
    }

    @Test func 二重オンと二重オフは無害() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: false, transcribe: false)
        try await h.engine.stopScreenRecording()  // 最初からオフ
        try await h.engine.startScreenRecording(target: target)
        try await h.engine.startScreenRecording(target: target)
        #expect(h.sources.all.count == 1)
        #expect(h.engine.status.screenRecording)

        try await h.engine.stopScreenRecording()
        try await h.engine.stopScreenRecording()
        #expect(!h.engine.status.screenRecording)
        #expect(h.sources.all.count == 1)
        #expect(h.sources.last.stopCount == 1)
        await h.engine.stop()
    }

    @Test func 対象の指定も前回の対象も無ければ開始できない() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: false, transcribe: false)
        #expect(!h.engine.canResumeScreenRecording)
        do {
            try await h.engine.startScreenRecording(target: nil)
            Issue.record("対象なしで開始できてしまう")
        } catch {
            guard case EngineError.noScreenTarget = error else {
                Issue.record("想定外のエラー: \(error)")
                return
            }
        }
        #expect(h.sources.all.isEmpty)
        await h.engine.stop()
    }

    @Test func フレームが来ないまま止めても動画ファイルはできない() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: true, transcribe: false)
        let directory = try #require(h.engine.status.sessionDirectory)
        try await h.engine.startScreenRecording(target: target)
        try await h.engine.stopScreenRecording()
        try await h.engine.startScreenRecording(target: nil)
        await h.engine.stop()

        #expect(movFiles(in: directory).isEmpty)
    }

    // MARK: - 失敗

    @Test func 開始に失敗するとオフのままで原因が分かり再実行できる() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.sources.configure = { $0.startError = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue) }

        try await h.engine.start(record: true, transcribe: false)
        do {
            try await h.engine.startScreenRecording(target: target)
            Issue.record("許可なしの開始が成功してしまう")
        } catch {
            guard case EngineError.screenRecordingFailed(.permissionDenied) = error else {
                Issue.record("想定外のエラー: \(error)")
                return
            }
        }
        #expect(!h.engine.status.screenRecording)
        #expect(!h.engine.canResumeScreenRecording)
        #expect(h.engine.status.recording)

        // 許可後の再実行。
        h.sources.configure = { _ in }
        try await h.engine.startScreenRecording(target: target)
        #expect(h.engine.status.screenRecording)
        await h.engine.stop()
    }

    @Test func 取得元が途中で止められると録画だけオフに戻り録音は続く() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: true, transcribe: true)
        let directory = try #require(h.engine.status.sessionDirectory)
        try await h.engine.startScreenRecording(target: target)
        await h.sources.last.emit(count: 5)

        h.sources.last.fail(.targetGone)
        await waitUntil { !h.engine.status.screenRecording }

        #expect(!h.engine.status.screenRecording)
        #expect(h.engine.status.active)
        #expect(h.engine.status.recording)
        #expect(h.engine.status.transcribing)
        let stopped = h.events.all.contains {
            if case .screenRecordingStopped(.targetGone) = $0 { return true }
            return false
        }
        #expect(stopped)

        // 前の対象で撮り直せる。止まるまでの分と続きが同じファイルになる。
        try await h.engine.startScreenRecording(target: nil)
        #expect(h.engine.status.screenRecording)
        await h.sources.last.emit(count: 5)
        await h.engine.stop()

        let files = movFiles(in: directory)
        #expect(files.count == 1)
        #expect(try await inspectVideo(try #require(files.first)).isPlayable)
    }

    @Test func 書き込みに失敗すると通知され再オンはエラーになり録音は続く() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: true, transcribe: false)
        let directory = try #require(h.engine.status.sessionDirectory)
        // 動画の出力先にディレクトリを置いて、ファイルを作れない状況にする。
        let blocker = URL(fileURLWithPath: directory)
            .appendingPathComponent("\(URL(fileURLWithPath: directory).lastPathComponent).mov")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)

        try await h.engine.startScreenRecording(target: target)
        await h.sources.last.emit(count: 3)
        await waitUntil { !h.engine.status.screenRecording }

        #expect(!h.engine.status.screenRecording)
        #expect(h.engine.status.recording)
        #expect(h.events.all.contains { if case .screenRecordingStopped(.writeFailed) = $0 { return true } else { return false } })

        do {
            try await h.engine.startScreenRecording(target: nil)
            Issue.record("失敗済みの動画へ再オンできてしまう")
        } catch {
            guard case EngineError.screenRecordingFailed(.writeFailed) = error else {
                Issue.record("想定外のエラー: \(error)")
                return
            }
        }
        #expect(!h.engine.status.screenRecording)
        await h.engine.stop()
    }

    @Test func 開始処理の途中で取得元が失敗すると開始の呼び出しがエラーを返す() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.sources.configure = { $0.startDelay = .milliseconds(300) }

        try await h.engine.start(record: false, transcribe: false)
        let failing = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(80))
            h.sources.last.fail(.targetGone)
        }
        do {
            try await h.engine.startScreenRecording(target: target)
            Issue.record("開始中の失敗が成功で返る")
        } catch {
            guard case EngineError.screenRecordingFailed(.targetGone) = error else {
                Issue.record("想定外のエラー: \(error)")
                return
            }
        }
        try await failing.value
        #expect(!h.engine.status.screenRecording)
        // 呼び出し側へエラーで返したので、イベントとしては重ねない。
        #expect(h.events.all.isEmpty)
        await h.engine.stop()
    }

    @Test func 開始処理の途中で止める操作が入ると取得元を片付けてオフのまま止められたと分かる() async throws {
        for failsStartIfStopped in [false, true] {
            let h = try makeHarness()
            defer { try? FileManager.default.removeItem(at: h.root) }
            h.sources.configure = {
                $0.startDelay = .milliseconds(300)
                $0.failsStartIfStopped = failsStartIfStopped
            }

            try await h.engine.start(record: false, transcribe: false)
            let starting = Task { @MainActor in
                try await h.engine.startScreenRecording(target: target)
            }
            try await Task.sleep(for: .milliseconds(50))
            try await h.engine.stopScreenRecording()
            do {
                try await starting.value
                Issue.record("止められた開始が成功で返る")
            } catch {
                guard case EngineError.screenRecordingCancelled = error else {
                    Issue.record("想定外のエラー: \(error)")
                    return
                }
            }

            #expect(!h.engine.status.screenRecording)
            #expect(h.sources.last.stopCount >= 1)
            // 止められただけなので、異常として通知しない。
            #expect(h.events.all.isEmpty)
            await h.engine.stop()
        }
    }

    // MARK: - 何も記録していないセッションの破棄

    @Test func 何もオンにならなかったセッションは破棄するとディレクトリごと消える() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: false, transcribe: false)
        let directory = try #require(h.engine.status.sessionDirectory)
        let discarded = await h.engine.discardIfNothingRecorded()

        #expect(discarded)
        #expect(!h.engine.status.active)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    @Test func 途中で録音を一度オンにしたセッションは破棄せず残る() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: false, transcribe: false)
        let directory = try #require(h.engine.status.sessionDirectory)
        try h.engine.setRecording(true)
        try h.engine.setRecording(false)
        let discarded = await h.engine.discardIfNothingRecorded()

        #expect(!discarded)
        #expect(h.engine.status.active)
        #expect(FileManager.default.fileExists(atPath: directory))
        await h.engine.stop()
        #expect(FileManager.default.fileExists(atPath: directory))
    }

    @Test func 途中で文字起こしを一度オンにしたセッションは破棄せず残る() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: false, transcribe: false)
        let directory = try #require(h.engine.status.sessionDirectory)
        try h.engine.setTranscribing(true)
        try h.engine.setTranscribing(false)
        let discarded = await h.engine.discardIfNothingRecorded()

        #expect(!discarded)
        #expect(FileManager.default.fileExists(atPath: directory))
        await h.engine.stop()
    }

    @Test func 録画が一度でも始まったセッションは破棄せず残る() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: false, transcribe: false)
        let directory = try #require(h.engine.status.sessionDirectory)
        try await h.engine.startScreenRecording(target: target)
        try await h.engine.stopScreenRecording()
        let discarded = await h.engine.discardIfNothingRecorded()

        #expect(!discarded)
        #expect(h.engine.status.active)
        #expect(FileManager.default.fileExists(atPath: directory))
        await h.engine.stop()
    }

    @Test func 録画中に録音を切り替えても動画は壊れない() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: true, transcribe: false)
        let directory = try #require(h.engine.status.sessionDirectory)
        try await h.engine.startScreenRecording(target: target)
        await h.sources.last.emit(count: 4)
        try h.engine.setRecording(false)
        await h.sources.last.emit(count: 4)
        try h.engine.setRecording(true)
        await h.sources.last.emit(count: 4)
        #expect(h.engine.status.screenRecording)
        await h.engine.stop()

        let facts = try await inspectVideo(try #require(movFiles(in: directory).first))
        #expect(facts.isPlayable)
        #expect(abs(facts.audioDuration - facts.duration) < 0.15)
    }

    // MARK: - 停止

    @Test func 録画中に停止しても固まらずファイルは再生できる形で閉じる() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        try await h.engine.start(record: true, transcribe: true)
        let directory = try #require(h.engine.status.sessionDirectory)
        try await h.engine.startScreenRecording(target: target)
        await h.sources.last.emit(count: 10)

        let began = ContinuousClock.now
        await h.engine.stop()
        #expect(ContinuousClock.now - began < .seconds(5))

        #expect(!h.engine.status.active)
        let facts = try await inspectVideo(try #require(movFiles(in: directory).first))
        #expect(facts.isPlayable)
        #expect(facts.duration > 0.5)
        #expect(!h.events.all.contains { if case .screenRecordingCloseFailed = $0 { return true } else { return false } })
    }

    @Test func 取得元の停止が返らなくても停止全体は上限時間で抜ける() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.sources.configure = { $0.hangsOnStop = true }

        try await h.engine.start(record: true, transcribe: false)
        let directory = try #require(h.engine.status.sessionDirectory)
        try await h.engine.startScreenRecording(target: target)
        await h.sources.last.emit(count: 5)

        let began = ContinuousClock.now
        await h.engine.stop()
        #expect(ContinuousClock.now - began < .seconds(10))

        let facts = try await inspectVideo(try #require(movFiles(in: directory).first))
        #expect(facts.isPlayable)
    }

    // MARK: - Status

    @Test func 録画の項目を持たない古いStatusも読め新しい項目は書き出される() throws {
        let old = #"{"active":true,"recording":true,"transcribing":false}"#
        let decoded = try JSONDecoder().decode(SessionEngine.Status.self, from: Data(old.utf8))
        #expect(decoded.active)
        #expect(!decoded.screenRecording)

        var status = SessionEngine.Status()
        status.screenRecording = true
        let roundTrip = try JSONDecoder().decode(
            SessionEngine.Status.self, from: JSONEncoder().encode(status))
        #expect(roundTrip.screenRecording)

        // 古いクライアントは知らない項目を無視するだけで読める。
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        #expect(json["screenRecording"] as? Bool == true)
        #expect(json["active"] != nil)
    }
}
