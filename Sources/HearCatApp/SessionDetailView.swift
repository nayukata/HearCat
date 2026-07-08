import AppKit
import HearCatKit
import SwiftUI

/// 過去セッションの詳細。文字起こしの閲覧、録音の再生、要約の生成、削除ができる。
struct SessionDetailView: View {
    let model: AppModel
    let session: SessionInfo
    let onDelete: () -> Void

    @State private var transcript: String?
    @State private var transcriptLines: [TranscriptLine] = []
    @State private var summary: String?
    @State private var player: SessionPlayer?
    @State private var summaryError: String?
    @State private var confirmingDelete = false
    /// AI 清書(cleaned.md)。原文と同じ形式なので行の表示・再生ジャンプを共用する。
    @State private var cleaned: String?
    @State private var cleanedLines: [TranscriptLine] = []
    /// 文字起こし欄に清書を出すか。清書があるセッションでは既定でオン。
    @State private var showCleaned = false
    @State private var cleanError: String?

    /// 生成中の表示は AppModel の状態に従う(停止直後の自動生成でも進捗が見えるように)。
    private var isSummarizing: Bool {
        model.summarizingSessionID == session.id
    }

    private var isCleaning: Bool {
        model.cleaningSessionID == session.id
    }

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
        .task(id: session.id) { load(forceNewPlayer: true) }
        // 停止直後に詳細へ遷移した場合、最後の発話の確定はまだファイルに
        // 書かれていないことがある。refreshSessions のたびに読み直して追従する。
        .onChange(of: model.sessionsVersion) { load(forceNewPlayer: false) }
        .onDisappear { player?.teardown() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    session.name.isEmpty
                        ? session.startDate.formatted(date: .complete, time: .shortened)
                        : session.name)
                    .font(.headline)
                if !session.name.isEmpty {
                    Text(session.startDate.formatted(date: .complete, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            .disabled(isSummarizing || isCleaning || (transcript?.isEmpty ?? true))
            Button {
                Task { await cleanUp() }
            } label: {
                if isCleaning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(Int(model.cleaningProgress * 100))%")
                            .font(.caption.monospacedDigit())
                    }
                } else {
                    Label(cleaned == nil ? "清書" : "清書し直す", systemImage: "wand.and.stars")
                }
            }
            .help("音声認識の誤変換を、会話の文脈からオンデバイス AI が直します")
            .disabled(isSummarizing || isCleaning || (transcript?.isEmpty ?? true))
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
                if let cleanError {
                    Label(cleanError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let summary {
                    GroupBox {
                        Text(summary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        HStack {
                            Text("要約")
                            Spacer()
                            CopyButton { summary }
                        }
                    }
                }
                if let transcript {
                    GroupBox {
                        if transcript.isEmpty {
                            Text("(文字起こしなし)")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(showCleaned ? cleanedLines : transcriptLines) { line in
                                    transcriptRow(line)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } label: {
                        HStack {
                            Text("文字起こし")
                            if cleaned != nil {
                                Picker("表示", selection: $showCleaned) {
                                    Text("清書").tag(true)
                                    Text("原文").tag(false)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                            Spacer()
                            if !transcript.isEmpty {
                                CopyButton {
                                    TranscriptParser.bodyText(
                                        from: showCleaned ? (cleaned ?? transcript) : transcript)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    /// 1行ぶんの文字起こし。録音内の経過時間(再生バーと同じ物差し)を出し、
    /// クリックで録音のその位置から再生する。ファイル内の実時刻は表示しない
    /// (再生位置と対応づかない表示には意味がないため)。
    @ViewBuilder
    private func transcriptRow(_ line: TranscriptLine) -> some View {
        if let offset = line.offset {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let player, player.hasAudio {
                    Button(formatPlaybackTime(offset)) {
                        player.playFrom(offset)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
                    .help("この位置から再生")
                } else {
                    Text(formatPlaybackTime(offset))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(line.body)
                    .textSelection(.enabled)
            }
        } else {
            Text(line.body)
                .textSelection(.enabled)
        }
    }

    /// forceNewPlayer が false の再読込(sessionsVersion 変化時)では、再生中に
    /// 途切れさせないよう、既に音声を持っているプレーヤーは作り直さない。
    private func load(forceNewPlayer: Bool) {
        transcript = session.transcriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        transcriptLines = TranscriptParser.lines(
            from: transcript ?? "", sessionStart: session.startDate)
        summary = session.summaryURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        cleaned = session.cleanedURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        cleanedLines = TranscriptParser.lines(from: cleaned ?? "", sessionStart: session.startDate)
        if forceNewPlayer {
            // セッションを切り替えた時だけ既定表示を決め直す(再読込でトグルを勝手に戻さない)。
            showCleaned = cleaned != nil
        }
        if forceNewPlayer || player?.hasAudio != true {
            player = SessionPlayer(audioURL: session.audioURL)
        }
    }

    private func cleanUp() async {
        guard let transcript, !transcript.isEmpty else { return }
        cleanError = nil
        do {
            cleaned = try await model.generateCleanTranscript(for: session, transcript: transcript)
            cleanedLines = TranscriptParser.lines(
                from: cleaned ?? "", sessionStart: session.startDate)
            showCleaned = true
        } catch {
            cleanError = "清書に失敗しました: \(error.localizedDescription)"
        }
    }

    private func summarize() async {
        guard let transcript, !transcript.isEmpty else { return }
        summaryError = nil
        do {
            summary = try await model.generateSummary(for: session, transcript: transcript)
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

            Text(formatPlaybackTime(scrubTime ?? player.currentTime))
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

            Text(formatPlaybackTime(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

}

/// 録音内の経過時間の表示。再生バーと文字起こしの行で同じ物差し・同じ見た目にする。
private func formatPlaybackTime(_ time: TimeInterval) -> String {
    let seconds = Int(time.rounded())
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
