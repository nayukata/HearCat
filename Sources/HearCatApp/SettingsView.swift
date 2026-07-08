import AppKit
import Foundation
import HearCatKit
import SwiftUI

/// マイクの入力デバイス選択肢。nil(システム標準)を含めて Picker で扱えるようにする。
private struct MicDeviceOption: Identifiable, Hashable {
    let uid: String?
    let name: String
    var id: String { uid ?? "" }
}

/// 設定ウィンドウ。ホットキー・録音音量・agent skill の導入をここに集約する。
struct SettingsView: View {
    let model: AppModel
    @Bindable var settings: AppSettings

    @State private var skillInstalled = SkillInstaller.skillInstalled
    @State private var cliInstalled = SkillInstaller.cliInstalled
    @State private var skillMessage: String?
    @State private var inputDevices: [MicDeviceOption] = [MicDeviceOption(uid: nil, name: "システム標準")]

    var body: some View {
        // 1本の長いスクロールだと下のセクションが見落とされるため、macOS の
        // 設定アプリと同じタブで分ける。各タブが一画面に収まる高さにする。
        TabView {
            Tab("一般", systemImage: "gearshape") { generalTab }
            Tab("音声", systemImage: "mic") { audioTab }
            Tab("ホットキー", systemImage: "keyboard") { hotkeyTab }
        }
        .frame(width: 520, height: 480)
        .onAppear { refreshInputDevices() }
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle("カレンダーの予定名を自動で付ける", isOn: $settings.calendarNaming)
            } header: {
                Text("セッション名")
            } footer: {
                Text("セッション開始時、今の時刻に重なる予定 (5分後までに始まる予定も含む) のタイトルをセッション名にします。macOS のカレンダーに追加したアカウント (Google など) の予定も対象です。初回はカレンダーへのアクセス許可を求めます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("skill") {
                    statusLabel(installed: skillInstalled)
                }
                LabeledContent("CLI") {
                    statusLabel(installed: cliInstalled)
                }
                if !(skillInstalled && cliInstalled) {
                    Button("導入する") {
                        installSkill()
                    }
                }
                if let skillMessage {
                    Text(skillMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("AI エージェント連携")
            } footer: {
                Text("導入すると、AI エージェント (Claude Code / Codex / Copilot など) が「文字起こしを始めて」などの指示でこのアプリを操作できるようになります。エージェントは skill で使い方を知り、CLI でこのアプリを動かします。skill の実体は ~/.agents/skills/ に置き、使用中の各エージェントへはリンクを張ります。CLI は ~/.local/bin へ置きます。導入後はアプリを起動するたびに自動で最新の内容へ更新されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var audioTab: some View {
        Form {
            Section {
                Picker("入力デバイス", selection: $settings.micDeviceUID) {
                    ForEach(inputDevices) { option in
                        Text(option.name).tag(option.uid)
                    }
                }
                Text("デバイスの変更は次のセッションから有効です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("エコー除去", isOn: $settings.echoRemoval)
                Text("スピーカーから出た相手の声が、自分の発言として文字起こしされるのを防ぎます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("入力感度を自動調整", isOn: $settings.micSensitivityAuto)
                if !settings.micSensitivityAuto {
                    micSensitivitySlider
                    // メーターの表示/非表示を伝えるだけで、実際にプローブを動かすかどうかの
                    // 判定(セッション中でないか等)は AppModel.updateMicProbe に集約している。
                    // デバイス変更時の作り直しも settings.micDeviceChanged 経由で同じ場所に集約される。
                    micLevelMeter
                        .onAppear { model.setMicMeterVisible(true) }
                        .onDisappear { model.setMicMeterVisible(false) }
                }
            } header: {
                Text("マイク")
            } footer: {
                Text("入力感度は、マイクの音量がこの値を下回る間は文字起こしに流しません。低すぎると回り込みを拾い、高すぎると小さな声を取りこぼします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                gainSlider(label: "自分 (マイク)", value: $settings.micGain)
                gainSlider(label: "相手 (システム音声)", value: $settings.systemGain)
            } header: {
                Text("録音の音量")
            } footer: {
                Text("録音ファイルに書く音量です。100% が原音。セッション中の変更もすぐに反映されます。文字起こしの精度には影響しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeyTab: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.label) {
                        HotkeyRecorderField(action: action, settings: settings)
                    }
                }
            } header: {
                Text("ホットキー")
            } footer: {
                Text("他のアプリを使っている時でも効きます。⌘ ⌥ ⌃ のいずれかを含むキー、または F1〜F12 を登録できます。録音/文字起こしのキーは、セッション外で押すとその機能だけオンでセッションを開始します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// 入力デバイスの一覧を取得し直す。動的な抜き差し監視はスコープ外なので、
    /// 設定画面を開いた時点のスナップショットでよい。
    private func refreshInputDevices() {
        let available = MicSource.availableInputDevices()
        var options = [MicDeviceOption(uid: nil, name: "システム標準")]
        options += available.map { MicDeviceOption(uid: $0.uid, name: $0.name) }
        // 保存済みのデバイスが今は繋がっていなくても選択肢に残し、Picker の選択状態を壊さない。
        if let savedUID = settings.micDeviceUID, !available.contains(where: { $0.uid == savedUID }) {
            options.append(MicDeviceOption(uid: savedUID, name: "(未接続) \(savedUID)"))
        }
        inputDevices = options
    }

    private func gainSlider(label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: 0...2)
                    .frame(width: 180)
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Button("戻す") { value.wrappedValue = 1.0 }
                    .controlSize(.small)
                    .disabled(value.wrappedValue == 1.0)
            }
        }
    }

    /// 入力感度の下限/上限(RMS)。回り込み(≈0.001)と発話(≈0.01)の間を、
    /// スライダーの分解能に余裕を持たせて挟む範囲。
    private static let micSensitivityMin: Double = 0.0002
    private static let micSensitivityMax: Double = 0.02

    /// RMS(0.0002〜0.02)を対数マッピングで UI 値(0〜1)へ変換する。
    /// RMS は低域(0.001前後)の違いが重要なため、線形マッピングだと低い側が
    /// スライダーの端に張り付いてしまう。
    private func rmsToUI(_ rms: Double) -> Double {
        let clamped = max(Self.micSensitivityMin, min(Self.micSensitivityMax, rms))
        return log(clamped / Self.micSensitivityMin) / log(Self.micSensitivityMax / Self.micSensitivityMin)
    }

    private func uiToRMS(_ ui: Double) -> Double {
        Self.micSensitivityMin * pow(Self.micSensitivityMax / Self.micSensitivityMin, ui)
    }

    private var micSensitivitySlider: some View {
        LabeledContent("入力感度") {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { rmsToUI(settings.micSensitivity) },
                        set: { settings.micSensitivity = uiToRMS($0) }
                    ),
                    in: 0...1
                )
                .frame(width: 180)
                Text(String(format: "%.4f", settings.micSensitivity))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    /// マイク音量のレベルメーター。しきい値の位置を縦線マーカーで重ねて表示する
    /// (Discord の入力感度 UI のイメージ)。バーもしきい値と同じ対数マッピングで描く。
    private var micLevelMeter: some View {
        VStack(alignment: .trailing, spacing: 4) {
            GeometryReader { geometry in
                let levelFraction = rmsToUI(Double(model.micLevel))
                let thresholdFraction = rmsToUI(settings.micSensitivity)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tint)
                        .frame(width: geometry.size.width * levelFraction)
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 2)
                        .offset(x: geometry.size.width * thresholdFraction - 1)
                }
            }
            .frame(height: 8)
        }
    }

    private func statusLabel(installed: Bool) -> some View {
        Label(
            installed ? "導入済み" : "未導入",
            systemImage: installed ? "checkmark.circle.fill" : "circle.dashed"
        )
        .foregroundStyle(installed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
    }

    private func installSkill() {
        do {
            try SkillInstaller.install()
            skillMessage = "配置しました"
        } catch {
            skillMessage = error.localizedDescription
        }
        skillInstalled = SkillInstaller.skillInstalled
        cliInstalled = SkillInstaller.cliInstalled
    }
}

/// キー割り当ての録画フィールド。クリックすると次のキー入力を捕まえて登録する。
struct HotkeyRecorderField: View {
    let action: HotkeyAction
    @Bindable var settings: AppSettings

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording ? endRecording() : beginRecording()
            } label: {
                Text(buttonTitle)
                    .font(.body.monospaced())
                    .frame(minWidth: 96)
            }
            // 割り当て済みのキーだけ消せるように、xmark は別ボタンで出す。
            // 場所は常に確保し、未設定時は透明にする(行ごとにボタンの位置がずれないように)。
            Button {
                settings.hotkeys[action] = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("割り当てを削除")
            .opacity(clearable ? 1 : 0)
            .disabled(!clearable)
        }
        .onDisappear { endRecording() }
    }

    private var clearable: Bool {
        settings.hotkeys[action] != nil && !recording
    }

    private var buttonTitle: String {
        if recording { return "キーを入力…" }
        return settings.hotkeys[action]?.display ?? "未設定"
    }

    private func beginRecording() {
        recording = true
        // 録画中に既存のホットキーが発火すると誤操作になるため一時停止する。
        HotkeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event: event)
            }
            return nil  // 入力はここで消費し、ビープや他の反応をさせない。
        }
    }

    private func handle(event: NSEvent) {
        defer { endRecording() }
        switch event.keyCode {
        case 53:  // Escape はキャンセル
            return
        case 51:  // Delete は割り当て解除
            settings.hotkeys[action] = nil
            return
        default:
            if let hotkey = Hotkey.from(event: event) {
                settings.hotkeys[action] = hotkey
            }
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = false
        // suspend で外したホットキーを現在の設定で登録し直す。
        HotkeyCenter.shared.apply(settings.hotkeys)
    }
}
