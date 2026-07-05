import HearCatKit
import SwiftUI

/// 進行中セッションのライブ表示。LP のヒーローにある「HearCat — ライブ」ウィンドウと同じ見た目。
/// 確定した発話に加えて、喋っている途中の暫定テキストを薄い色で出す(ファイルには確定分しか書かれない)。
struct LiveSessionView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            transcriptList
        }
        .background(HCColor.navyGradient)
        // ライブ画面はシステムの外観設定に関わらずネイビー基調(LP と同じ)。
        .environment(\.colorScheme, .dark)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            CatHeadShape()
                .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                .frame(width: 15, height: 15)
            Text("HearCat — ライブ")
                .font(.system(size: 12))
                .foregroundStyle(HCColor.whiteDim)
            EQBars(active: model.status.transcribing)
            if model.status.recording {
                RecBadge()
            }
            Spacer()
            Toggle("録音", isOn: Binding(
                get: { model.status.recording },
                set: { model.setRecording($0) }))
            Toggle("文字起こし", isOn: Binding(
                get: { model.status.transcribing },
                set: { model.setTranscribing($0) }))
            Button("停止", role: .destructive) {
                Task { await model.stopSession() }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(HCColor.blue)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
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
                .padding(20)
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time.map { "[" + $0.formatted(date: .omitted, time: .standard) + "]" } ?? "認識中")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.34))
                .frame(width: 66, alignment: .leading)
            SpeakerChip(speaker: speaker)
            if volatile {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(text)
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.system(size: 13.5))
                    BlinkingCursor()
                }
            } else {
                Text(text)
                    .foregroundStyle(.white.opacity(0.88))
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
            }
        }
    }
}

/// 暫定テキストの末尾で点滅するキャレット(LP の .u.partial .b::after と同じ)。
private struct BlinkingCursor: View {
    @State private var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(HCColor.blueSoft)
            .frame(width: 2, height: 14)
            .opacity(dimmed ? 0 : 1)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}
