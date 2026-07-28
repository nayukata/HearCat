import Foundation
import HearCatKit
import HearCatSummarize
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

    /// グループ(セッション整理のプロジェクトフォルダ)ごとの関連フォルダの絶対パス。
    /// エージェント要約が用語・固有名詞の確認のために参照する。
    var referenceFolders: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(referenceFolders) {
                UserDefaults.standard.set(data, forKey: Self.referenceFoldersKey)
            }
        }
    }

    /// 自動要約(Claude/Codex)へ文字起こしを送信することへの初回同意。
    /// 関連資料との照合(codeImpactConsented)とは別に持つ。片方への同意で
    /// もう片方が自動で許可されないようにする(プライバシー越境の防止)。
    var agentSummaryConsented: Bool {
        didSet { UserDefaults.standard.set(agentSummaryConsented, forKey: Self.agentSummaryConsentedKey) }
    }

    /// 進行中の会議を関連資料と照合する機能で、文字起こしと資料フォルダを
    /// エージェント CLI に読み取らせることへの初回同意。要約と別枠。
    var codeImpactConsented: Bool {
        didSet { UserDefaults.standard.set(codeImpactConsented, forKey: Self.codeImpactConsentedKey) }
    }

    /// 進行中の会議を関連資料と照合する際に使うエージェント。
    var codeImpactAgent: AgentCLI {
        didSet { UserDefaults.standard.set(codeImpactAgent.rawValue, forKey: Self.codeImpactAgentKey) }
    }

    /// 要約(自動・手動どちらも)で使うモデル名。空欄なら各 CLI の設定に任せる。
    /// 関連資料との照合は用途が違うため別枠(codeImpactAgentModels)にする。
    var summaryAgentModels: [AgentCLI: String] {
        didSet {
            if let data = try? JSONEncoder().encode(summaryAgentModels) {
                UserDefaults.standard.set(data, forKey: Self.summaryAgentModelsKey)
            }
        }
    }

    /// 関連資料との照合で使うモデル名。要約とは独立(照合は別モデルで動かしたい人向け)。
    var codeImpactAgentModels: [AgentCLI: String] {
        didSet {
            if let data = try? JSONEncoder().encode(codeImpactAgentModels) {
                UserDefaults.standard.set(data, forKey: Self.codeImpactAgentModelsKey)
            }
        }
    }

    func summaryAgentModel(for cli: AgentCLI) -> String? {
        Self.trimmed(summaryAgentModels[cli])
    }

    func codeImpactAgentModel(for cli: AgentCLI) -> String? {
        Self.trimmed(codeImpactAgentModels[cli])
    }

    private static func trimmed(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// 停止直後に自動で走る要約のエンジン。nil は自動要約を止める。
    /// Claude/Codex を選ぶ場合は agentSummaryConsented が併せて必要
    /// (未同意のまま入っていたら autoSummarize 側で走らせない)。
    var autoSummaryEngine: SummaryEngine? {
        didSet {
            if let autoSummaryEngine {
                UserDefaults.standard.set(autoSummaryEngine.rawValue, forKey: Self.autoSummaryEngineKey)
            } else {
                UserDefaults.standard.set("", forKey: Self.autoSummaryEngineKey)
            }
        }
    }

    /// 新規セッションを入れるグループ。nil は未分類。
    var defaultSessionGroup: String? {
        didSet {
            if let defaultSessionGroup {
                UserDefaults.standard.set(defaultSessionGroup, forKey: Self.defaultSessionGroupKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.defaultSessionGroupKey)
            }
        }
    }

    /// ホットキーでセッションを開始する際、グループ選択画面を挟むか。
    var hotkeyGroupPicker: Bool {
        didSet { UserDefaults.standard.set(hotkeyGroupPicker, forKey: Self.hotkeyGroupPickerKey) }
    }

    /// 無音(マイクとシステム音声の両方)が5分続いたらセッションを自動で終了するか。
    var autoStopOnSilence: Bool {
        didSet {
            UserDefaults.standard.set(autoStopOnSilence, forKey: Self.autoStopOnSilenceKey)
            autoStopChanged?()
        }
    }

    @ObservationIgnored var gainsChanged: (() -> Void)?
    @ObservationIgnored var hotkeysChanged: (() -> Void)?
    @ObservationIgnored var micGateChanged: (() -> Void)?
    @ObservationIgnored var micDeviceChanged: (() -> Void)?
    @ObservationIgnored var autoStopChanged: (() -> Void)?

    private static let micGainKey = "micGain"
    private static let systemGainKey = "systemGain"
    private static let hotkeysKey = "hotkeys"
    private static let calendarNamingKey = "calendarNaming"
    private static let echoRemovalKey = "echoRemoval"
    private static let micSensitivityAutoKey = "micSensitivityAuto"
    private static let micSensitivityKey = "micSensitivity"
    private static let micDeviceUIDKey = "micDeviceUID"
    private static let referenceFoldersKey = "referenceFolders"
    private static let agentSummaryConsentedKey = "agentSummaryConsented"
    private static let codeImpactConsentedKey = "codeImpactConsented"
    private static let codeImpactAgentKey = "codeImpactAgent"
    private static let summaryAgentModelsKey = "summaryAgentModels"
    private static let codeImpactAgentModelsKey = "codeImpactAgentModels"
    /// 要約と照合で同じモデル辞書を共有していた旧版からの移行用(agentModels)、
    /// さらに古い「照合だけにモデル設定があった旧版」の移行用(codeImpactModels)。
    private static let legacyAgentModelsKey = "agentModels"
    private static let legacyCodeImpactModelsKey = "codeImpactModels"
    private static let autoSummaryEngineKey = "autoSummaryEngine"
    private static let defaultSessionGroupKey = "defaultSessionGroup"
    private static let hotkeyGroupPickerKey = "hotkeyGroupPicker"
    private static let autoStopOnSilenceKey = "autoStopOnSilence"

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
        agentSummaryConsented = defaults.object(forKey: Self.agentSummaryConsentedKey) as? Bool ?? false
        codeImpactConsented = defaults.object(forKey: Self.codeImpactConsentedKey) as? Bool ?? false
        codeImpactAgent = defaults.string(forKey: Self.codeImpactAgentKey)
            .flatMap(AgentCLI.init(rawValue:)) ?? .claude
        // 要約用と照合用のモデル辞書を別々に読む。両方とも未設定なら、旧共通辞書
        // (agentModels)からシード → それも無ければさらに旧「照合だけ」の辞書からシード。
        let savedSummaryModels = defaults.data(forKey: Self.summaryAgentModelsKey)
            .flatMap { try? JSONDecoder().decode([AgentCLI: String].self, from: $0) }
        let savedCodeImpactModels = defaults.data(forKey: Self.codeImpactAgentModelsKey)
            .flatMap { try? JSONDecoder().decode([AgentCLI: String].self, from: $0) }
        let legacyAgentModels = defaults.data(forKey: Self.legacyAgentModelsKey)
            .flatMap { try? JSONDecoder().decode([AgentCLI: String].self, from: $0) }
        let legacyCodeImpactOnlyModels = defaults.data(forKey: Self.legacyCodeImpactModelsKey)
            .flatMap { try? JSONDecoder().decode([AgentCLI: String].self, from: $0) }
        let seed = legacyAgentModels ?? legacyCodeImpactOnlyModels ?? [:]
        var initialSummaryModels = savedSummaryModels ?? seed
        var initialCodeImpactModels = savedCodeImpactModels ?? seed
        // 旧設定 → 新設定への初回移行時だけ、未設定の Claude を "sonnet" にする
        // (以前の既定を維持しつつ、Claude Code 側の既定モデル(Fable等)へ流されるのを防ぐ)。
        if savedSummaryModels == nil, Self.trimmed(initialSummaryModels[.claude]) == nil {
            initialSummaryModels[.claude] = "sonnet"
        }
        if savedCodeImpactModels == nil, Self.trimmed(initialCodeImpactModels[.claude]) == nil {
            initialCodeImpactModels[.claude] = "sonnet"
        }
        summaryAgentModels = initialSummaryModels
        codeImpactAgentModels = initialCodeImpactModels
        // 空文字("")は「明示的にオフ」の記録、キー未設定は「未設定=既定に落とす」と解釈する。
        // 既定は Apple Intelligence が使えるなら Apple Intelligence、そうでない機体(Intel Mac 等)は
        // 「オフ」にする(既定のまま黙って何も生成されない silent no-op を避ける)。
        // 未知の rawValue(将来のケース名変更などで来る想定)は「オフ」ではなく既定に落とす
        // (ユーザーが選んだエンジンを黙って消さない)。
        let defaultAutoSummaryEngine: SummaryEngine? =
            OnDeviceModel.unavailableReason() == nil ? .appleIntelligence : nil
        if let raw = defaults.object(forKey: Self.autoSummaryEngineKey) as? String {
            if raw.isEmpty {
                autoSummaryEngine = nil
            } else if let engine = SummaryEngine(rawValue: raw) {
                autoSummaryEngine = engine
            } else {
                autoSummaryEngine = defaultAutoSummaryEngine
            }
        } else {
            autoSummaryEngine = defaultAutoSummaryEngine
        }
        defaultSessionGroup = defaults.string(forKey: Self.defaultSessionGroupKey)
        hotkeyGroupPicker = defaults.object(forKey: Self.hotkeyGroupPickerKey) as? Bool ?? true
        autoStopOnSilence = defaults.object(forKey: Self.autoStopOnSilenceKey) as? Bool ?? true
        if let data = defaults.data(forKey: Self.referenceFoldersKey),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            referenceFolders = decoded
        } else {
            referenceFolders = [:]
        }
        if let data = defaults.data(forKey: Self.hotkeysKey),
            let decoded = try? JSONDecoder().decode([HotkeyAction: Hotkey].self, from: data)
        {
            hotkeys = decoded
        } else {
            hotkeys = [:]
        }
    }
}
