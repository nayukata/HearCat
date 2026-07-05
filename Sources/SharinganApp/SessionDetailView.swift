import AppKit
import SharinganKit
import SwiftUI

/// 過去セッションの詳細。文字起こしの閲覧、録音の再生、要約の生成、削除ができる。
struct SessionDetailView: View {
    let model: AppModel
    let session: SessionInfo
    let onDelete: () -> Void

    @State private var transcript: String?
    @State private var summary: String?
    @State private var player: SessionPlayer?
    @State private var isSummarizing = false
    @State private var summaryError: String?
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let player, player.hasAudio {
                PlayerView(player: player)
                Divider()
            }
            content
        }
        .task(id: session.id) { load() }
        .onDisappear { player?.teardown() }
    }

    private var header: some View {
        HStack {
            Text(session.startDate.formatted(date: .complete, time: .shortened))
                .font(.headline)
            Spacer()
            Button {
                Task { await summarize() }
            } label: {
                if isSummarizing {
                    ProgressView().controlSize(.small)
                } else {
                    Label(summary == nil ? "要約を生成" : "要約を再生成", systemImage: "list.bullet.rectangle")
                }
            }
            .disabled(isSummarizing || (transcript?.isEmpty ?? true))
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([session.directory])
            } label: {
                Label("Finder で表示", systemImage: "folder")
            }
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("削除", systemImage: "trash")
            }
            .confirmationDialog(
                "このセッションを削除しますか？", isPresented: $confirmingDelete
            ) {
                Button("文字起こしと録音を削除", role: .destructive) {
                    player?.teardown()
                    model.delete(session)
                    onDelete()
                }
            } message: {
                Text("元に戻せません。")
            }
        }
        .padding()
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summaryError {
                    Label(summaryError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let summary {
                    GroupBox("要約") {
                        Text(summary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let transcript {
                    GroupBox("文字起こし") {
                        Text(transcript.isEmpty ? "(文字起こしなし)" : transcript)
                            .textSelection(.enabled)
                            .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
    }

    private func load() {
        transcript = session.transcriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        summary = session.summaryURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        player = try? SessionPlayer(micURL: session.micAudioURL, systemURL: session.systemAudioURL)
    }

    private func summarize() async {
        guard let transcript, !transcript.isEmpty else { return }
        isSummarizing = true
        summaryError = nil
        defer { isSummarizing = false }
        do {
            let result = try await TranscriptSummarizer.summarize(transcript: transcript)
            let url = session.directory.appendingPathComponent("summary.md")
            try result.write(to: url, atomically: true, encoding: .utf8)
            summary = result
            model.refreshSessions()
        } catch {
            summaryError = "要約に失敗しました: \(error.localizedDescription)"
        }
    }
}

/// 再生コントロール。再生/一時停止とシークバー。
struct PlayerView: View {
    let player: SessionPlayer
    @State private var scrubTime: TimeInterval?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Text(format(scrubTime ?? player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { scrubTime ?? player.currentTime },
                    set: { scrubTime = $0 }),
                in: 0...max(player.duration, 0.01),
                onEditingChanged: { editing in
                    if !editing, let time = scrubTime {
                        player.seek(to: time)
                        scrubTime = nil
                    }
                })

            Text(format(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = Int(time.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
