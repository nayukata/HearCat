@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// 結果が返らない可能性のある待ちに上限を付ける。上限に先に着いたら nil を返す
/// (work は止めず、その結果は捨てる)。TaskGroup だと終了時に全子タスクの完了を
/// 暗黙に待つため、止まったものに引きずられる。ChannelTranscriber.stop と同じ作り。
func withDeadline<T: Sendable>(
    seconds: Double, _ work: @escaping @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let resumeOnce = ResumeOnce<T?, Never>(continuation)
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            resumeOnce(nil)
        }
        Task {
            let value = await work()
            timer.cancel()
            resumeOnce(value)
        }
    }
}

/// セッションの画面録画を <ディレクトリ名>.mov 1本に書く(映像 HEVC・音声 AAC モノラル)。
///
/// 時間軸の考え方:
/// - 動画は壁時計に沿って進む。画面は変化が無い間フレームが来ないため、「いまの時刻」は
///   フレームの到着ではなく時計(now)から求める。
/// - 録画をオフにしていた区間は動画に入れない。区間(セグメント)ごとに、先頭フレームの
///   時刻を直前までの出力時間へ接ぎ、オフの間を詰める。
/// - 音声はサンプル数で位置を決める(SessionRecorder が .m4a に書くのと同じブロックを受ける)。
///   録音オフの間と録音の前後は無音で埋め、映像と同じ長さにそろえる。
///
/// 強制終了対策: movieFragmentInterval で数秒ごとに断片(moof + mdat)を確定させる。
/// 断片化した MOV は、書き途中で止まっても確定済みの断片まで再生できる(索引が末尾に
/// 1つだけ要る通常の MOV と違い、.m4a のような .aac 経由の退避は要らない)。
/// 失うのは最後の断片(fragmentInterval)ぶんだけ。
///
/// ファイルは最初のフレームが来た時に作る(録画を一度もオンにしなければできない)。
/// 画面が動かない間はフレームが来ない。映像トラックに何も届かないと断片が確定せず、静止した
/// 画面(スライドの共有など)で話し続けたまま強制終了すると、書いた分が再生できなくなる。
/// そのため、一定時間フレームが来なければ直前のフレームを同じ画で書き足す。
///
/// 複数のスレッド(フレームの転送タスク、SessionRecorder の actor、MainActor)から呼ばれるため、
/// 状態はすべてロックの下に置く。
final class ScreenVideoWriter: @unchecked Sendable {
    static let fragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
    private static let audioRate = Int64(SessionRecorder.sampleRate)
    /// 動画のビットレートは「1ピクセルあたり 1bps」を、この範囲に収めて決める。
    /// 画面は動きが少なく、1080p で約 2Mbps あれば文字が読める。
    private static let bitrateRange = 1_000_000...8_000_000
    /// 音声の書き出しが詰まった時に溜めてよい上限(フレーム数)。超えたら新しい分を捨てる。
    private static let maxAudioBacklogFrames = 30 * audioRate
    /// 映像と音声のずれを測る窓の長さ(秒)と、補正に入るずれの大きさ(秒)。
    /// 音声はブロック単位でまとまって届くため、到着の瞬間のずれは最大で 0.15 秒ほど揺れる。
    /// 窓の中で最も小さかったずれが閾値を超えている時だけ「ずっと」ずれていると見なす
    /// (数秒の遅配では、あとから追いつくので補正しない)。
    private static let driftWindow = 10.0
    private static let driftThreshold = 0.3
    /// 直前のフレームを書き足すまでの無フレーム時間(秒)と、確認の間隔。
    private static let keepAliveAfter = 1.0
    private static let keepAlivePeriod = Duration.milliseconds(500)
    /// 録音オン中に音声が届かないまま、映像がこの秒数(音声の位置との差)進んだら無音で埋める。
    /// 認識器の詰まりで起きる数秒の遅配(実測 4〜5 秒)と、録音側の穴埋め(15 秒)より手前に取る。
    private static let audioDryAfter = 10.0
    private static let audioDryPadMargin = 2.0

    private enum AudioChunk {
        case samples([Float])
        case silence(frames: Int64)
    }

    private let url: URL
    private let now: @Sendable () -> CMTime
    private let lock = NSLock()
    private var onFailure: (@Sendable () -> Void)?
    private var failed = false
    private var closed = false

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputWidth = 0
    private var outputHeight = 0
    private var ciContext: CIContext?

    /// 映像: 今のセグメントの先頭フレームのホスト時刻と、そこに対応する出力時間。
    private var segmentOpen = false
    private var segmentStart = CMTime.zero
    private var outputOffset = CMTime.zero
    private var lastVideoTime = CMTime.invalid
    private var lastFrameBuffer: CVPixelBuffer?
    private var lastFrameHost = CMTime.zero
    private var keepAliveTask: Task<Void, Never>?
    private var endMark: CMTime?
    private var audioOverflowLogged = false

    /// 音声: 録音オンか、積んだ位置(フレーム数)、書き出し済みの位置、書き出し待ち。
    private var audioActive: Bool
    private var audioPosition: Int64 = 0
    private var audioWritten: Int64 = 0
    private var audioBacklog: [AudioChunk] = []
    private var audioBacklogFrames: Int64 = 0
    private var audioSkipFrames: Int64 = 0
    private var driftWindowStart: CMTime?
    private var driftMinimum = Double.infinity

    init(url: URL, audioActive: Bool, now: @escaping @Sendable () -> CMTime = ScreenVideoWriter.hostNow) {
        self.url = url
        self.audioActive = audioActive
        self.now = now
    }

    static let hostNow: @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// 書き込みが失敗して以後の録画を諦めた時に一度だけ呼ぶ。ロックを持ったまま呼ばれるため、
    /// 受け側は重い処理や、このクラスへの再入をしないこと。
    func setOnFailure(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onFailure = handler }
    }

    /// 書き込みの失敗で、以後の録画を諦めたか。
    var isFailed: Bool { lock.withLock { failed } }

    /// ファイルを開いたか(最初のフレームが来たか)。
    var hasOpenedFile: Bool { lock.withLock { writer != nil } }

    // MARK: - 映像

    /// 画面の1フレームを書く。書き出しが詰まっている時やずれた時刻のものは捨てる。
    func append(_ frame: ScreenFrame) {
        lock.lock()
        defer { lock.unlock() }
        // 終わりを記録した後の画は、停止処理の時間ぶん末尾を伸ばすだけになる。
        guard !closed, !failed, endMark == nil else { return }

        if writer == nil {
            guard openFile(for: frame.pixelBuffer) else { return }
        }
        if !segmentOpen {
            segmentOpen = true
            segmentStart = frame.presentationTime
            // 間にオフの区間があった場合、音声の位置は映像の出力時間より手前で止まっている。
            padSilence(to: outputOffset)
        }
        var time = outputTime(forHost: frame.presentationTime)
        // 時刻が戻るフレームは書けない(エンコーダが落ちる)。keepAlive が先に進めた時刻と
        // 競合して遅れて着いた実フレームは、捨てずに少し先へ引き上げて書く(最新の画を残すため)。
        if lastVideoTime.isValid, time <= lastVideoTime {
            time = lastVideoTime + CMTime(value: 1, timescale: 1000)
        }
        guard let videoInput, let adaptor else { return }
        // 入力が詰まって書けない間も、writer が失敗していればここで気づく。
        guard videoInput.isReadyForMoreMediaData else {
            checkWriterStatus()
            return
        }
        guard let buffer = fit(frame.pixelBuffer) else { return }
        guard adaptor.append(buffer, withPresentationTime: time) else {
            checkWriterStatus()
            return
        }
        lastVideoTime = time
        lastFrameBuffer = buffer
        lastFrameHost = frame.presentationTime
        if !audioActive { padSilence(to: time) }
        flushAudio()
        checkWriterStatus()
    }

    /// 画面が動かない間、直前のフレームを書き足して映像トラックを進める(型のコメントを参照)。
    /// 一定間隔のタイマーから呼ばれる。
    func keepAlive() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !failed, endMark == nil, segmentOpen, let adaptor, let videoInput,
            let buffer = lastFrameBuffer
        else { return }
        let host = now()
        guard (host - lastFrameHost).seconds >= Self.keepAliveAfter else { return }
        let time = outputTime(forHost: host)
        guard time > lastVideoTime, videoInput.isReadyForMoreMediaData,
            adaptor.append(buffer, withPresentationTime: time)
        else {
            checkWriterStatus()
            return
        }
        lastVideoTime = time
        lastFrameHost = host
        if audioActive {
            // 録音オン中なのに音声が長く届かない(音源の停止など)と、映像だけが先へ進み
            // 書き出しが詰まる。数秒の遅配では動かないよう長めに待ってから無音で埋める。
            padSilence(to: time - CMTime(seconds: Self.audioDryPadMargin, preferredTimescale: 600),
                       onlyIfBehindBy: Self.audioDryAfter)
        } else {
            padSilence(to: time)
        }
        flushAudio()
        checkWriterStatus()
    }

    /// 画面の取得を止めた(録画オフ)。ここまでを1つの区間として閉じ、次のフレームから
    /// 新しい区間を始める。オフの間は動画の時間に数えない。
    func pauseVideo() {
        lock.lock()
        defer { lock.unlock() }
        guard segmentOpen, !closed else { return }
        let end = outputTime(forHost: now())
        let minimumEnd = lastVideoTime.isValid ? lastVideoTime + CMTime(value: 1, timescale: 1000) : end
        outputOffset = max(end, minimumEnd)
        segmentOpen = false
        lastFrameBuffer = nil
        // 区間をまたいで持ち越すと、次の区間の先頭の実音を誤って捨てる。
        resetDriftWindow()
        audioSkipFrames = 0
    }

    // MARK: - 音声

    /// 録音のオン/オフ。オンにした時点で、直前までを無音で映像の時間まで埋める
    /// (録音オフの間も動画は進んでいるため)。
    func setAudioActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, audioActive != active else { return }
        audioActive = active
        guard active, segmentOpen else { return }
        padSilence(to: outputTime(forHost: now()))
        flushAudio()
        resetDriftWindow()
    }

    /// 録音ファイルに書いたものと同じブロック(モノラル 48kHz)を受け取る。
    /// 録画していない間と録音オフの間のものは捨てる。
    func appendAudio(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !failed, segmentOpen, audioActive else { return }

        var samples = samples
        if audioSkipFrames > 0 {
            let drop = min(Int(audioSkipFrames), samples.count)
            audioSkipFrames -= Int64(drop)
            samples.removeFirst(drop)
        }
        guard !samples.isEmpty else { return }
        guard audioBacklogFrames + Int64(samples.count) <= Self.maxAudioBacklogFrames else {
            if !audioOverflowLogged {
                audioOverflowLogged = true
                errorLog("画面録画の音声の書き出しが詰まっています。詰まっている間の音声を捨てます")
            }
            return
        }
        audioOverflowLogged = false
        enqueue(.samples(samples))
        audioPosition += Int64(samples.count)
        flushAudio()
        measureDrift()
    }

    // MARK: - 終了

    /// 停止の起点を記録する。録音の後片付けで close が遅れても、映像の末尾はここまでにする
    /// (音声の末尾は、この後に届く分も欠かさず入れる)。
    func markEnd() {
        lock.lock()
        defer { lock.unlock() }
        guard segmentOpen, !closed, endMark == nil else { return }
        endMark = outputTime(forHost: now())
    }

    /// 残りを書き切ってファイルを閉じる。一度もフレームが来ていなければ何も作らず true。
    /// 閉じ処理が上限時間(deadline)内に終わらない場合は、待たずに false を返す
    /// (確定済みの断片までは再生できる形で残る)。
    func close(deadline: Double = 10) async -> Bool {
        let finishing: AVAssetWriter? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            return writer
        }
        lock.withLock { keepAliveTask?.cancel() }
        guard let finishing else { return !lock.withLock { failed } }

        // 音声の書き出し待ちを、入力が受け付ける間に流し切る(上限 2 秒)。
        let end = lock.withLock { endTimeForClose() }
        lock.withLock { padSilence(to: end) }
        for _ in 0..<100 {
            let done = lock.withLock { () -> Bool in
                flushAudio()
                return audioBacklog.isEmpty
            }
            if done { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let canFinish = lock.withLock { () -> Bool in
            guard !failed, finishing.status == .writing else { return false }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            finishing.endSession(atSourceTime: end)
            return true
        }
        // 書き込みが既に失敗している場合に cancelWriting は呼ばない。出力ファイルを消してしまい、
        // 確定済みの断片まで再生できる、という失敗時の方針に反する。
        guard canFinish else { return false }

        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumeOnce = ResumeOnce<Bool, Never>(continuation)
            let timer = Task {
                try? await Task.sleep(for: .seconds(deadline))
                guard !Task.isCancelled else { return }
                errorLog("画面録画の仕上げが \(Int(deadline)) 秒で終わりません。確定済みの分までを残します")
                resumeOnce(false)
            }
            nonisolated(unsafe) let finishing = finishing
            finishing.finishWriting {
                timer.cancel()
                resumeOnce(finishing.status == .completed)
            }
        }
        if !finished {
            errorLog("画面録画の書き出しに失敗しました: \(finishing.error.map { "\($0)" } ?? "不明")")
        }
        return finished
    }

    // MARK: - 内部(ロックを持った状態で呼ぶ)

    /// 閉じる時点の出力時間。最後のフレームより後ろ、かつ今の時刻まで(画面が動かない間も
    /// 最後のフレームを表示し続けるため)。
    private func endTimeForClose() -> CMTime {
        let current = segmentOpen ? (endMark ?? outputTime(forHost: now())) : outputOffset
        let minimum = (lastVideoTime.isValid ? lastVideoTime : .zero) + CMTime(value: 1, timescale: 30)
        let audioEnd = CMTime(value: audioPosition, timescale: Int32(Self.audioRate))
        return max(current, minimum, audioEnd)
    }

    private func outputTime(forHost host: CMTime) -> CMTime {
        outputOffset + (host - segmentStart)
    }

    private func openFile(for pixelBuffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(pixelBuffer) & ~1
        let height = CVPixelBufferGetHeight(pixelBuffer) & ~1
        guard width >= 2, height >= 2 else {
            fail("フレームの大きさが不正です(\(width)x\(height))")
            return false
        }
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.movieFragmentInterval = Self.fragmentInterval

            let video = AVAssetWriterInput(
                mediaType: .video, outputSettings: Self.videoSettings(width: width, height: height, writer: writer))
            video.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: video,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(video), writer.canAdd(audio) else {
                fail("動画の入力を追加できません")
                return false
            }
            writer.add(video)
            writer.add(audio)
            guard writer.startWriting() else {
                fail("動画ファイルを開始できません: \(writer.error.map { "\($0)" } ?? "不明")")
                return false
            }
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            videoInput = video
            audioInput = audio
            self.adaptor = adaptor
            outputWidth = width
            outputHeight = height
            keepAliveTask = Task.detached { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.keepAlivePeriod)
                    guard let self else { return }
                    self.keepAlive()
                }
            }
            return true
        } catch {
            fail("動画ファイルを作成できません: \(error)")
            return false
        }
    }

    private static func videoSettings(width: Int, height: Int, writer: AVAssetWriter) -> [String: Any] {
        let bitrate = min(max(width * height, bitrateRange.lowerBound), bitrateRange.upperBound)
        func settings(codec: AVVideoCodecType) -> [String: Any] {
            [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: Int(ScreenCaptureSource.maxFramesPerSecond),
                    // 画面は変化が無い間フレームが来ない。フレーム数ではなく時間でキーフレームを
                    // 置かないと、静止画面でシークできる位置が極端に減る。
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ]
        }
        let hevc = settings(codec: .hevc)
        return writer.canApply(outputSettings: hevc, forMediaType: .video) ? hevc : settings(codec: .h264)
    }

    private static var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: SessionRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
    }

    /// 出力の大きさに合わせたピクセルバッファを返す。同じ大きさならそのまま。
    /// 録画対象が途中で変わって大きさが違うフレームは、縦横比を保って枠に収め、余白は黒にする。
    private func fit(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        if width == outputWidth, height == outputHeight { return source }
        guard let pool = adaptor?.pixelBufferPool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
            return nil
        }
        let context = ciContext ?? CIContext(options: [.cacheIntermediates: false])
        ciContext = context

        let frame = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let scale = min(frame.width / CGFloat(width), frame.height / CGFloat(height))
        let scaledWidth = CGFloat(width) * scale
        let scaledHeight = CGFloat(height) * scale
        let image = CIImage(cvPixelBuffer: source)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(
                by: CGAffineTransform(
                    translationX: (frame.width - scaledWidth) / 2,
                    y: (frame.height - scaledHeight) / 2))
        let background = CIImage(color: .black).cropped(to: frame)
        context.render(image.composited(over: background), to: output, bounds: frame, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    // MARK: 音声の積み書き

    private func enqueue(_ chunk: AudioChunk) {
        switch chunk {
        case .samples(let samples):
            audioBacklogFrames += Int64(samples.count)
            audioBacklog.append(chunk)
        case .silence(let frames):
            guard frames > 0 else { return }
            audioBacklogFrames += frames
            if case .silence(let previous)? = audioBacklog.last {
                audioBacklog[audioBacklog.count - 1] = .silence(frames: previous + frames)
            } else {
                audioBacklog.append(chunk)
            }
        }
    }

    /// 音声の位置を、出力時間 time まで無音で進める。すでに先へ進んでいれば何もしない。
    private func padSilence(to time: CMTime, onlyIfBehindBy threshold: Double = 0) {
        let target = time.convertScale(Int32(Self.audioRate), method: .roundHalfAwayFromZero).value
        guard target > audioPosition,
            Double(target - audioPosition) / Double(Self.audioRate) >= threshold
        else { return }
        enqueue(.silence(frames: target - audioPosition))
        audioPosition = target
    }

    /// 入力が受け付ける間、書き出し待ちを送る。
    private func flushAudio() {
        guard let audioInput, !failed else { return }
        while !audioBacklog.isEmpty {
            guard audioInput.isReadyForMoreMediaData else {
                checkWriterStatus()
                return
            }
            let samples: [Float]
            switch audioBacklog[0] {
            case .samples(let value):
                samples = value
                audioBacklog.removeFirst()
            case .silence(let frames):
                // 長い無音は1秒ずつに分けて作る(1時間ぶんを一度にメモリへ置かない)。
                let take = min(frames, Self.audioRate)
                samples = [Float](repeating: 0, count: Int(take))
                if take == frames {
                    audioBacklog.removeFirst()
                } else {
                    audioBacklog[0] = .silence(frames: frames - take)
                }
            }
            audioBacklogFrames -= Int64(samples.count)
            guard let buffer = Self.makeSampleBuffer(samples, startFrame: audioWritten) else {
                fail("音声のバッファを作れません")
                return
            }
            audioWritten += Int64(samples.count)
            guard audioInput.append(buffer) else {
                checkWriterStatus()
                return
            }
        }
    }

    private func resetDriftWindow() {
        driftWindowStart = nil
        driftMinimum = .infinity
    }

    /// 音声が映像に対して「ずっと」遅れている/進んでいる場合に補正する(理由は driftWindow を参照)。
    /// 遅れていれば無音を差して位置を送り、進んでいれば続く分を捨てて待つ。
    private func measureDrift() {
        let host = now()
        guard let start = driftWindowStart else {
            driftWindowStart = host
            return
        }
        let lag = outputTime(forHost: host).seconds - Double(audioPosition) / Double(Self.audioRate)
        driftMinimum = min(driftMinimum, lag)
        guard (host - start).seconds >= Self.driftWindow else { return }
        if driftMinimum > Self.driftThreshold {
            let frames = Int64(driftMinimum * Double(Self.audioRate))
            enqueue(.silence(frames: frames))
            audioPosition += frames
            flushAudio()
        } else if driftMinimum < -Self.driftThreshold {
            audioSkipFrames += Int64(-driftMinimum * Double(Self.audioRate))
        }
        resetDriftWindow()
    }

    // MARK: 失敗

    private func checkWriterStatus() {
        guard let writer, writer.status == .failed else { return }
        fail("動画の書き込みに失敗しました: \(writer.error.map { "\($0)" } ?? "不明")")
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        errorLog(message)
        onFailure?()
    }

    // MARK: モノラル Float → CMSampleBuffer

    private static func makeSampleBuffer(_ samples: [Float], startFrame: Int64) -> CMSampleBuffer? {
        var description = AudioStreamBasicDescription(
            mSampleRate: SessionRecorder.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format
        else { return nil }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block
        else { return nil }
        let copied = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return nil }

        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: startFrame, timescale: Int32(audioRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer) == noErr
        else { return nil }
        return buffer
    }
}
