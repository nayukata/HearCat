@preconcurrency import AVFoundation
import Foundation
import Observation

/// 録音(自分と相手をミックスした1ファイル)の再生。
@MainActor
@Observable
final class SessionPlayer {
    private let player: AVAudioPlayer?
    private var timer: Timer?

    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false

    var duration: TimeInterval { player?.duration ?? 0 }
    var hasAudio: Bool { player != nil }

    init(audioURL: URL?) {
        player = audioURL.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        player?.prepareToPlay()
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
            timer = nil
        } else {
            if currentTime >= duration { player.currentTime = 0 }
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    /// 指定位置へ飛んで再生を始める。文字起こしの行クリックからのジャンプ用。
    func playFrom(_ time: TimeInterval) {
        seek(to: time)
        if !isPlaying { togglePlayback() }
    }

    /// View が消えるときに呼ぶ。deinit は MainActor の外なのでここで止める。
    func teardown() {
        player?.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
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
        guard let player else { return }
        currentTime = player.currentTime
        // 末尾まで再生し終えると AVAudioPlayer は自動で止まる。UI 側の状態を追従させる。
        if isPlaying && !player.isPlaying {
            isPlaying = false
            currentTime = duration
            timer?.invalidate()
            timer = nil
        }
    }
}
