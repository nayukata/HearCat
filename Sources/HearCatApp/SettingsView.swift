import AppKit
import SwiftUI

/// 設定ウィンドウ。ホットキー・録音音量・agent skill の導入をここに集約する。
struct SettingsView: View {
    let model: AppModel
    @Bindable var settings: AppSettings

    @State private var skillInstalled = SkillInstaller.skillInstalled
    @State private var cliInstalled = SkillInstaller.cliInstalled
    @State private var skillMessage: String?

    var body: some View {
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
                Text("他のアプリを使っている時でも効きます。⌘ ⌥ ⌃ のいずれかを含むキー、または F1〜F12 を登録できます。")
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

            Section {
                LabeledContent("skill (使い方の説明書)") {
                    statusLabel(installed: skillInstalled)
                }
                LabeledContent("CLI (操作コマンド hearcat)") {
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
        .frame(width: 520, height: 680)
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
