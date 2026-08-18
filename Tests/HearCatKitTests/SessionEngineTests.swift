import AVFoundation
import Foundation
import Testing

@testable import HearCatKit

/// テスト用のフェイク音源。実機のマイク/システム音声(Core Audio・署名必須)を使わず、
/// start/stop の呼び出し回数と空の buffers ストリームだけを提供する。
private final class FakeAudioBufferSource: SessionEngine.AudioBufferSource {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    var startError: (any Error)?
    let buffers: AsyncStream<SendableBuffer>
    private let continuation: AsyncStream<SendableBuffer>.Continuation

    init() {
        (buffers, continuation) = AsyncStream<SendableBuffer>.makeStream()
    }

    func start() throws {
        startCallCount += 1
        if let startError { throw startError }
    }

    func stop() {
        stopCallCount += 1
        continuation.finish()
    }
}

/// テスト用のフェイク文字起こし。実機の Speech フレームワーク(モデルの用意や認識処理)に
/// 触れず、呼び出し回数だけ記録する。
private actor FakeChannelTranscriber: SessionEngine.ChannelTranscribing {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    var startError: (any Error)?

    func start() async throws {
        startCallCount += 1
        if let startError { throw startError }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {}

    func stop() async {
        stopCallCount += 1
    }
}

private struct FakeStartError: Error, Equatable {}

/// SessionEngine の状態遷移(start/stop)の検証。
///
/// 実機のマイク・システム音声・音声認識・OS の許可ダイアログには一切触れない。
/// start() は許可未確定のまま呼ぶと AVCaptureDevice.requestAccess が許可ダイアログを
/// 出して待ち続けることがあるため、権限問い合わせと音源/文字起こしの生成をすべて
/// SessionEngine のテスト用注入口(internal な *Factory / request*)でフェイクに差し替える。
/// セッション保存先も sessionDirectoryFactory で専用の一時ディレクトリへ差し替え、
/// SessionStore.rootDirectory(ひいては本番の Application Support)には一切触れない。
///
/// SessionEngine 自体が @MainActor のため、テスト側もそれに合わせる。
@MainActor
struct SessionEngineTests {
    private func tempSessionsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 実機に触れないフェイク一式を差し込んだ engine を作る。
    private func makeEngine(root: URL) -> SessionEngine {
        let engine = SessionEngine()
        engine.micSourceFactory = { _ in FakeAudioBufferSource() }
        engine.systemAudioSourceFactory = { FakeAudioBufferSource() }
        engine.selfTranscriberFactory = { _, _ in FakeChannelTranscriber() }
        engine.otherTranscriberFactory = { _, _ in FakeChannelTranscriber() }
        engine.requestSpeechAuthorization = { .authorized }
        engine.requestMicAccess = { true }
        engine.sessionDirectoryFactory = { _, name, _ in
            let dirName = name.isEmpty ? "session-\(UUID().uuidString)" : "session-\(UUID().uuidString) \(name)"
            let dir = root.appendingPathComponent(dirName, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return engine
    }

    // MARK: - 二重 start

    @Test func 実行中にもう一度startを呼ぶと拒否されディレクトリは増えない() async throws {
        let root = try tempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(root: root)

        try await engine.start(record: false, transcribe: false, name: "会議")
        #expect(engine.status.active)

        await #expect(throws: EngineError.self) {
            try await engine.start(record: false, transcribe: false, name: "会議2")
        }

        // 拒否された2回目でディレクトリが増えていないこと。
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries.count == 1)
        // 1回目のセッションは拒否によって壊れていないこと。
        #expect(engine.status.active)

        await engine.stop()
    }

    // MARK: - start 失敗時の後始末

    @Test func 開始失敗時に作成済みのセッションディレクトリを片付けてエラーを伝える() async throws {
        let root = try tempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(root: root)
        engine.micSourceFactory = { _ in
            let fake = FakeAudioBufferSource()
            fake.startError = FakeStartError()
            return fake
        }

        await #expect(throws: FakeStartError.self) {
            try await engine.start(record: false, transcribe: false, name: "会議")
        }

        #expect(!engine.status.active)
        // 作りかけのセッションディレクトリが残っていないこと。
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries.isEmpty)
    }

    // MARK: - stop の冪等性

    @Test func stopを2回呼んでも安全() async throws {
        let root = try tempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(root: root)
        try await engine.start(record: false, transcribe: false, name: "会議")

        await engine.stop()
        #expect(!engine.status.active)

        // 2回目は何も壊さず早期リターンするだけ。
        await engine.stop()
        #expect(!engine.status.active)
    }

    // MARK: - stop → start の再実行

    @Test func 停止後に再開すると新しいセッションディレクトリで正常に始まる() async throws {
        let root = try tempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(root: root)

        try await engine.start(record: true, transcribe: false, name: "1回目")
        let firstDirectory = engine.status.sessionDirectory
        await engine.stop()
        #expect(!engine.status.active)

        try await engine.start(record: false, transcribe: true, name: "2回目")
        let secondDirectory = engine.status.sessionDirectory

        #expect(engine.status.active)
        #expect(firstDirectory != nil)
        #expect(secondDirectory != nil)
        // 前のセッションのディレクトリを使い回していない。
        #expect(firstDirectory != secondDirectory)
        // 前のセッションのトグル(record: true, transcribe: false)を引きずっていない。
        #expect(engine.status.recording == false)
        #expect(engine.status.transcribing == true)

        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries.count == 2)

        await engine.stop()
    }

    // MARK: - onHealthEvent

    @Test func 権限が拒否されるとonHealthEventで通知される() async throws {
        let root = try tempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(root: root)
        engine.requestSpeechAuthorization = { .denied }
        engine.requestMicAccess = { false }

        var events: [SessionHealthEvent] = []
        engine.onHealthEvent = { events.append($0) }

        try await engine.start(record: false, transcribe: false, name: "会議")

        #expect(
            events.contains {
                if case .speechPermissionDenied = $0 { return true }
                return false
            })
        #expect(
            events.contains {
                if case .micPermissionDenied = $0 { return true }
                return false
            })
        // 権限が無くてもセッション自体は始まる(自分のマイクだけ・システム音声だけでも
        // 価値があるため、start() は権限拒否では失敗しない)。
        #expect(engine.status.active)

        await engine.stop()
    }

    /// 相手のチャンネルだけが欠けている状態の判定。
    ///
    /// タップは音を止めずに枝分かれさせて取るため、取得が死んでいても相手の声は耳に
    /// 届き続ける。耳では気づけない欠落なので、判定の条件をここで固定しておく。
    @Test func 自分は話しているのに相手だけ長く無音なら片側の欠落とみなす() {
        #expect(
            SessionEngine.isSystemChannelOneSided(
                systemSilentFor: 11 * 60, micSilentFor: 5))
    }

    /// 自分が説明し続けている間、相手が数分黙っているのは普通の会議の姿。
    @Test func 相手の無音が短いうちは片側の欠落とみなさない() {
        #expect(
            !SessionEngine.isSystemChannelOneSided(
                systemSilentFor: 3 * 60, micSilentFor: 5))
    }

    /// 両方止まっているのは、ただ会議が途切れているだけかもしれない。
    /// そちらは無音監視(停止するかの確認)の領分で、音声の欠落として扱わない。
    @Test func 自分も黙っているなら片側の欠落とみなさない() {
        #expect(
            !SessionEngine.isSystemChannelOneSided(
                systemSilentFor: 30 * 60, micSilentFor: 30 * 60))
    }

    // MARK: - マイク音声へのエコー除去適用可否
    //
    // pump 内の分岐(SessionEngine.applyEchoCancellation)だけを切り出して検証する。
    // モノラル 48kHz への変換自体は SessionRecorder.monoSamples が既にテスト済みのため、
    // ここでは「process をいつ呼ぶか・打ち消し済みの出力を feed に使うかどうか」だけを見る。

    private static let echoSampleRate = 48000.0

    /// エコー除去がオフでも、返す値は未処理のモノラルのまま
    /// (= process 自体は内部で呼ばれるが、feed には使われない。フォーマットが常に
    /// モノラル変換だけを経由し、揺れないことの前提部分)。
    @Test func エコー除去がオフなら打ち消し済みではなく未処理のまま返す() {
        let canceller = EchoCanceller(sampleRate: Self.echoSampleRate)
        #expect(canceller != nil)
        let mono = toneSignal(sampleCount: 4096, frequencies: [220, 440], sampleRate: Self.echoSampleRate)

        let result = SessionEngine.applyEchoCancellation(
            mono, echoRemoval: false, canceller: canceller)

        #expect(result == mono)
    }

    /// canceller が無い(init 失敗などの素通し経路)場合も、除去フラグに関わらずそのまま返す。
    @Test func cancellerが無ければ除去オンでもそのまま返す() {
        let mono = toneSignal(sampleCount: 4096, frequencies: [220, 440], sampleRate: Self.echoSampleRate)

        let result = SessionEngine.applyEchoCancellation(
            mono, echoRemoval: true, canceller: nil)

        #expect(result == mono)
    }

    /// エコー除去がオンかつ canceller があれば、canceller.process が実際に呼ばれ、
    /// 参照信号と相関するエコー成分が抑圧される(= 恒等関数ではないことを観測で確認する)。
    @Test func エコー除去がオンなら参照と相関する成分を抑圧する() {
        guard let canceller = EchoCanceller(sampleRate: Self.echoSampleRate) else {
            Issue.record("EchoCanceller の初期化に失敗した")
            return
        }

        let totalSamples = Int(Self.echoSampleRate * 4.0)
        let reference = toneSignal(sampleCount: totalSamples, frequencies: [220, 440, 880], sampleRate: Self.echoSampleRate)
        // 近端 = 参照を50ms遅らせて0.3倍したもの(回り込みエコーを模する)。
        let delaySamples = Int(Self.echoSampleRate * 0.05)
        let near = withEcho(of: reference, delaySamples: delaySamples, scale: 0.3)

        let chunkSize = 4096
        var output: [Float] = []
        output.reserveCapacity(totalSamples)
        var offset = 0
        while offset < totalSamples {
            let end = min(offset + chunkSize, totalSamples)
            canceller.pushReference(Array(reference[offset..<end]))
            let processed = SessionEngine.applyEchoCancellation(
                Array(near[offset..<end]), echoRemoval: true, canceller: canceller)
            output.append(contentsOf: processed)
            offset = end
        }

        #expect(output.count == near.count)
        let half = totalSamples / 2
        let nearRms = rmsLevel(near[half...])
        let outRms = rmsLevel(output[half...])
        #expect(nearRms > 0)
        let ratioDb = 20 * log10(Double(outRms) / Double(nearRms))
        #expect(ratioDb <= -10, "抑圧量が不足: \(ratioDb) dB")
    }

}
