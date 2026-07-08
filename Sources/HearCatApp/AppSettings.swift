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

    /// スピーカーから出た相手の声がマイクに回り込み、自分の発言として文字起こしされるのを防ぐか。
    var echoRemoval: Bool {
        didSet {
            UserDefaults.standard.set(echoRemoval, forKey: Self.echoRemovalKey)
            micGateChanged?()
        }
    }
    /// 入力感度を自動(既定値)にするか。false なら micSensitivity を使う。
    var micSensitivityAuto: Bool {
        didSet {
            UserDefaults.standard.set(micSensitivityAuto, forKey: Self.micSensitivityAutoKey)
            micGateChanged?()
        }
    }
    /// 手動時のマイク入力感度しきい値(RMS)。
    var micSensitivity: Double {
        didSet {
            UserDefaults.standard.set(micSensitivity, forKey: Self.micSensitivityKey)
            micGateChanged?()
        }
    }

    /// 使う入力デバイスの UID。nil はシステム標準。AudioDeviceID でなく UID で保存する
    /// (AudioDeviceID は抜き差しや再起動でデバイスごとに変わり得るため)。
    var micDeviceUID: String? {
        didSet {
            if let micDeviceUID {
                UserDefaults.standard.set(micDeviceUID, forKey: Self.micDeviceUIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.micDeviceUIDKey)
            }
            micDeviceChanged?()
        }
    }

    @ObservationIgnored var gainsChanged: (() -> Void)?
    @ObservationIgnored var hotkeysChanged: (() -> Void)?
    @ObservationIgnored var micGateChanged: (() -> Void)?
    @ObservationIgnored var micDeviceChanged: (() -> Void)?

    private static let micGainKey = "micGain"
    private static let systemGainKey = "systemGain"
    private static let hotkeysKey = "hotkeys"
    private static let calendarNamingKey = "calendarNaming"
    private static let echoRemovalKey = "echoRemoval"
    private static let micSensitivityAutoKey = "micSensitivityAuto"
    private static let micSensitivityKey = "micSensitivity"
    private static let micDeviceUIDKey = "micDeviceUID"

    private init() {
        let defaults = UserDefaults.standard
        micGain = defaults.object(forKey: Self.micGainKey) as? Double ?? 1.0
        systemGain = defaults.object(forKey: Self.systemGainKey) as? Double ?? 1.0
        calendarNaming = defaults.object(forKey: Self.calendarNamingKey) as? Bool ?? true
        // かつての用語集(平文/構造化)の残骸を掃除する。
        defaults.removeObject(forKey: "glossary")
        defaults.removeObject(forKey: "glossaryEntries")
        echoRemoval = defaults.object(forKey: Self.echoRemovalKey) as? Bool ?? true
        micSensitivityAuto = defaults.object(forKey: Self.micSensitivityAutoKey) as? Bool ?? true
        micSensitivity = defaults.object(forKey: Self.micSensitivityKey) as? Double ?? 0.001
        micDeviceUID = defaults.string(forKey: Self.micDeviceUIDKey)
        if let data = defaults.data(forKey: Self.hotkeysKey),
            let decoded = try? JSONDecoder().decode([HotkeyAction: Hotkey].self, from: data)
        {
            hotkeys = decoded
        } else {
            hotkeys = [:]
        }
    }
}
