import AppKit
import HearCatKit
import SwiftUI
import os

/// decisions.json の読み書き失敗を残すための内部ログ。SessionDetailView 側の
/// decisionInspectionLogger と同じ category にして、決定事項まわりの失敗をまとめて追える
/// ようにする(ファイルは分けているが、原因の種類は同じ「検品操作の読み書き失敗」のため)。
private let groupDetailLogger = Logger(
    subsystem: SessionStore.bundleIdentifier, category: "decision-inspection")

/// グループ画面。サイドバーでグループの行名をクリックすると開く(MainWindow.swift の
/// groupSelectionTag を選択した時の detail)。「セッション」「決まったこと」の2タブを持つ。
struct GroupDetailView: View {
    let model: AppModel
    let folder: String
    /// セッションタブで行を選ぶと、親(MainWindow)の selection をそのセッションへ切り替える。
    let onSelectSession: (String) -> Void

    private enum Tab: String, CaseIterable {
        case sessions = "セッション"
        case decisions = "決まったこと"
    }

    // 既定は「決まったこと」。決定事項の記録を見返す方が主目的の画面のため。
    @State private var selectedTab: Tab = .decisions

    @State private var decisionLog: DecisionLog = .empty
    @State private var searchText = ""
    /// nil = すべて。
    @State private var statusFilter: DecisionStatus?
    @State private var showArchived = false
    @State private var expandedTopicIDs: Set<String> = []

    /// バックフィルの初回同意ダイアログの対象 CLI。SessionDetailView の
    /// confirmingAgentCLI と同じ役割・同じ体裁。
    @State private var confirmingBackfillCLI: AgentCLI?
    @State private var backfillMenuAnchor: NSView?
    @State private var backfillMenuActionHandler = MenuActionHandler()

    /// TopicRow の手動記録ボタンから開くシートの対象。
    @State private var manualConfirmTarget: ManualEntrySheetTarget?

    private var groupSessions: [SessionInfo] {
        model.sessions.filter { $0.folder == folder }.sorted { $0.startDate > $1.startDate }
    }

    private var availableAgentCLIs: [AgentCLI] {
        AgentCLIDetector.shared.availableCLIs
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            switch selectedTab {
            case .sessions:
                sessionsTabContent
            case .decisions:
                decisionsTabContent
            }
        }
        .task(id: folder) { reloadDecisions() }
        .onChange(of: model.sessionsVersion) { reloadDecisions() }
        .onChange(of: model.decisionBackfillProgress) { reloadDecisions() }
        // グループが切り替わったら、前のグループの検索・展開・フィルタを持ち越さない。
        .onChange(of: folder) {
            searchText = ""
            statusFilter = nil
            showArchived = false
            expandedTopicIDs = []
        }
        .confirmationDialog(
            "この操作は文字起こしを外部の AI サービスへ送信します。続けますか？",
            isPresented: Binding(
                get: { confirmingBackfillCLI != nil },
                set: { if !$0 { confirmingBackfillCLI = nil } }),
            presenting: confirmingBackfillCLI
        ) { cli in
            Button("続ける") {
                model.settings.agentSummaryConsented = true
                model.startDecisionBackfill(folder: folder, using: cli)
            }
            Button("キャンセル", role: .cancel) {}
        }
        .sheet(item: $manualConfirmTarget) { target in
            ManualConfirmSheet(topic: target.topic) { text in
                try appendManualEntry(topicID: target.topic.id, text: text, status: .confirmed)
            }
        }
    }

    // MARK: - ヘッダー

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(folder, systemImage: "folder")
                    .font(HCFont.headline)
                Spacer()
            }
            summaryRow
        }
        .padding()
    }

    /// 概要行。「・」区切りをやめ、HStack の余白だけで項目を分ける。パスは他の項目より
    /// 長くなり得るため、幅が足りない場面ではパスだけが縮んで中央省略されるように
    /// layoutPriority を他より下げる(件数・期間は常にフル表示のまま)。
    private var summaryRow: some View {
        HStack(spacing: 15) {
            if let path = model.settings.referenceFolders[folder] {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            Text("セッション \(groupSessions.count) 件")
                .fixedSize()
            Text("議題 \(activeTopicCount) 件")
                .fixedSize()
            if let period = periodText {
                Text(period)
                    .fixedSize()
            }
        }
        .font(HCFont.caption)
        .foregroundStyle(.secondary)
    }

    /// アーカイブを除いた議題の総数。ヘッダーの概要行に出す(フィルタチップの件数とは別に、
    /// 「このグループに今何件あるか」をアーカイブ表示状態によらず固定で見せるため)。
    private var activeTopicCount: Int {
        decisionLog.topics.filter { $0.archivedAt == nil }.count
    }

    private var periodText: String? {
        let dates = groupSessions.map(\.startDate)
        guard let oldest = dates.min(), let newest = dates.max() else { return nil }
        let style = Date.FormatStyle.dateTime.year().month().day()
        if Calendar.current.isDate(oldest, inSameDayAs: newest) {
            return oldest.formatted(style)
        }
        return "\(oldest.formatted(style)) 〜 \(newest.formatted(style))"
    }

    // MARK: - タブ切り替え

    /// SwiftUI 標準の Picker(.segmented) ではなくボタン列にしているのは、
    /// アプリの他所(要約・共有ボタン等)と同じ HCSecondaryButtonStyle / cinnamon の
    /// トーンに揃えるため(標準セグメントは灰色でここだけ浮く)。
    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases, id: \.self) { tab in
                if selectedTab == tab {
                    Button(tab.rawValue) { selectedTab = tab }
                        .buttonStyle(.hcPrimary)
                        .controlSize(.small)
                } else {
                    Button(tab.rawValue) { selectedTab = tab }
                        .buttonStyle(.hcSecondary)
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - セッションタブ

    private var sessionsTabContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupSessions) { session in
                    Button {
                        onSelectSession(session.id)
                    } label: {
                        SessionRow(session: session, sessionsVersion: model.sessionsVersion)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    if session.id != groupSessions.last?.id {
                        Divider()
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - 決まったことタブ

    /// 検索語・状態フィルタ・アーカイブ表示を1回だけ解決した結果。decisionsToolbar /
    /// decisionsList の両方がこれを参照するだけにし、body 評価のたびに同じ絞り込み・並び替えを
    /// 何度も走らせない(DecisionLog.filterTopics 参照)。
    private var decisionsTabContent: some View {
        let filterResult = decisionLog.filterTopics(
            query: searchText, status: statusFilter, showArchived: showArchived)
        return VStack(alignment: .leading, spacing: 0) {
            decisionsToolbar(filterResult)
            Divider()
            if decisionLog.topics.isEmpty {
                emptyDecisionsState
            } else {
                decisionsList(filterResult)
            }
            Divider()
            backfillSection
                .padding()
        }
    }

    private func decisionsToolbar(_ result: DecisionTopicFilterResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("議題名や現在の内容で検索", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(HCRadius.shape(HCRadius.control).fill(Color.primary.opacity(0.05)))

            HStack(spacing: 6) {
                FilterChip(title: "すべて", count: result.visibleCount, isSelected: statusFilter == nil) {
                    statusFilter = nil
                }
                ForEach(DecisionStatus.allCases, id: \.self) { status in
                    FilterChip(
                        title: status.displayName, count: result.statusCounts[status] ?? 0,
                        isSelected: statusFilter == status
                    ) {
                        statusFilter = status
                    }
                }
                Spacer()
                // アーカイブの件数は showArchived の状態に関わらず「アーカイブ済み議題数」を
                // 常に示す(他のチップは今表示中のスコープの内訳、これだけは切替先の件数)。
                FilterChip(title: "アーカイブ", count: decisionLog.archivedTopicCount, isSelected: showArchived) {
                    showArchived.toggle()
                }
            }
        }
        .padding()
    }

    private var emptyDecisionsState: some View {
        // checkmark 系は「完了済み」に誤読されるため、中立なリスト系のアイコンにする。
        ContentUnavailableView(
            "まだ記録がありません",
            systemImage: "list.bullet.rectangle",
            description: Text("会話を Claude / Codex で要約するか、下のボタンで過去の会話から取り込めます。"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func decisionsList(_ result: DecisionTopicFilterResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if result.filtered.isEmpty {
                    Text("条件に一致する議題がありません")
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    let recentlyMovedIDs = Set(result.recentlyMoved.map(\.id))
                    let hasRecentlyMoved = !result.recentlyMoved.isEmpty
                    if hasRecentlyMoved {
                        section(title: "前回の会話で決まった・変わったこと", topics: result.recentlyMoved)
                    }
                    // 上のセクションと同じ議題を下に重複させないため、recentlyMoved に
                    // 含まれる議題を除外する(DecisionLog.filterTopics 側は変えず View 側で除く)。
                    let rest = result.sorted.filter { !recentlyMovedIDs.contains($0.id) }
                    if !rest.isEmpty {
                        section(title: hasRecentlyMoved ? "そのほかの議題" : "すべての議題", topics: rest)
                    }
                }
            }
            .padding()
        }
    }

    private func section(title: String, topics: [DecisionTopic]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(HCFont.style(.subheadline, weight: .bold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(topics, id: \.id) { topic in
                    TopicRow(
                        topic: topic,
                        isExpanded: expandedTopicIDs.contains(topic.id),
                        onToggleExpand: { toggleExpanded(topic.id) },
                        onJump: { jumpToEntry($0) },
                        onToggleArchive: { toggleArchive(topic) },
                        onManualConfirm: { manualConfirmTarget = ManualEntrySheetTarget(topic: topic) })
                    if topic.id != topics.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - バックフィル(過去の会議から取り込む)

    /// このグループの未取り込みセッション数。decisionLog(既に reloadDecisions() で読み込み済み)の
    /// extractedSessionDirectories に無い groupSessions を数える。この画面はグループを選んだ時点で
    /// 既に decisionLog を読んでいるため、backfillSection の表示のたびに decisions.json を
    /// 読み直さないよう、ここでは既に読み込んだ decisionLog だけから計算する。
    private var pendingBackfillCount: Int {
        let extracted = Set(decisionLog.extractedSessionDirectories)
        return groupSessions.filter { !extracted.contains($0.directory.lastPathComponent) }.count
    }

    @ViewBuilder
    private var backfillSection: some View {
        if let progress = model.decisionBackfillProgress, model.decisionBackfillFolder == folder {
            if progress.completed < progress.total {
                HStack(spacing: 10) {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .frame(maxWidth: 160)
                    Text(
                        "取り込み中… \(progress.completed)/\(progress.total)"
                            + (progress.currentSessionName.map { " (\($0))" } ?? "")
                    )
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("キャンセル") { model.cancelDecisionBackfill() }
                        .buttonStyle(.hcSecondary)
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 10) {
                    Label("取り込み完了", systemImage: "checkmark.circle")
                        .font(HCFont.caption)
                        .foregroundStyle(.secondary)
                    if !progress.failedSessions.isEmpty {
                        Text("(\(progress.failedSessions.count) 件は取り込めませんでした)")
                            .font(HCFont.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
        } else {
            let pending = pendingBackfillCount
            HStack {
                if pending > 0 {
                    Button {
                        presentBackfillMenu()
                    } label: {
                        Label("過去の会話から取り込む (\(pending) 件)", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.hcSecondary)
                    .disabled(availableAgentCLIs.isEmpty)
                    .help(
                        availableAgentCLIs.isEmpty
                            ? "Claude または Codex が見つかりません" : "")
                    .background(MenuAnchorView(anchor: $backfillMenuAnchor))
                } else {
                    Label("過去の会話は取り込み済み", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(HCFont.callout)
                }
                Spacer()
            }
        }
    }

    private func presentBackfillMenu() {
        guard let anchor = backfillMenuAnchor else { return }
        let menu = makeHCMenu()
        for cli in availableAgentCLIs {
            menu.addItem(
                backfillMenuActionHandler.makeItem("\(cli.displayName) で取り込む") {
                    requestBackfill(cli)
                })
        }
        popUpMenu(menu, below: anchor)
    }

    private func requestBackfill(_ cli: AgentCLI) {
        if model.settings.agentSummaryConsented {
            model.startDecisionBackfill(folder: folder, using: cli)
        } else {
            confirmingBackfillCLI = cli
        }
    }

    // MARK: - 操作

    private func toggleExpanded(_ topicID: String) {
        if expandedTopicIDs.contains(topicID) {
            expandedTopicIDs.remove(topicID)
        } else {
            expandedTopicIDs.insert(topicID)
        }
    }

    private func reloadDecisions() {
        do {
            decisionLog = try DecisionLogStore.load(folder: folder)
        } catch {
            groupDetailLogger.error(
                "decisions.json の読み込みに失敗: \(error.localizedDescription, privacy: .public)")
            decisionLog = .empty
        }
    }

    private func toggleArchive(_ topic: DecisionTopic) {
        do {
            try DecisionLogStore.setArchived(
                folder: folder, topicID: topic.id, archived: topic.archivedAt == nil)
        } catch {
            groupDetailLogger.error(
                "アーカイブの切り替えに失敗: \(error.localizedDescription, privacy: .public)")
        }
        reloadDecisions()
    }

    /// 変遷の時刻チップから、そのエントリの由来セッションを選び、文字起こしの該当位置まで
    /// ジャンプする。セッションの解決とジャンプ本体は AppModel.postDecisionEntryReveal に
    /// 共通化している(AppModel.revealDecisionEntry と同じ処理)。
    private func jumpToEntry(_ entry: DecisionEntry) {
        guard let session = model.postDecisionEntryReveal(entry, folder: folder) else { return }
        onSelectSession(session.id)
    }

    /// 「決まった…」シートの確定。会話の外(Slack・PR レビュー等)で決着した内容を、
    /// DecisionEntry.origin == .manual のエントリとして追加する。失敗はログに残したうえで
    /// 呼び出し元(シート)へ投げ返し、シート側でメッセージとして出す(黙って失敗させない)。
    private func appendManualEntry(
        topicID: String, text: String, status: DecisionStatus
    ) throws {
        do {
            try DecisionLogStore.appendManualEntry(
                folder: folder, topicId: topicID, text: text, status: status)
        } catch {
            groupDetailLogger.error(
                "手動記録の追加に失敗: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        reloadDecisions()
    }
}

/// TopicRow の手動記録ボタンから開くシートの対象。DecisionTopic は Identifiable ではないため、
/// .sheet(item:) に渡す薄いラッパー。
private struct ManualEntrySheetTarget: Identifiable {
    let topic: DecisionTopic
    var id: String { topic.id }
}

/// 「決まった…」シート。会話の外で決着した内容を、その場で手動記録する。
/// DecisionEditSheet(DecisionBlock.swift)と同じ「見出し + 入力 + 右下ボタン列」の構成に倣う。
private struct ManualConfirmSheet: View {
    let topic: DecisionTopic
    let onSave: (_ text: String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var errorMessage: String?

    init(topic: DecisionTopic, onSave: @escaping (_ text: String) throws -> Void) {
        self.topic = topic
        self.onSave = onSave
        _text = State(initialValue: topic.current?.text ?? "")
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(topic.title)
                .font(HCFont.headline)
            TextField("内容", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            if let errorMessage {
                Text(errorMessage)
                    .font(HCFont.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .buttonStyle(.hcSecondary)
                Button("確定") {
                    do {
                        try onSave(trimmedText)
                        dismiss()
                    } catch {
                        errorMessage = "記録できませんでした。もう一度お試しください。"
                    }
                }
                .buttonStyle(.hcPrimary)
                .disabled(trimmedText.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

/// 状態フィルタ・アーカイブトグルに使う小さなチップボタン。選択中は cinnamon 塗り、
/// 非選択は控えめな面。primary/secondary ボタンと同じトーンに揃える。
private struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // 日本語と半角数字の間には半角スペースを入れる(「すべて 12」)。
            Text("\(title) \(count)")
                .font(HCFont.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isSelected ? HCColor.mistDark : .secondary)
                .background(Capsule().fill(isSelected ? HCColor.cinnamon : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }
}

/// 議題1件の行。折りたたみ時は現在の状態だけ、展開すると history を時系列(昇順)で見せる。
private struct TopicRow: View {
    let topic: DecisionTopic
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onJump: (DecisionEntry) -> Void
    let onToggleArchive: () -> Void
    let onManualConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .font(HCFont.caption)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.title)
                        .font(HCFont.style(.body, weight: .semibold))
                    // 展開中は鎖の最新版(太字+琥珀の点)が「現在」を兼ねるため、折りたたみ時
                    // だけこの1行を出す(展開したまま出すと、履歴1件の議題では同じ文章が
                    // 2回並んで見えていた)。
                    if !isExpanded, let current = topic.current {
                        Text(current.text)
                            .font(HCFont.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                // 右端列(チップ・日付・アーカイブボタン)をひとまとめにして中央揃えにする。
                // 親の HStack は先頭合わせ(alignment: .top、chevron を1行目の高さに揃えるため)
                // なので、ここに .frame(maxHeight: .infinity) を付けて親の行高いっぱいに広げ、
                // 中の要素は HStack 既定の中央揃えで縦に揃える(以前は行の上に浮いて見えていた)。
                HStack(spacing: 8) {
                    if let status = topic.current?.status {
                        // 固定幅で縦に整列させる(「仮」1文字と「確定」2文字で幅が揺れないように)。
                        DecisionStatusChip(status: status)
                            .frame(width: 48, alignment: .center)
                    }
                    if let recordedAt = topic.current?.recordedAt {
                        Text(HCDate.list.string(from: recordedAt))
                            .font(HCFont.monospacedDigit(.caption1))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    archiveButton
                    manualConfirmButton
                }
                .frame(maxHeight: .infinity)
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }

            if isExpanded {
                historySection
            }
        }
        .padding(.vertical, 8)
    }

    /// 変遷の鎖(タイムライン)。各版を破線レール+肉球の足あとで繋ぐ。新しい順に並べ、
    /// 最上段(=最新版)を「いまここ」として強調する。最後の版はレールを下に伸ばさない。
    /// 1件しかない議題も同じ様式(足あと1つ・レール無し)で出す。
    /// 描画本体は DecisionTimelineView に共通化している(質問応答パネルの経緯回答カードと
    /// 同じ部品。見た目はこの画面のものを正としてそちらへ合わせた)。
    private var historySection: some View {
        DecisionTimelineView(
            history: topic.history,
            currentTextColor: .primary, pastTextColor: .secondary
        ) { entry in
            entryMetaRow(entry)
        }
        .padding(.leading, 20)
        .padding(.top, 6)
    }

    /// 本文の下に分けたメタ行: 状態チップ・日付(ゼロ埋め等幅)・entry.sourceLabel・時刻チップ
    /// (既存のジャンプボタンをそのまま使う)・理由(あれば「— 理由」で同じ行に添える)。
    /// 手動記録の reason は「どこで決まったか」であって変更理由ではないため、entry.sourceLabel
    /// (DecisionTimelineView.swift 末尾の拡張)側に委ね、通常の「— 理由」表示とは重複させない。
    /// timeSeconds も手動記録では常に nil なので、時刻ジャンプは既存の条件分岐のまま自然に出ない。
    private func entryMetaRow(_ entry: DecisionEntry) -> some View {
        HStack(spacing: 4) {
            DecisionStatusChip(status: entry.status)
            Text(HCDate.list.string(from: entry.recordedAt))
                .font(HCFont.monospacedDigit(.caption1))
            Text(entry.sourceLabel)
            if let timeSeconds = entry.timeSeconds {
                Text("·")
                Button(formatPlaybackTime(TimeInterval(timeSeconds))) { onJump(entry) }
                    .buttonStyle(.plain)
                    .font(HCFont.timecode)
                    .foregroundStyle(.tint)
                    .pointingHandOnHover()
                    .help("この位置から文字起こしへ移動")
            }
            if !entry.isManual, let reason = entry.reason, !reason.isEmpty {
                Text("— \(reason)")
            }
        }
        .font(HCFont.caption)
        .foregroundStyle(.secondary)
    }

    /// アーカイブの切り替えをワンボタンにする。中身がアーカイブ1つしか無いメニューは
    /// 回り道でしかない(以前は「⋯」→ NSMenu 経由だった)ため、直接のボタンにした。
    /// アイコンの見た目は 12〜14pt 程度だが、クリック判定は .frame + .contentShape で
    /// 24x24pt 相当まで広げる(小さすぎて押せない、という指摘への対応)。
    /// 行全体の .onTapGesture(展開)とはボタンの当たり判定内で確実に競合しない
    /// (SwiftUI は Button 自身のヒットテストを外側の onTapGesture より優先する)。
    private var archiveButton: some View {
        let isArchived = topic.archivedAt != nil
        return Button {
            onToggleArchive()
        } label: {
            Image(systemName: isArchived ? "tray.and.arrow.up" : "archivebox")
                .imageScale(.small)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .pointingHandOnHover()
        .help(isArchived ? "アーカイブから戻す" : "アーカイブする")
    }

    /// 会話の外(Slack・PR レビュー等)で決着した議題を手動で記録する入口。
    /// DecisionEntry.origin == .manual のエントリを追加する UI はここだけ
    /// (データ層の DecisionLogStore.appendManualEntry 自体は既に実装済み)。
    /// archiveButton と同じ「直接ボタン + 24x24pt のクリック判定」の作りに揃える。
    private var manualConfirmButton: some View {
        Button {
            onManualConfirm()
        } label: {
            Image(systemName: "checkmark.circle")
                .imageScale(.small)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .pointingHandOnHover()
        .help("決まったことを手動で記録")
    }
}
