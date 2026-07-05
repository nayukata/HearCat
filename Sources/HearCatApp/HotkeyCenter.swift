import AppKit
import Carbon.HIToolbox

/// ホットキーで呼び出せる操作。設定画面の並び順は allCases の順。
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case toggleSession
    case toggleRecording
    case toggleTranscribing
    case openHistory
    case openSettings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggleSession: "セッション開始/停止"
        case .toggleRecording: "録音オン/オフ"
        case .toggleTranscribing: "文字起こしオン/オフ"
        case .openHistory: "履歴ウィンドウを開く"
        case .openSettings: "設定を開く"
        }
    }

    /// Carbon の EventHotKeyID.id に使う固定番号。イベントから操作を逆引きする。
    var carbonID: UInt32 {
        switch self {
        case .toggleSession: 1
        case .toggleRecording: 2
        case .toggleTranscribing: 3
        case .openHistory: 4
        case .openSettings: 5
        }
    }
}

/// 登録された1個のキー割り当て。display は設定画面での表示用(例: "⌃⌥S")。
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String
}

/// グローバルホットキーの登録と発火。
/// Carbon の RegisterEventHotKey を使う(NSEvent のグローバル監視と違い、
/// アクセシビリティ等の追加許可なしに他アプリがアクティブでも効くため)。
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onAction: ((HotkeyAction) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    private init() {}

    /// 現在の登録を全て置き換える。設定変更のたびに丸ごと再登録する(件数が少ないため)。
    func apply(_ hotkeys: [HotkeyAction: Hotkey]) {
        installHandlerIfNeeded()
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        for (action, hotkey) in hotkeys {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x5348_524E), id: action.carbonID)  // 'SHRN'
            let status = RegisterEventHotKey(
                hotkey.keyCode, hotkey.carbonModifiers, hotKeyID,
                GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    /// キー割り当ての録画中に、既存ホットキーが発火してしまうのを防ぐ。
    func suspend() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                // Carbon イベントはメインスレッドのランループで届く。
                MainActor.assumeIsolated {
                    HotkeyCenter.shared.dispatch(id: hotKeyID.id)
                }
                return noErr
            },
            1, &eventType, nil, nil)
        handlerInstalled = true
    }

    private func dispatch(id: UInt32) {
        guard let action = HotkeyAction.allCases.first(where: { $0.carbonID == id }) else { return }
        onAction?(action)
    }
}

// MARK: - NSEvent からの変換(キー割り当ての録画で使う)

extension Hotkey {
    /// F1〜F12(修飾キーなしでも登録を許すキー)。
    private static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
    ]

    private static let specialKeyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
    ]

    /// キーダウンイベントから割り当てを作る。
    /// 誤爆を防ぐため、⌘⌥⌃ のいずれかを含むか、F キーであることを要求する。
    static func from(event: NSEvent) -> Hotkey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasStrongModifier = !flags.intersection([.command, .option, .control]).isEmpty
        guard hasStrongModifier || functionKeyCodes.contains(event.keyCode) else { return nil }

        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) {
            carbon |= UInt32(controlKey)
            symbols += "⌃"
        }
        if flags.contains(.option) {
            carbon |= UInt32(optionKey)
            symbols += "⌥"
        }
        if flags.contains(.shift) {
            carbon |= UInt32(shiftKey)
            symbols += "⇧"
        }
        if flags.contains(.command) {
            carbon |= UInt32(cmdKey)
            symbols += "⌘"
        }

        let keyName =
            specialKeyNames[event.keyCode]
            ?? event.charactersIgnoringModifiers?.uppercased()
            ?? "?"
        return Hotkey(
            keyCode: UInt32(event.keyCode), carbonModifiers: carbon, display: symbols + keyName)
    }
}
