import AppKit
@preconcurrency import ScreenCaptureKit

/// 録画する対象(画面・ウィンドウ・アプリ)を、macOS の選択画面で選んでもらう。
///
/// 選択画面はシステムが出す。出す場所もシステムが決めるため、こちらでは位置を指定しない。
/// 画面収録の許可を先に求めずに済むのは、ここで選ばれた対象だけが録画の許可になるため。
@MainActor
final class ScreenTargetPicker: NSObject, SCContentSharingPickerObserver {
    static let shared = ScreenTargetPicker()

    /// 選択画面の結果。SCContentFilter は Sendable ではないが、選択画面から受け取った後は
    /// 書き換えず、メインアクターの中でしか触らない。スレッドをまたぐのは受け渡しの一瞬だけ。
    enum Outcome: @unchecked Sendable {
        case picked(SCContentFilter)
        /// ユーザーが選ばずに閉じた。異常ではない。
        case cancelled
        /// 選択画面を開始できなかった。
        case failed(any Error)
    }

    private var continuation: CheckedContinuation<Outcome, Never>?

    private override init() { super.init() }

    /// 選択画面を出し、選ばれた対象か、取り消し・失敗を返す。
    /// 選択画面が開いたまま再度呼ばれたら、前の呼び出しは取り消しで終わらせ、
    /// 結果は新しい呼び出しへ届ける(画面は1つしか開かないため)。
    func pick() async -> Outcome {
        resolve(.cancelled)
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        // 録画の途中で、選択画面の側から対象を差し替えさせない(差し替えは行のメニューから行う)。
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            picker.present()
        }
    }

    /// 待っている呼び出しを取り消しで終わらせる。セッションが終わった時や、
    /// ユーザーが選ぶ前にスイッチを切った時に使う。
    func cancel() {
        guard continuation != nil else { return }
        resolve(.cancelled)
        deactivate()
    }

    private func resolve(_ outcome: Outcome) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: outcome)
    }

    private func deactivate() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    // MARK: - SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let picked = Outcome.picked(filter)
        Task { @MainActor in
            self.resolve(picked)
            self.deactivate()
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            self.resolve(.cancelled)
            self.deactivate()
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let failed = Outcome.failed(error)
        Task { @MainActor in
            self.resolve(failed)
            self.deactivate()
        }
    }

    // MARK: - 表示名

    /// 録画の行に出す対象の名前。
    static func label(for filter: SCContentFilter) -> String {
        switch filter.style {
        case .window:
            guard let window = filter.includedWindows.first else { return "ウィンドウ" }
            let app = window.owningApplication?.applicationName
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 }
            switch (app, title) {
            case let (app?, title?): return "\(app) – \(title)"
            case let (app?, nil): return app
            case let (nil, title?): return title
            default: return "ウィンドウ"
            }
        case .application:
            return filter.includedApplications.first?.applicationName ?? "アプリ"
        case .display:
            guard let id = filter.includedDisplays.first?.displayID,
                let index = NSScreen.screens.firstIndex(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
                })
            else { return "画面" }
            return "画面\(index + 1)"
        default:
            return "選択した対象"
        }
    }
}
