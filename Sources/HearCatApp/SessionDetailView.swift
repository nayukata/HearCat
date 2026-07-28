import AppKit
import HearCatKit
import HearCatSummarize
import SwiftUI

/// 過去セッションの詳細。文字起こしの閲覧、録音の再生、要約の生成、削除ができる。
struct SessionDetailView: View {
    let model: AppModel
    let session: SessionInfo
    let onDelete: () -> Void
    /// 資料フォルダ紐付けで未分類のセッションを新規グループへ移した後、移動後の ID を
    /// 親(MainWindow)へ伝える。session は let で不変なため、このビュー自身は移動後の
    /// パスへ追従できない。親が選択をこの ID へ張り替え、.id(session.id) で
    /// ビューごと作り直すことで、以後の表示や要約生成が新しいパスを向くようにする。
    let onMove: (String) -> Void

    @State private var transcript: String?
    @State private var transcriptLines: [TranscriptLine] = []
    @State private var summary: String?
    /// 要約を生成したエンジン。エンジン情報の無い過去の要約(この機能より前に生成)は nil のまま。
    @State private var summaryEngine: SummaryEngine?
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
        // ヘッダー内のボタンは既定の透明背景 + tint 色のテキストだと、mistDark 上で
        // cinnamon が沈んで読みにくい。.bordered にして「pill 型の tint 背景 + 濃いテキスト」
        // の macOS 標準スタイルに寄せることで、クリック可能領域も明示する。
        // 削除ボタンは role: .destructive を付けているので、.bordered と組み合わせても
        // 破壊的操作特有の赤味が出て他ボタンと差別化される。
        .buttonStyle(.hcSecondary)
        .controlSize(.regular)
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
                            // エンジン情報の無い過去の要約には出さない(推測で埋めない)。
                            if let summaryEngine {
                                EngineChip(engine: summaryEngine)
                            }
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
        summaryEngine = session.summaryEngine
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
        // まだ設定していないグループにはここからも設定できるようにする。未分類のセッションにも
        // 同じ項目を出す(グループ機能を使っていないユーザーもこの導線に出会えるように)。
        // subtitle は macOS 14.4+ で利用可能(このプロジェクトのターゲットは macOS 26)。
        if let target = referenceFolderMenuTarget {
            menu.addItem(.separator())
            // ラベルは機能名(関連フォルダ)でなく効能(要約精度が上がる)で語る
            // (詳細は MainWindow.swift の同種の項目のコメント参照)。
            let referenceFolderItem = summarizeMenuActionHandler.makeItem("資料フォルダと紐付けて要約精度を上げる…") {
                switch target {
                case .existingGroup(let folder):
                    ReferenceFolderPicker.pick(forGroup: folder)
                case .newGroupFromUnclassified:
                    linkToNewGroup()
                }
            }
            referenceFolderItem.subtitle = "会議に関連する資料やコードを Claude / Codex が読み、誤変換の修正や参加者の前提を踏まえた要約になります"
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

    /// 資料フォルダ紐付けの誘導を押した時の遷移先。MenuPanel の同種の型と役割は同じだが、
    /// こちらは「今見ているセッションが所属するグループ」を基準にする。
    private enum ReferenceFolderMenuTarget {
        case existingGroup(String)
        case newGroupFromUnclassified
    }

    /// 資料フォルダの紐付けを勧める余地があるか。所属グループが無ければ新規グループ作成、
    /// あれば既存グループへの紐付け(未紐付けの場合のみ)を案内する。
    private var referenceFolderMenuTarget: ReferenceFolderMenuTarget? {
        guard let folder = session.folder else { return .newGroupFromUnclassified }
        return model.settings.referenceFolders[folder] == nil ? .existingGroup(folder) : nil
    }

    /// 未分類のセッションから資料フォルダを紐付ける。選んだフォルダの名前で新しいグループを
    /// 作り(既存の未紐付けグループがあれば流用)、このセッション自体もそこへ移す。
    private func linkToNewGroup() {
        ReferenceFolderPicker.pickForNewGroup { folder in
            guard let newID = model.move(session, toFolder: folder) else { return }
            onMove(newID)
        }
    }
}

/// 要約を生成したエンジンのバッジ。「この要約はどのエンジンが作ったか」を後から見ても
/// 分かるようにする(表示のたびに現在の設定から推測せず、生成時点に固定した値を出す。
/// 詳細は SummaryEngine のコメント参照)。
private struct EngineChip: View {
    let engine: SummaryEngine

    var body: some View {
        Text(engine.displayName)
            .font(HCFont.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
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
