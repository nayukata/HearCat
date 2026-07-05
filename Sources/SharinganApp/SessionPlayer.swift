@preconcurrency import AVFoundation
import Foundation
import Observation

/// 録音の再生。自分(mic.m4a)と相手(system.m4a)は別ファイルなので、
/// 2つの AVAudioPlayerNode に同じ位置から同時に流して1本の録音として聴かせる。
@MainActor
@Observable
final class SessionPlayer {
    private let engine = AVAudioEngine()
    private let micNode = AVAudioPlayerNode()
    private let systemNode = AVAudioPlayerNode()
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?

    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false

    /// 直近の play(from:) の起点。ノードの再生位置はこの起点からの相対値で返るため保持する。
    private var playbackOffset: TimeInterval = 0
    private var timer: Timer?

    init(micURL: URL?, systemURL: URL?) throws {
        if let micURL {
            let file = try AVAudioFile(forReading: micURL)
            micFile = file
            engine.attach(micNode)
            engine.connect(micNode, to: engine.mainMixerNode, format: file.processingFormat)
            duration = max(duration, Double(file.length) / file.processingFormat.sampleRate)
        }
        if let systemURL {
            let file = try AVAudioFile(forReading: systemURL)
            systemFile = file
            engine.attach(systemNode)
            engine.connect(systemNode, to: engine.mainMixerNode, format: file.processingFormat)
            duration = max(duration, Double(file.length) / file.processingFormat.sampleRate)
        }
    }

    var hasAudio: Bool { micFile != nil || systemFile != nil }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play(from: currentTime >= duration ? 0 : currentTime)
        }
    }

    func play(from time: TimeInterval) {
        stopNodes()
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        schedule(file: micFile, node: micNode, from: time)
        schedule(file: systemFile, node: systemNode, from: time)
        playbackOffset = time
        currentTime = time
        if micFile != nil { micNode.play() }
        if systemFile != nil { systemNode.play() }
        isPlaying = true
        startTimer()
    }

    func pause() {
        currentTime = playbackPosition()
        stopNodes()
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), duration)
        if isPlaying {
            play(from: clamped)
        } else {
            currentTime = clamped
            playbackOffset = clamped
        }
    }

    /// View が消えるときに呼ぶ。deinit は MainActor の外なのでここで止める。
    func teardown() {
        stopNodes()
        engine.stop()
        isPlaying = false
    }

    private func schedule(file: AVAudioFile?, node: AVAudioPlayerNode, from time: TimeInterval) {
        guard let file else { return }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(time * sampleRate)
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        node.scheduleSegment(
            file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining), at: nil)
    }

    private func stopNodes() {
        timer?.invalidate()
        timer = nil
        micNode.stop()
        systemNode.stop()
    }

    private func playbackPosition() -> TimeInterval {
        let node = micFile != nil ? micNode : systemNode
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return playbackOffset
        }
        return playbackOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func tick() {
        guard isPlaying else { return }
        currentTime = playbackPosition()
        if currentTime >= duration {
            stopNodes()
            isPlaying = false
            currentTime = duration
        }
    }
}
