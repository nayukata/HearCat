@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit
import os

/// 画面から取れた1フレーム。pixelBuffer は取得元から書き出し側へ1回だけ受け渡すので、
/// SendableBuffer と同じく @unchecked Sendable で包んで運ぶ。
struct ScreenFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// ホスト時計(CMClockGetHostTimeClock)での表示時刻。
    let presentationTime: CMTime
}

/// 画面録画が止まった(または始められなかった)理由。UI が案内を出し分けるための分類で、
/// 文言はアプリ側で組み立てる。
public enum ScreenRecordingStopReason: Sendable, Equatable {
    /// 画面収録が許可されていない。
    case permissionDenied
    /// 録画対象が無くなった。対象のウィンドウが閉じた場合と、メニューバーの共有停止を
    /// 押された場合の両方(どちらも「共有が終わった」状態で、選び直しが要る)。
    case targetGone
    /// 動画ファイルへ書けなくなった(ディスク容量不足など)。
    case writeFailed
    /// 上のどれでもない。reason は診断用の文字列。
    case other(reason: String)

    init(error: any Error) {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else {
            self = .other(reason: "\(error)")
            return
        }
        switch nsError.code {
        case SCStreamError.Code.userDeclined.rawValue,
            SCStreamError.Code.missingEntitlements.rawValue:
            self = .permissionDenied
        case SCStreamError.Code.userStopped.rawValue,
            SCStreamError.Code.noWindowList.rawValue,
            SCStreamError.Code.noDisplayList.rawValue,
            SCStreamError.Code.noCaptureSource.rawValue,
            SCStreamError.Code.systemStoppedStream.rawValue:
            self = .targetGone
        default:
            self = .other(reason: "\(error)")
        }
    }
}

/// 録画対象。実機では SCContentFilter が入る。filter を持たない値はテストが
/// フェイクの取得元へ渡すためだけに使う(SCContentFilter は許可なしでは作れない)。
struct ScreenTarget: @unchecked Sendable {
    let filter: SCContentFilter?
}

enum ScreenCaptureError: LocalizedError {
    case noTarget
    /// startCapture の完了を待つ間に stop が呼ばれた。
    case stoppedWhileStarting

    var errorDescription: String? {
        switch self {
        case .noTarget: return "録画する対象が指定されていません"
        case .stoppedWhileStarting: return "録画の開始中に止められました"
        }
    }
}

/// ScreenCaptureSource が実装する最小限のインターフェース。AudioBufferSource と同じ位置づけで、
/// テストから実機の画面収録(許可と署名に左右される)に触れずに状態遷移だけを固定するために置く。
/// 1回の start から stop までで使い切り、撮り直す時は新しいインスタンスを作る。
protocol ScreenFrameSource: AnyObject, Sendable {
    var frames: AsyncStream<ScreenFrame> { get }
    func start(target: ScreenTarget) async throws
    /// 取得を止めて frames を finish する。stop 自体が失敗しても frames は必ず finish する。
    func stop() async
    /// start が成功したあとに取得が止められた時の通知先(対象ウィンドウが閉じた、
    /// 共有停止を押された等)。自分で stop した場合は呼ばない。
    func setOnFailure(_ handler: @escaping @Sendable (ScreenRecordingStopReason) -> Void)
}

/// SCStream でフレームを流す取得元。画面の取得元(ディスプレイ・ウィンドウ・アプリ)は
/// ユーザーが選んだ SCContentFilter に任せ、ここは取得と通知だけを持つ。
final class ScreenCaptureSource: NSObject, ScreenFrameSource, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    /// フレームレートの上限。画面の動きが無い間はフレームが来ないので、実際はこれ以下になる。
    static let maxFramesPerSecond: Int32 = 30
    /// 取得サイズの長辺の上限(ピクセル)。Retina の大画面をそのままの解像度で撮ると
    /// ファイルとエンコード負荷が会議の記録には過大になるため、この大きさに収める。
    static let maxLongSide = 2560

    let frames: AsyncStream<ScreenFrame>
    private let continuation: AsyncStream<ScreenFrame>.Continuation
    private let queue = DispatchQueue(label: "dev.nayukata.hearcat.screen-capture", qos: .userInitiated)

    private struct State {
        var stream: SCStream?
        /// 呼び出し側の stop() が来た。
        var userStopped = false
        /// システム側の失敗(didStopWithError)が来た。失敗の通知は一度だけにする。
        var systemFailed = false
        var onFailure: (@Sendable (ScreenRecordingStopReason) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    override init() {
        // 書き出しが詰まった時は古いフレームを捨てる(画面は最新が正で、溜めると遅延が伸びる)。
        (frames, continuation) = AsyncStream<ScreenFrame>.makeStream(bufferingPolicy: .bufferingNewest(4))
        super.init()
    }

    func setOnFailure(_ handler: @escaping @Sendable (ScreenRecordingStopReason) -> Void) {
        state.withLock { $0.onFailure = handler }
    }

    func start(target: ScreenTarget) async throws {
        guard let filter = target.filter else {
            continuation.finish()
            throw ScreenCaptureError.noTarget
        }
        let size = Self.captureSize(
            contentSize: filter.contentRect.size, pointPixelScale: CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.maxFramesPerSecond)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        // 書き出し側が直前のフレームを保持し続けるぶんの余裕を含め、上限の 8 にする。
        configuration.queueDepth = 8

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            state.withLock { $0.stream = stream }
            try await stream.startCapture()
            // stop は開始前の stream への stopCapture が失敗して終わるため、
            // 開始が成功した後にここで自分で止めないと、誰も止めない stream が残る。
            if state.withLock({ $0.userStopped }) {
                try? await stream.stopCapture()
                throw ScreenCaptureError.stoppedWhileStarting
            }
        } catch {
            let userStopped = state.withLock { state -> Bool in
                state.stream = nil
                return state.userStopped
            }
            continuation.finish()
            // 止めた操作の最中に起きたエラーは、異常として扱わない。システム側の失敗は本来の理由で返す。
            if userStopped { throw ScreenCaptureError.stoppedWhileStarting }
            throw error
        }
    }

    func stop() async {
        let stream = state.withLock { state -> SCStream? in
            state.userStopped = true
            defer { state.stream = nil }
            return state.stream
        }
        // stopCapture が失敗しても(すでにシステム側で止まっている等)、frames は閉じる。
        try? await stream?.stopCapture()
        continuation.finish()
    }

    /// 取得サイズ(ピクセル、偶数)。ポイント単位の対象サイズに倍率を掛け、長辺を上限に収める。
    /// 動画のエンコーダは奇数の幅・高さを嫌うため偶数に丸める。
    static func captureSize(contentSize: CGSize, pointPixelScale: CGFloat) -> (width: Int, height: Int) {
        let scale = pointPixelScale > 0 ? pointPixelScale : 1
        var width = contentSize.width * scale
        var height = contentSize.height * scale
        guard width >= 2, height >= 2 else { return (2, 2) }
        let longSide = max(width, height)
        if longSide > CGFloat(maxLongSide) {
            let shrink = CGFloat(maxLongSide) / longSide
            width *= shrink
            height *= shrink
        }
        return (max(2, Int(width) & ~1), max(2, Int(height) & ~1))
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        continuation.yield(
            ScreenFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let handler = state.withLock { state -> (@Sendable (ScreenRecordingStopReason) -> Void)? in
            // 自分で止めた結果の通知は失敗として扱わない。
            guard !state.userStopped, !state.systemFailed else { return nil }
            state.systemFailed = true
            state.stream = nil
            return state.onFailure
        }
        continuation.finish()
        handler?(ScreenRecordingStopReason(error: error))
    }
}
