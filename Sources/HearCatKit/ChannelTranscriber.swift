@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 1チャンネル分(自分 or 相手)のライブ文字起こし。
/// 生の AVAudioPCMBuffer を受け取り、確定/暫定のイベントを sink へ流す。
/// actor なのは、バッファ変換や解析投入を UI(メインスレッド)から切り離すため。
public actor ChannelTranscriber {
    private let speaker: String
    private let locale: Locale
    private let sink: AsyncStream<TranscriberEvent>.Continuation

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private let converter = BufferConverter()

    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// 強制確定のタイミング判定。中身は FinalizeWatchdog のコメント参照。
    private var watchdog = FinalizeWatchdog()
    private var fedCount = 0
    /// 解析へ送った累計フレーム数。
    private var fedFrames = 0
    /// 累計フレーム数と実時刻の対応(約1秒間隔で記録)。確定結果の range(解析音声内の
    /// 位置)を実時刻へ変換し、発話開始時刻をタイムスタンプにするために持つ。
    /// ゲートが閉じている間は解析へ音声が流れず解析内の時間が実時間より遅れるため、
    /// サンプルレートだけからの単純な換算では正しい時刻にならない。
    private var feedCheckpoints: [(frame: Int, at: Date)] = []
    /// 最後に feed した実時刻。供給の途切れ(無音ゲートが閉じた区間)の検出に使う。
    private var lastFedAt = Date.distantPast

    /// 直近1分の解析用音声。確定文の時刻範囲から発話末尾を切り出し、
    /// ピッチ上昇(イントネーション疑問文)の判定に使う。
    private var ring: AudioRing?

    public init(speaker: String, locale: Locale, sink: AsyncStream<TranscriberEvent>.Continuation) {
        self.speaker = speaker
        self.locale = locale
        self.sink = sink
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputStream = stream
        self.inputContinuation = continuation
    }

    public func start() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // 暫定結果はライブ表示用。ファイルへ書くのは確定分のみ(ファイルを安定させるため)。
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])

        try await Self.ensureModel(for: transcriber, locale: locale)

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let format = analyzerFormat else { throw TranscriptionError.noAudioFormat }
        debugLog("\(speaker) analyzerFormat sr=\(format.sampleRate) ch=\(format.channelCount)")
        ring = AudioRing(capacity: Int(format.sampleRate) * 60)

        let speaker = self.speaker
        let sink = self.sink
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let raw = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // 表示に値しない結果(空・記号のみ)でも、認識器が動いた事実は
                    // watchdog へ伝える。特に確定は「どこまで確定済みか」を進めないと、
                    // 破棄した確定に対して強制確定を要求し続けてしまう。
                    if result.isFinal {
                        self.noteFinalArrived(range: result.range)
                    } else {
                        self.noteVolatile(raw)
                    }
                    guard !raw.isEmpty else { continue }
                    // 句読点や記号だけの結果は情報がないので捨てる
                    // (スピーカーからの回り込み音の断片で出やすい)。
                    guard raw.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                    // 確定の発話開始時刻は、正確な順に
                    //   1. 認識器が付けた最初の語の時刻(雑音が続く環境でも語の位置を指す)
                    //   2. 範囲内で音が立ち上がった位置(語の時刻が無い時の予備)
                    //   3. 範囲の先頭(前の確定の終端に揃うため、無音・雑音ぶん早く出る)
                    // で決める。暫定は速報性優先で 3 のまま。
                    let startedAt = self.speechStartWallTime(of: result) ?? Date()
                    if result.isFinal {
                        // 無音ゲートのゼロ埋めを長時間聞いた認識器は「あ」などの短い語を
                        // 捏造することがある(実測: 何も再生していない相手側で頻発)。
                        // 該当範囲の音量がほぼゼロなら、実音声は無かったので捨てる。
                        if self.isSilentHallucination(range: result.range) {
                            debugLog("\(speaker) 無音区間の幻聴として破棄 text='\(raw)'")
                            continue
                        }
                        let text = self.finalizeText(raw, range: result.range)
                        // 確定が届いた時刻でなく発話が始まった時刻を使う。確定までの遅延は
                        // チャンネルごとに違うため、届いた時刻だと発話順が入れ替わって
                        // 会話として読めない文字起こしになる。
                        sink.yield(.final(TranscriptSegment(speaker: speaker, text: text, timestamp: startedAt)))
                    } else {
                        debugLog("\(speaker) 暫定 '\(raw.suffix(20))'")
                        sink.yield(.volatile(speaker: speaker, text: raw, startedAt: startedAt))
                    }
                }
            } catch {
                errorLog("[\(speaker)] 認識エラー: \(error)")
            }
        }

        try await analyzer?.start(inputSequence: inputStream)

        watchdogTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                await forceFinalizeIfStalled()
            }
        }
    }

    private func noteVolatile(_ text: String) {
        watchdog.noteVolatile(text)
    }

    private func noteFinalArrived(range: CMTimeRange) {
        let endSeconds = range.end.seconds
        let sampleRate = analyzerFormat?.sampleRate ?? 0
        let frame = endSeconds.isFinite && endSeconds > 0 ? Int(endSeconds * sampleRate) : 0
        watchdog.noteFinal(throughFrame: frame)
    }

    /// 認識結果が停滞していたら、認識器へ強制確定を要求する(無音待ちに頼らない区切り)。
    private func forceFinalizeIfStalled() async {
        guard watchdog.shouldRequestFinalize() else { return }
        debugLog("\(speaker) 結果の停滞を検出したため強制確定 \(watchdog.stallDescription)")
        do {
            try await analyzer?.finalize(through: nil)
        } catch {
            errorLog("[\(speaker)] 強制確定エラー: \(error)")
        }
    }

    /// 幻聴とみなす音量の上限。実発話の範囲 RMS は無音で薄まっても 0.0007 前後、
    /// ゼロ埋め区間から捏造された確定は 0.0(実測)なので、1桁下に線を引く。
    private static let hallucinationRms: Float = 2e-4

    /// 確定の音声範囲がほぼ無音(ゼロ埋めだけ)なら true。
    private func isSilentHallucination(range: CMTimeRange) -> Bool {
        guard let format = analyzerFormat, let ring else { return false }
        let sampleRate = format.sampleRate
        let endSeconds = range.end.seconds
        guard endSeconds.isFinite, endSeconds > 0 else { return false }
        let endFrame = min(Int(endSeconds * sampleRate), ring.totalWritten)
        // リング容量(60秒)を超える古い範囲は判定できないので、直近30秒だけ見る。
        let startFrame = max(Int(range.start.seconds * sampleRate), endFrame - Int(sampleRate * 30))
        guard startFrame < endFrame, let slice = ring.slice(start: startFrame, end: endFrame) else {
            return false
        }
        return Self.rms(slice) < Self.hallucinationRms
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for v in samples { sumSq += v * v }
        return (sumSq / Float(samples.count)).squareRoot()
    }

    /// 確定文の仕上げ。疑問文(語彙 or 末尾のピッチ上昇)なら文末を「？」に直す。
    private func finalizeText(_ text: String, range: CMTimeRange) -> String {
        if QuestionDetector.isLexicalQuestion(text) {
            return QuestionDetector.markAsQuestion(text)
        }
        guard let format = analyzerFormat, let ring else { return text }
        let sampleRate = format.sampleRate
        let endSeconds = range.end.seconds
        guard endSeconds.isFinite, endSeconds > 0 else { return text }
        // range.end は発話の終わりではなく、確定処理までの無音を含んだ広い範囲を指す。
        // そのため範囲全体(上限10秒)を渡し、末尾の有声区間の探索は検出器側に任せる。
        let endFrame = min(Int(endSeconds * sampleRate), ring.totalWritten)
        let startFrame = max(Int(range.start.seconds * sampleRate), endFrame - Int(sampleRate * 10))
        guard let tail = ring.slice(start: startFrame, end: endFrame) else {
            debugLog("\(speaker) 疑問判定: '\(text)' リング範囲外 range=\(range.start.seconds)-\(endSeconds) written=\(ring.totalWritten)")
            return text
        }
        let analysis = QuestionDetector.risingPitchAnalysis(tail: tail, sampleRate: sampleRate)
        if hearcatDebug {
            debugLog("\(speaker) 疑問判定: '\(text)' rising=\(analysis.rising) voiced=\(analysis.voicedFrames)/\(analysis.totalVoiced)/\(analysis.windows) head=\(Int(analysis.headF0)) tail=\(Int(analysis.tailF0)) sliceRms=\(Self.rms(tail)) range=\(String(format: "%.2f", range.start.seconds))-\(String(format: "%.2f", endSeconds))")
        }
        if analysis.rising {
            return QuestionDetector.markAsQuestion(text)
        }
        return text
    }

    /// 解析音声内の位置(秒)を、その音声を feed した実時刻へ変換する。
    /// 記録より前の位置なら nil(呼び出し側が現在時刻で代用する)。
    private func wallTime(forAudioSeconds seconds: Double) -> Date? {
        guard seconds.isFinite, seconds >= 0, let format = analyzerFormat else { return nil }
        return wallTime(forFrame: Int(seconds * format.sampleRate))
    }

    private func wallTime(forFrame frame: Int) -> Date? {
        guard let format = analyzerFormat,
            // 直近の発話ほど末尾に近いので、後ろからの線形探索で十分。
            let checkpoint = feedCheckpoints.last(where: { $0.frame <= frame })
        else { return nil }
        return checkpoint.at.addingTimeInterval(Double(frame - checkpoint.frame) / format.sampleRate)
    }

    /// 確定結果の発話開始の実時刻。優先順はこの関数を呼ぶ側のコメント参照。
    private func speechStartWallTime(of result: SpeechTranscriber.Result) -> Date? {
        if result.isFinal {
            if let wordStart = Self.firstWordStart(of: result.text),
                let at = wallTime(forAudioSeconds: wordStart)
            {
                debugLog(
                    "\(speaker) 語開始=\(String(format: "%.2f", wordStart)) range先頭=\(String(format: "%.2f", result.range.start.seconds))"
                )
                return at
            }
            if let frame = voicedStartFrame(range: result.range), let at = wallTime(forFrame: frame) {
                return at
            }
        }
        return wallTime(forAudioSeconds: result.range.start.seconds)
    }

    /// 認識器が語ごとに付ける時刻範囲(audioTimeRange)から、最初の語の開始秒を得る。
    private static func firstWordStart(of text: AttributedString) -> Double? {
        for (timeRange, _) in text.runs[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
            if let start = timeRange?.start.seconds, start.isFinite, start >= 0 {
                return start
            }
        }
        return nil
    }

    /// 音が立ち上がったとみなす 0.1 秒窓の RMS。発話中の窓は 0.001 以上、
    /// 無音ゲートのゼロ埋めは 0 なので、間に線を引く。
    private static let voicedStartRms: Float = 5e-4

    /// 確定範囲の中で実音声が鳴り始めた累計フレーム位置。
    /// range.start は前の確定の終端に揃うことが多く、発話前の無音(ゼロ埋め)を含む。
    /// そのまま発話開始時刻にすると無音ぶん早い時刻が付き、録音の再生位置と
    /// ズレる(実測9秒。上限は無音ゲートの hangover)。
    private func voicedStartFrame(range: CMTimeRange) -> Int? {
        guard let format = analyzerFormat, let ring else { return nil }
        let sampleRate = format.sampleRate
        let endSeconds = range.end.seconds
        guard endSeconds.isFinite, endSeconds > 0 else { return nil }
        let endFrame = min(Int(endSeconds * sampleRate), ring.totalWritten)
        let rangeStart = max(Int(range.start.seconds * sampleRate), 0)
        guard let slice = ring.slice(start: rangeStart, end: endFrame) else { return nil }
        let window = Int(sampleRate / 10)
        var offset = 0
        while offset < slice.count {
            let windowEnd = min(offset + window, slice.count)
            if Self.rms(Array(slice[offset..<windowEnd])) >= Self.voicedStartRms {
                return rangeStart + offset
            }
            offset = windowEnd
        }
        return nil
    }

    /// 生バッファを受け取り、解析フォーマットへ変換して analyzer へ流す。
    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let format = analyzerFormat else { return }
        do {
            let converted = try converter.convert(buffer, to: format)
            // 対応点は約1秒の音声ごとに加え、供給が途切れた後の再開時にも必ず加える。
            // 無音ゲートが閉じている間は音声が流れず対応点も増えないため、再開直後の
            // 音声を古い対応点から換算すると、無音時間ぶん過去の時刻が付いてしまう
            // (実測で21秒早い行が出た)。
            let now = Date()
            let resumedAfterGap = now.timeIntervalSince(lastFedAt) >= 1.0
            if resumedAfterGap
                || feedCheckpoints.last.map({ fedFrames - $0.frame >= Int(format.sampleRate) }) ?? true
            {
                feedCheckpoints.append((fedFrames, now))
            }
            lastFedAt = now
            inputContinuation.yield(AnalyzerInput(buffer: converted))
            ring?.append(converted.monoFloatSamples())
            fedFrames += Int(converted.frameLength)
            // 無音ゲートのゼロ埋めと実音声を区別して watchdog へ伝える
            // (「実音声を送ったのに結果が来ない」の検出に使う)。
            if rmsLevel(converted) > 1e-6 {
                watchdog.noteVoicedAudio(throughFrame: fedFrames)
            }
            fedCount += 1
            if hearcatDebug && fedCount % 100 == 0 {
                debugLog("\(speaker) fed=\(fedCount) level=\(rmsLevel(converted))")
            }
        } catch {
            errorLog("[\(speaker)] 変換エラー: \(error)")
        }
    }

    public func stop() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        inputContinuation.finish()
        // 末尾に残った音声を確定結果として吐き出してから停止する。
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
    }

    /// ja-JP の認識モデルが未DLならダウンロードし、locale を予約(reserve)する。
    private static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw TranscriptionError.localeNotSupported
        }
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: locale)
        }
    }
}

/// 強制確定のタイミング判定(純粋ロジック。時刻は引数で受け取りテスト可能にする)。
///
/// 認識器は「無音」で文末を検出するため、放っておくと確定が数十秒遅れることがある。
/// 発話が終わった兆候を2通りで捉え、強制確定(finalize)を要求する:
///
/// 1. 暫定テキストが stallAfter 秒変化せず、かつ実音声も voicedQuietFor 秒来ていない。
///    暫定の静止だけを見ると、発話中でも切ってしまう(認識器はチャンク処理のため、
///    喋っている最中でも暫定が2〜3秒止まることがある。実測で文の途中が確定され
///    「頑張ってたじゃん」が「頑張って？」になった)。音が鳴り続けて静まらない環境
///    (ゲーム音など)では noisyStallAfter 秒の静止で諦めて切る。
/// 2. 暫定が一度も出ないまま認識器が休眠した(無音ゲートが音声を止めると、短い発話は
///    暫定を1つも産まずに認識器が止まることがある。実測でこの死角により一言の確定が
///    40〜98秒、次の発話まで遅れた)。「確定済み範囲より先の実音声を送ったのに、
///    stallAfter 秒なんの結果も来ない」ことで検出する。
///
/// 要求が空振りした時(認識器が結果を返さない時)は retryAfter 秒で要求し直し、
/// 2 の経路は maxSilentAttempts 回で諦める(咳など、認識器が文字にしない音への
/// 要求を無限に繰り返さないため)。
struct FinalizeWatchdog {
    /// 結果がこの秒数止まっていたら強制確定を要求する。
    static let stallAfter: TimeInterval = 2.0
    /// 実音声がこの秒数来ていなければ「発話が終わった」とみなす。
    static let voicedQuietFor: TimeInterval = 1.0
    /// 実音声が鳴り続けている時に、暫定の静止だけで切るまでの秒数。
    /// 発話中のチャンク処理の間(実測2〜3秒)より十分長く取る。
    static let noisyStallAfter: TimeInterval = 6.0
    /// 要求後、結果が何も届かない時に要求し直すまでの秒数。
    static let retryAfter: TimeInterval = 5.0
    /// 暫定なし経路(2)で諦めるまでの要求回数。
    static let maxSilentAttempts = 3

    private var pendingVolatileText: String?
    private var pendingVolatileChangedAt = Date.distantPast
    private var requestedAt: Date?
    private var attempts = 0
    private var lastVoicedFedFrame = 0
    private var lastVoicedFedAt = Date.distantPast
    private var finalizedThroughFrame = 0

    /// ログ用。何に対して停滞を検出したか。
    var stallDescription: String {
        if let pendingVolatileText {
            return "暫定='\(pendingVolatileText.suffix(20))' 要求\(attempts)回目"
        }
        return "暫定なし(音声 frame=\(lastVoicedFedFrame) > 確定済み frame=\(finalizedThroughFrame)) 要求\(attempts)回目"
    }

    mutating func noteVolatile(_ text: String, at now: Date = Date()) {
        guard text != pendingVolatileText else { return }
        pendingVolatileText = text
        pendingVolatileChangedAt = now
        requestedAt = nil
        attempts = 0
    }

    /// 確定の到着。表示に値せず破棄された確定でも呼ぶこと。「どこまで確定済みか」が
    /// 進まないと、破棄済みの音声に対して強制確定を要求し続けてしまう。
    mutating func noteFinal(throughFrame: Int) {
        finalizedThroughFrame = max(finalizedThroughFrame, throughFrame)
        pendingVolatileText = nil
        requestedAt = nil
        attempts = 0
    }

    /// 実音声(無音ゲートのゼロ埋めでないバッファ)を解析へ送った。
    mutating func noteVoicedAudio(throughFrame: Int, at now: Date = Date()) {
        lastVoicedFedFrame = throughFrame
        lastVoicedFedAt = now
    }

    /// 今、強制確定を要求すべきか。true を返した時は要求済みとして記録する
    /// (連打防止。次の要求は retryAfter 秒後)。
    mutating func shouldRequestFinalize(now: Date = Date()) -> Bool {
        if let requestedAt {
            guard now.timeIntervalSince(requestedAt) >= Self.retryAfter else { return false }
            if pendingVolatileText == nil, attempts >= Self.maxSilentAttempts {
                // 諦める: この音声は確定を産まないとみなし、以後の要求対象から外す。
                finalizedThroughFrame = max(finalizedThroughFrame, lastVoicedFedFrame)
                self.requestedAt = nil
                attempts = 0
                return false
            }
        }
        let stalled: Bool
        if pendingVolatileText != nil {
            let volatileStill = now.timeIntervalSince(pendingVolatileChangedAt)
            let voicedQuiet = now.timeIntervalSince(lastVoicedFedAt) >= Self.voicedQuietFor
            stalled =
                (volatileStill >= Self.stallAfter && voicedQuiet)
                || volatileStill >= Self.noisyStallAfter
        } else {
            stalled =
                lastVoicedFedFrame > finalizedThroughFrame
                && now.timeIntervalSince(lastVoicedFedAt) >= Self.stallAfter
        }
        if stalled {
            requestedAt = now
            attempts += 1
        }
        return stalled
    }
}
