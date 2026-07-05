import AppKit
import SwiftUI

/// メニューバーから開く操作メニュー。ワンクリックで開始/停止・トグル切り替えができる。
struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.status.active {
            if let startedAt = model.status.startedAt {
                Text("セッション進行中 (\(startedAt.formatted(date: .omitted, time: .shortened))〜)")
            }
            Button("セッションを停止") {
                Task { await model.stopSession() }
            }
            Toggle("録音", isOn: recordingBinding)
            Toggle("文字起こし", isOn: transcribingBinding)
            if let error = model.status.systemAudioError {
                Text("相手の音声: 取得できていません").foregroundStyle(.secondary)
                    .help(error)
            }
        } else {
            Button("セッションを開始") {
                Task { await model.startSession() }
            }
        }

        Divider()

        Button("履歴を開く") {
            openWindow(id: "main")
            NSApp.activate()
        }

        Divider()

        Button("sharingan を終了") {
            NSApp.terminate(nil)
        }
    }

    private var recordingBinding: Binding<Bool> {
        Binding(
            get: { model.status.recording },
            set: { model.setRecording($0) })
    }

    private var transcribingBinding: Binding<Bool> {
        Binding(
            get: { model.status.transcribing },
            set: { model.setTranscribing($0) })
    }
}
