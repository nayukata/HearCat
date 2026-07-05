@preconcurrency import AVFoundation
import Foundation
import Speech
import os

public enum EngineError: LocalizedError {
    case alreadyActive
    case notActive

    public var errorDescription: String? {
        switch self {
        case .alreadyActive: return "すでにセッションが進行中です"
        case .notActive: return "進行中のセッションがありません"
        }
    }
}

/// 録音と文字起こしのセッション全体を束ねるエンジン。アプリが1個だけ保持する。
/// 「録音」と「文字起こし」は独立トグルで、セッション中いつでも切り替えられる。
@MainActor
public final class SessionEngine {
    public struct Status: Codable, Sendable {
        public var active = false
        public var recording = false
        public var transcribing = false
        public var sessionID: String?
        public var sessionDirectory: String?
        public var transcriptPath: String?
        public var startedAt: Date?
        /// システム音声(相手)の取得に失敗した場合の理由。署名なしビルド等で起きる。
        public var systemAudioError: String?

        public init() {}
    }

    /// 無音区間を文字起こしに流さないゲート。
    /// 無音でも音声認識は架空の文を生成することがある(幻覚)ため、音量が閾値を
    /// 下回るバッファは解析へ渡さない。発話の間の短い沈黙でブツ切りにならないよう、
    /// 無音が一定時間続くまでは開いたままにする。pump タスク内でだけ使う(排他不要)。
    private struct SilenceGate {
        /// これ未満を無音とみなす RMS。システム音声の「何も再生していない」区間(ほぼ0)を
        /// 主な標的にした控えめな値。通常の発話は 0.01 前後なので発話を削ることはない。
        private static let threshold: Float = 0.001
        /// 無音がこの秒数続いたら閉じる。文中の間(ポーズ)より長く取る。
        private static let hangover: TimeInterval = 2.0
        /// 開始直後は「最初の音が鳴るまで閉じたまま」にするため、無音継続扱いで始める。
        private var silentSeconds: TimeInterval = .greatestFiniteMagnitude

        mutating func allows(_ buffer: AVAudioPCMBuffer, level: Float) -> Bool {
            if level >= Self.threshold {
                silentSeconds = 0
                return true
            }
            silentSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            return silentSeconds < Self.hangover
        }
    }

    /// 音声バッファごとに参照するオンオフ状態。
    /// pump(音声転送タスク)は MainActor の外で回るため、actor 越しでなくロックで読む。
    private final class Toggles: Sendable {
        let recording: OSAllocatedUnfairLock<Bool>
        let transcribing: OSAllocatedUnfairLock<Bool>

        init(recording: Bool, transcribing: Bool) {
            self.recording = OSAllocatedUnfairLock(initialState: recording)
            self.transcribing = OSAllocatedUnfairLock(initialState: transcribing)
        }
    }

    public private(set) var status = Status() {
        didSet { onStatusChange?(status) }
    }

    /// 確定/暫定の文字起こしイベント。UI のライブ表示用。MainActor 上で呼ばれる。
    public var onEvent: ((TranscriberEvent) -> Void)?
    public var onStatusChange: ((Status) -> Void)?
    /// 入力レベル(RMS)の通知。UI のメーター表示用。
    /// pump(音声転送タスク)から MainActor の外で呼ばれるため Sendable であること。
    public var onLevel: (@Sendable (_ speaker: String, _ level: Float) -> Void)?

    private let locale: Locale
    private var toggles: Toggles?
    private var mic: MicSource?
    private var system: SystemAudioSource?
    private var mine: ChannelTranscriber?
    private var theirs: ChannelTranscriber?
    private var recorder: SessionRecorder?
    private var writer: TranscriptWriter?
    private var pumps: [Task<Void, Never>] = []
    private var eventTask: Task<Void, Never>?
    private var eventSink: AsyncStream<TranscriberEvent>.Continuation?
    /// 録音音量。セッション開始前に設定された値も、開始時に recorder へ引き継ぐ。
    private var micGain: Float = 1
    private var systemGain: Float = 1

    public init(locale: Locale = Locale(identifier: "ja-JP")) {
        self.locale = locale
    }

    public func start(record: Bool, transcribe: Bool) async throws {
        guard !status.active else { throw EngineError.alreadyActive }

        // 許可が下りなくても止めない(マイクだけ・システム音声だけでも価値があるため)。
        // 失敗はその経路が無音になる形で現れるので、stderr に手がかりを残す。
        let speechAuth = await Self.requestSpeechAuthorization()
        if speechAuth != .authorized {
            FileHandle.standardError.write(Data("音声認識が許可されていません (status: \(speechAuth.rawValue))\n".utf8))
        }
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        if !micGranted {
            FileHandle.standardError.write(Data("マイクが許可されていません\n".utf8))
        }

        let startedAt = Date()
        let sessionDir = try SessionStore.createSessionDirectory(startDate: startedAt)
        do {
            try await startResources(sessionDir: sessionDir, startedAt: startedAt, record: record, transcribe: transcribe)
        } catch {
            // 途中失敗(マイク初期化エラーなど)で取得済みリソースを残さない。
            // 中身はヘッダだけの transcript なので、空セッションごと消す。
            await teardown()
            try? FileManager.default.removeItem(at: sessionDir)
            throw error
        }
    }

    private func startResources(
        sessionDir: URL, startedAt: Date, record: Bool, transcribe: Bool
    ) async throws {
        // 成果物のファイル名はディレクトリ名(日時)と同じ基底名にする。
        // Finder で1ファイルだけ取り出しても、どのセッションのものか分かるように。
        let transcriptURL = sessionDir.appendingPathComponent(
            "\(sessionDir.lastPathComponent).md")
        let writer = try TranscriptWriter(fileURL: transcriptURL)
        await writer.writeHeader(sessionStart: startedAt)
        self.writer = writer

        let toggles = Toggles(recording: record, transcribing: transcribe)
        self.toggles = toggles

        let (events, eventSink) = AsyncStream<TranscriberEvent>.makeStream()
        self.eventSink = eventSink

        // 確定文はファイルへ、確定/暫定の両方を UI へ。消費は1本のタスクに直列化して行を守る。
        eventTask = Task { [weak self] in
            for await event in events {
                if case .final(let segment) = event {
                    await writer.append(segment)
                }
                self?.onEvent?(event)
            }
        }

        var systemAudioError: String?

        // --- 音源と文字起こしの用意 ---
        let mine = ChannelTranscriber(speaker: "自分", locale: locale, sink: eventSink)
        try await mine.start()
        self.mine = mine
        let mic = MicSource()
        try mic.start()
        self.mic = mic

        // 相手(システム音声)は署名なしビルドなどで失敗しても、自分のマイクだけで継続する。
        var theirs: ChannelTranscriber?
        var system: SystemAudioSource?
        do {
            let transcriber = ChannelTranscriber(speaker: "相手", locale: locale, sink: eventSink)
            try await transcriber.start()
            let source = SystemAudioSource()
            try source.start()
            theirs = transcriber
            system = source
            self.theirs = transcriber
            self.system = source
        } catch {
            systemAudioError = "システム音声を取得できません: \(error)"
            FileHandle.standardError.write(Data((systemAudioError! + "\n").utf8))
        }

        // --- 録音(1本のモノラルミックス。自分と相手を重ねて書く) ---
        let recorder = SessionRecorder(
            url: sessionDir.appendingPathComponent("\(sessionDir.lastPathComponent).m4a"),
            includesSystemChannel: system != nil)
        await recorder.setGains(mic: micGain, system: systemGain)
        self.recorder = recorder

        // --- pump: 音源 → 文字起こし/録音への分岐 ---
        let onLevel = self.onLevel
        let micBuffers = mic.buffers
        pumps.append(Task.detached(priority: .userInitiated) {
            var gate = SilenceGate()
            for await item in micBuffers {
                let level = rmsLevel(item.buffer)
                onLevel?("自分", level)
                // ゲートは文字起こしにだけ効かせる。録音は無音も含めて忠実に残す。
                if toggles.transcribing.withLock({ $0 }), gate.allows(item.buffer, level: level) {
                    await mine.feed(item.buffer)
                }
                if toggles.recording.withLock({ $0 }) { await recorder.appendMic(item.buffer) }
            }
        })
        if let theirs, let system {
            let systemBuffers = system.buffers
            pumps.append(Task.detached(priority: .userInitiated) {
                var gate = SilenceGate()
                for await item in systemBuffers {
                    let level = rmsLevel(item.buffer)
                    onLevel?("相手", level)
                    if toggles.transcribing.withLock({ $0 }), gate.allows(item.buffer, level: level) {
                        await theirs.feed(item.buffer)
                    }
                    if toggles.recording.withLock({ $0 }) { await recorder.appendSystem(item.buffer) }
                }
            })
        }

        var status = Status()
        status.active = true
        status.recording = record
        status.transcribing = transcribe
        status.sessionID = sessionDir.lastPathComponent
        status.sessionDirectory = sessionDir.path
        status.transcriptPath = transcriptURL.path
        status.startedAt = startedAt
        status.systemAudioError = systemAudioError
        self.status = status
    }

    public func stop() async {
        guard status.active else { return }
        await teardown()
        status = Status()
    }

    private func teardown() async {
        // 1. 音源を止めてバッファストリームを finish させ、pump が末尾まで流し切るのを待つ。
        mic?.stop()
        system?.stop()
        for pump in pumps { _ = await pump.value }
        pumps = []

        // 2. 末尾の発話を確定文としてフラッシュしてから解析を閉じる。
        await mine?.stop()
        await theirs?.stop()

        // 3. イベントの消費(ファイル書き込み)を完了させる。
        eventSink?.finish()
        _ = await eventTask?.value
        eventTask = nil
        eventSink = nil

        await writer?.close()
        await recorder?.close()

        mic = nil
        system = nil
        mine = nil
        theirs = nil
        recorder = nil
        writer = nil
        toggles = nil
    }

    public func setRecording(_ on: Bool) throws {
        guard status.active, let toggles else { throw EngineError.notActive }
        toggles.recording.withLock { $0 = on }
        status.recording = on
        if !on {
            // 中途半端に残ったサンプルを捨て、再開時に左右チャンネルが揃った状態から始める。
            let recorder = self.recorder
            Task { await recorder?.pause() }
        }
    }

    public func setTranscribing(_ on: Bool) throws {
        guard status.active, let toggles else { throw EngineError.notActive }
        toggles.transcribing.withLock { $0 = on }
        status.transcribing = on
    }

    /// 録音音量を変える。セッション中でなくても呼べる(次のセッションに引き継がれる)。
    public func setGains(mic: Float, system: Float) {
        micGain = mic
        systemGain = system
        if let recorder {
            Task { await recorder.setGains(mic: mic, system: system) }
        }
    }

    // SFSpeechRecognizer.requestAuthorization の完了ハンドラは TCC が背景スレッドで呼ぶ。
    // MainActor 分離のまま継続を受けるとランタイムが trap するため、nonisolated に切り出す。
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
