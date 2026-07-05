import Foundation
import Observation

/// ユーザー設定。UserDefaults に永続化し、変更は即座に反映系の closure へ流す。
/// (エンジンやホットキー登録への反映は AppModel が closure を差し込んで行う。
///  設定がエンジンを直接知ると層が逆転するため。)
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// 録音音量。1.0 が原音、範囲は 0〜2(設定画面のスライダーと揃える)。
    var micGain: Double {
        didSet {
            UserDefaults.standard.set(micGain, forKey: Self.micGainKey)
            gainsChanged?()
        }
    }
    var systemGain: Double {
        didSet {
            UserDefaults.standard.set(systemGain, forKey: Self.systemGainKey)
            gainsChanged?()
        }
    }

    var hotkeys: [HotkeyAction: Hotkey] {
        didSet {
            if let data = try? JSONEncoder().encode(hotkeys) {
                UserDefaults.standard.set(data, forKey: Self.hotkeysKey)
            }
            hotkeysChanged?()
        }
    }

    /// セッション開始時、カレンダーの今の予定名をセッション名に自動で付けるか。
    var calendarNaming: Bool {
        didSet { UserDefaults.standard.set(calendarNaming, forKey: Self.calendarNamingKey) }
    }

    @ObservationIgnored var gainsChanged: (() -> Void)?
    @ObservationIgnored var hotkeysChanged: (() -> Void)?

    private static let micGainKey = "micGain"
    private static let systemGainKey = "systemGain"
    private static let hotkeysKey = "hotkeys"
    private static let calendarNamingKey = "calendarNaming"

    private init() {
        let defaults = UserDefaults.standard
        micGain = defaults.object(forKey: Self.micGainKey) as? Double ?? 1.0
        systemGain = defaults.object(forKey: Self.systemGainKey) as? Double ?? 1.0
        calendarNaming = defaults.object(forKey: Self.calendarNamingKey) as? Bool ?? true
        if let data = defaults.data(forKey: Self.hotkeysKey),
            let decoded = try? JSONDecoder().decode([HotkeyAction: Hotkey].self, from: data)
        {
            hotkeys = decoded
        } else {
            hotkeys = [:]
        }
    }
}
