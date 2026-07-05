import SharinganKit
import SwiftUI

/// 進行中セッションのライブ表示。確定した発話に加えて、
/// 喋っている途中の暫定テキストを薄い色で出す(ファイルには確定分しか書かれない)。
struct LiveSessionView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptList
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            if let startedAt = model.status.startedAt {
                Text("\(startedAt.formatted(date: .omitted, time: .shortened)) 開始")
                    .foregroundStyle(.secondary)
            }
            Toggle("録音", isOn: Binding(
                get: { model.status.recording },
                set: { model.setRecording($0) }))
            Toggle("文字起こし", isOn: Binding(
                get: { model.status.transcribing },
                set: { model.setTranscribing($0) }))
            Spacer()
            Button("停止", role: .destructive) {
                Task { await model.stopSession() }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding()
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let error = model.status.systemAudioError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(model.liveFinals.enumerated()), id: \.offset) { _, segment in
                        segmentLine(
                            time: segment.timestamp, speaker: segment.speaker, text: segment.text,
                            volatile: false)
                    }
                    ForEach(model.liveVolatile.sorted(by: { $0.key < $1.key }), id: \.key) { speaker, text in
                        segmentLine(time: nil, speaker: speaker, text: text, volatile: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.liveFinals.count) {
                proxy.scrollTo("bottom")
            }
            .onChange(of: model.liveVolatile) {
                proxy.scrollTo("bottom")
            }
        }
    }

    private func segmentLine(time: Date?, speaker: String, text: String, volatile: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time.map { $0.formatted(date: .omitted, time: .standard) } ?? "…")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(speaker)
                .font(.caption.bold())
                .foregroundStyle(speaker == "自分" ? .blue : .green)
                .frame(width: 36, alignment: .leading)
            Text(text)
                .foregroundStyle(volatile ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }
}
