import AppKit
import HearCatKit
import HearCatSummarize
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
    /// エージェント要約の実行タスク。「キャンセル」ボタンから止められるように保持する。
    /// オンデバイス要約はここに入れない(既存挙動のまま、キャンセル UI を出さない)。
    @State private var agentSummarizeTask: Task<Void, Never>?
    /// 初回同意ダイアログの対象 CLI。nil でない間だけダイアログが出る。
    @State private var confirmingAgentCLI: AgentCLI?
    /// NSMenu をポップアップする位置の基準にする NSView(要約ボタンの実体)。
    @State private var summarizeMenuAnchor: NSView?
    /// NSMenuItem の target。NSMenuItem は target を弱参照するため、
    /// ビューの生存期間だけ強参照を保持する必要がある。
    @State private var summarizeMenuActionHandler = MenuActionHandler()

    /// 生成中の表示は AppModel の状態に従う(停止直後の自動生成でも進捗が見えるように)。
    private var isSummarizing: Bool {
        model.summarizingSessionID == session.id
    }

    /// オンデバイスモデル(Apple Intelligence)が使えない理由。使えるなら nil。
    /// 要約ボタンの disabled と tooltip に使う。システム設定で状態が変わっても、
    /// 詳細画面を開き直せば再評価される。
    private var aiUnavailableReason: String? {
        OnDeviceModel.unavailableReason()
    }

    /// 検出済みのエージェント CLI。1つも無ければ従来どおりオンデバイス単独ボタンにする。
    private var availableAgentCLIs: [AgentCLI] {
        AgentCLIDetector.shared.availableCLIs
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
                    .font(HCFont.headline)
                if !session.name.isEmpty {
                    Text(session.startDate.formatted(date: .complete, time: .shortened))
                        .font(HCFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            summarizeButton
            if isSummarizing, let agentSummarizeTask {
                Button("キャンセル") {
                    agentSummarizeTask.cancel()
                }
                .controlSize(.small)
            }
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
                    GroupBox {
                        SummaryView(markdown: summary)
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
                        Group {
                            if transcript.isEmpty {
                                Text("(文字起こしなし)")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(transcriptLines) { line in
                                        transcriptRow(line)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        // GroupBox 既定の内側余白は薄い。要約(SummaryView)と同じ余白にする。
                        .padding(8)
                    } label: {
                        HStack {
                            Text("文字起こし")
                            Spacer()
                            if !transcript.isEmpty {
                                CopyButton {
                                    TranscriptParser.bodyText(from: transcript)
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
                    .font(HCFont.monospacedDigit(.caption1))
                    .foregroundStyle(.tint)
                    .help("この位置から再生")
                } else {
                    Text(formatPlaybackTime(offset))
                        .font(HCFont.monospacedDigit(.caption1))
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
        if forceNewPlayer || player?.hasAudio != true {
            player = SessionPlayer(audioURL: session.audioURL)
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

    /// エージェント CLI が1つも検出されていなければ従来どおりの単独ボタン、
    /// 1つ以上あれば「オンデバイス」+ 検出された CLI ごとの項目を NSMenu で自前
    /// ポップアップするボタンにする(SwiftUI Menu を使わない理由は下記コメント参照)。
    @ViewBuilder
    private var summarizeButton: some View {
        if availableAgentCLIs.isEmpty {
            Button {
                Task { await summarize() }
            } label: {
                if isSummarizing {
                    ProgressView().controlSize(.small)
                } else {
                    Label(summary == nil ? "要約を生成" : "要約を再生成", systemImage: "list.bullet.rectangle")
                }
            }
            .help(aiUnavailableReason ?? "会話の要点を Apple Intelligence が箇条書きにまとめます")
            .disabled(
                isSummarizing || (transcript?.isEmpty ?? true)
                    || aiUnavailableReason != nil)
        } else {
            // SwiftUI の Menu はラベルを AppKit のボタン描画に変換する際にレイアウト指定
            // (HStack の spacing、文字列先頭の空白のいずれも)を無視してしまい、隣の
            // Button(Finder で表示、削除)と余白が揃わない(実機確認済み)。ラベルを
            // 通常の Button として描き、メニューは NSMenu を自前でポップアップすることで
            // 見た目を統一する。
            Button {
                popUpSummarizeMenu()
            } label: {
                if isSummarizing {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 4) {
                        Label(summary == nil ? "要約を生成" : "要約を再生成", systemImage: "list.bullet.rectangle")
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                }
            }
            .disabled(isSummarizing || (transcript?.isEmpty ?? true))
            .background(MenuAnchorView(anchor: $summarizeMenuAnchor))
            .confirmationDialog(
                "この操作は文字起こしを外部の AI サービスへ送信します。続けますか？",
                isPresented: Binding(
                    get: { confirmingAgentCLI != nil },
                    set: { if !$0 { confirmingAgentCLI = nil } }),
                presenting: confirmingAgentCLI
            ) { cli in
                Button("続ける") {
                    model.settings.agentSummaryConsented = true
                    runAgentSummary(cli)
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }

    /// NSMenu を要約ボタンの直下にポップアップする。項目: オンデバイス、検出済み
    /// エージェント CLI ごと、(関連フォルダ未設定のグループなら)関連フォルダの設定。
    private func popUpSummarizeMenu() {
        guard let anchor = summarizeMenuAnchor else { return }
        let menu = NSMenu()
        // NSMenu は既定で autoenablesItems = true で、この場合 target/action が有効な
        // 項目は isEnabled への手動代入を無視して常に有効化される。オンデバイス不可の
        // 環境でも項目が押せてしまうため、自動有効化を切って isEnabled をそのまま尊重させる。
        menu.autoenablesItems = false

        let onDeviceItem = summarizeMenuActionHandler.makeItem("Apple Intelligence で生成") {
            Task { await summarize() }
        }
        onDeviceItem.isEnabled = aiUnavailableReason == nil
        menu.addItem(onDeviceItem)

        // オンデバイスとエージェント CLI(外部送信を伴う)は性質が違うため区切る。
        if !availableAgentCLIs.isEmpty {
            menu.addItem(.separator())
        }
        for cli in availableAgentCLIs {
            menu.addItem(summarizeMenuActionHandler.makeItem("\(cli.displayName) で生成") {
                requestAgentSummary(cli)
            })
        }

        // 関連フォルダの設定はサイドバーのグループ右クリックの中にもあり気づかれにくいため、
        // まだ設定していないグループにはここからも設定できるようにする。
        // subtitle は macOS 14.4+ で利用可能(このプロジェクトのターゲットは macOS 26)。
        if let folder = session.folder, model.settings.referenceFolders[folder] == nil {
            menu.addItem(.separator())
            let referenceFolderItem = summarizeMenuActionHandler.makeItem("関連フォルダを設定…") {
                ReferenceFolderPicker.pick(forGroup: folder)
            }
            referenceFolderItem.subtitle = "会議に関連する資料やコードの場所。Claude / Codex が誤変換の修正や内容の理解に使います"
            menu.addItem(referenceFolderItem)
        }

        // popUp の指定点はメニューの左上角。素の NSView は isFlipped = false(非 flipped、
        // y=0 が下端)なので、ボタン直下に出すには負のオフセットを使う。NSHostingView 等の
        // flipped なビューに載る場合は上端 y=0 なので、そちらは高さぶん下げる。
        let point = anchor.isFlipped
            ? NSPoint(x: 0, y: anchor.bounds.height + 4)
            : NSPoint(x: 0, y: -4)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }

    /// 初回だけ外部送信の同意を求める。同意済みならそのまま実行する。
    private func requestAgentSummary(_ cli: AgentCLI) {
        if model.settings.agentSummaryConsented {
            runAgentSummary(cli)
        } else {
            confirmingAgentCLI = cli
        }
    }

    private func runAgentSummary(_ cli: AgentCLI) {
        summaryError = nil
        agentSummarizeTask = Task {
            do {
                summary = try await model.generateAgentSummary(for: session, using: cli)
            } catch is CancellationError {
                // ユーザーによるキャンセルなのでエラー表示はしない。
            } catch {
                summaryError = "要約に失敗しました: \(error.localizedDescription)"
            }
            agentSummarizeTask = nil
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
                    .font(HCFont.title3)
            }
            .buttonStyle(.plain)

            Text(formatPlaybackTime(scrubTime ?? player.currentTime))
                .font(HCFont.monospacedDigit(.caption1))
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
                .font(HCFont.monospacedDigit(.caption1))
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

/// SwiftUI の Button からは実体の NSView に直接アクセスできないため、透明な NSView を
/// background に仕込んで実体を取り出す。取り出した NSView は NSMenu.popUp(in:) の
/// アンカーに使う(ボタンの直下にメニューを出すため)。
private struct MenuAnchorView: NSViewRepresentable {
    @Binding var anchor: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // view はビューが階層に載った後でないと座標系が確定しないため1サイクル遅らせる。
        DispatchQueue.main.async { anchor = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// NSMenuItem の target/action を SwiftUI のクロージャに橋渡しする。NSMenuItem は
/// Objective-C のセレクタ経由でしか反応せずクロージャを直接渡せないため、
/// representedObject にクロージャを積み、共通のセレクタから呼び出す。
/// NSMenuItem は target を弱参照するため、呼び出し側(View)がこのインスタンスを
/// @State 等で強参照し続ける必要がある。
final class MenuActionHandler: NSObject {
    func makeItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        return item
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }
}
