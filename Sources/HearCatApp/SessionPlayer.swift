@preconcurrency import AVFoundation
import Foundation
import Observation

/// 録音(自分と相手をミックスした1ファイル)の再生。
///
/// ファイルを開く処理(AVAudioPlayer の生成と prepareToPlay)は、1時間超の録音(数十 MB)だと
/// 実測で 140〜350ms かかる。これをメインスレッドで行うと、履歴でセッションを選んだ瞬間に
/// そのぶん画面が固まる。読み込みはバックグラウンドで行い、UI は先に描く。
/// 読み込み中に押された再生要求は取りこぼさず、準備ができ次第その位置から再生する。
@MainActor
@Observable
final class SessionPlayer {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    /// 読み込み中に要求された再生位置。準備完了時に消費する。
    private var pendingStart: TimeInterval?

    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    /// 再生を始められる状態か。読み込み中は false(録音があっても、まだ開けていない)。
    private(set) var isReady = false

    /// 録音があるか。ファイルの有無だけで決まるため読み込みの完了を待たずに答えられる。
    /// 再生バーを出すかどうかの判断はこれで即座にできる。
    let hasAudio: Bool

    var duration: TimeInterval { player?.duration ?? 0 }

    init(audioURL: URL?) {
        hasAudio = audioURL != nil
        guard let audioURL else { return }
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                let player = try? AVAudioPlayer(contentsOf: audioURL)
                // 実際に音を出す直前のバッファ確保もここで済ませる(再生ボタンを押した
                // 瞬間の引っかかりを、切り替え直後の見えない時間に寄せる)。
                player?.prepareToPlay()
                return LoadedPlayer(player: player)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.adopt(loaded.player)
        }
    }

    func togglePlayback() {
        guard let player else {
            // まだ開けていない録音への再生要求は、捨てずに控える。
            if hasAudio { pendingStart = currentTime }
            return
        }
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
        guard isReady else {
            pendingStart = time
            return
        }
        seek(to: time)
        if !isPlaying { togglePlayback() }
    }

    /// View が消えるときと、別のセッションへ切り替わるときに呼ぶ。
    /// deinit は MainActor の外なのでここで止める。
    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        pendingStart = nil
        player?.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    /// バックグラウンドで開き終えた録音を受け取る。読み込み中に控えた再生要求があれば、
    /// ここで消費する(押した操作が無かったことにならないように)。
    private func adopt(_ loaded: AVAudioPlayer?) {
        player = loaded
        isReady = loaded != nil
        guard let pendingStart else { return }
        self.pendingStart = nil
        playFrom(pendingStart)
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

/// バックグラウンドで開いた AVAudioPlayer を MainActor へ渡すための入れ物。
/// AVAudioPlayer は Sendable ではないが、この値は「生成したタスクから受け取り側へ
/// 一度だけ引き渡す」用途に限っており、両側から同時に触ることはない。
private struct LoadedPlayer: @unchecked Sendable {
    let player: AVAudioPlayer?
}
