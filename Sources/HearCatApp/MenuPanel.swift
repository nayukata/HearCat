import AppKit
import HearCatKit
import SwiftUI

/// GUI の開始ボタンで選べる録音/文字起こしの組み合わせ。
enum SessionStartMode: String, CaseIterable {
    case recordAndTranscribe
    case transcribeOnly
    case recordOnly

    var buttonLabel: String {
        switch self {
        case .recordAndTranscribe: return "録音 ＋ 文字起こしを開始"
        case .transcribeOnly: return "文字起こしを開始"
        case .recordOnly: return "録音を開始"
        }
    }

    var menuLabel: String {
        switch self {
        case .recordAndTranscribe: return "録音 ＋ 文字起こし"
        case .transcribeOnly: return "文字起こしのみ"
        case .recordOnly: return "録音のみ"
        }
    }

    var systemImage: String {
        switch self {
        case .recordAndTranscribe: return "record.circle"
        case .transcribeOnly: return "text.quote"
        case .recordOnly: return "mic"
        }
    }

    var record: Bool { self != .transcribeOnly }
    var transcribe: Bool { self != .recordOnly }
}

/// メニューバーから開くパネル。開始/停止・トグル・入力メーターをここに集約する。
/// (MenuBarExtra の .window スタイルで表示するリッチ版メニュー)
struct MenuPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: AppModel

    /// 「まだ決まっていないこと」カードの中身。UnresolvedDecisionsCard 側に
    /// .task を置くと、初期状態(pendingDecisions 空)では Group が EmptyView に
    /// 解決され、EmptyView に付いた .task/.onAppear は発火しないため
    /// 一度も読み込みが走らない(実機で再現済み)。activeSection の外側 VStack は
    /// セッション中は必ず実体を持つため、ここに .task を置いて確実に発火させる。
    @State private var pendingDecisions: [PendingDecision] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if !model.healthIssues.isEmpty {
                healthBannerSection
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            divider
            Group {
                if model.status.active {
                    activeSection
                } else {
                    idleSection
                }
            }
            .padding(14)
            if let error = model.lastError {
                divider
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(HCFont.caption)
                    .foregroundStyle(.orange)
                    // MenuBarExtra(.window) は中身の理想サイズで窓の高さを決めるため、
                    // 理想 1 行の Text は折り返されず末尾が省略される。縦だけ実寸で確保する。
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            divider
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 300)
        .background(HCColor.panel)
        .tint(HCColor.accent)
        .background(WindowAccessor { window in
            model.adoptPanelWindow(window)
        })
        // initial: true で初回表示から流し込む。窓の解決(WindowAccessor は非同期)と
        // どちらが先でも、モデル側で最後の値が適用される。
        .onChange(of: colorScheme, initial: true) { _, scheme in
            model.panelSchemeChanged(isDark: scheme == .dark)
        }
    }

    private var divider: some View {
        Rectangle().fill(HCColor.lift(0.1)).frame(height: 1)
    }

    // MARK: - ヘッダー

    private var header: some View {
        HStack(spacing: 9) {
            // マークが塗り1枚になったので、稼働中と待機の差は明度で付ける。
            HCLogoShape()
                .fill(
                    model.status.active ? HCColor.textPrimary : HCColor.textDim,
                    style: FillStyle(eoFill: true))
                .frame(width: 17, height: 17)
            Text("HearCat")
                .font(HCFont.brand)
                .foregroundStyle(HCColor.textPrimary)
            Spacer()
            if model.status.active, let startedAt = model.status.startedAt {
                // 経過時間。Text(_:style: .timer) が毎秒勝手に進んでくれる。
                Text(startedAt, style: .timer)
                    .font(HCFont.monospacedDigit(.subheadline))
                    .foregroundStyle(HCColor.textDim)
            } else {
                Text("待機中")
                    .font(HCFont.subheadline)
                    .foregroundStyle(HCColor.textDim)
            }
        }
    }

    // MARK: - 異常バナー

    /// 進行中の異常をすべて縦に並べる。複数同時にあり得るので個別に畳む/消せる。
    private var healthBannerSection: some View {
        VStack(spacing: 8) {
            ForEach(model.healthIssues) { issue in
                HealthIssueBanner(
                    issue: issue,
                    isCollapsed: model.collapsedHealthIssues.contains(issue.kind),
                    onToggleCollapsed: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            model.toggleHealthIssueCollapsed(issue)
                        }
                    },
                    onDismiss: { model.dismissHealthIssue(issue) })
            }
        }
    }

    // MARK: - 待機中

    private var idleSection: some View {
        VStack(spacing: 10) {
            if let recent = model.recentlyEndedSession {
                recentSessionCard(recent)
            }
            startButtonRow
            savingDestinationRow
        }
        .disabled(model.busy)
    }

    /// 大きい開始ボタン(前回選んだモードを反映)+ モード切替。
    /// この環境は Tab キーがボタンに止まらない設定のため、モードの選択肢一覧は
    /// 自前のカスタム UI で組まず、NSMenu 裏付けの Menu にする。
    private var startButtonRow: some View {
        let mode = model.settings.lastSessionStartMode
        return HStack(spacing: 6) {
            Button {
                Task { await model.startSession(record: mode.record, transcribe: mode.transcribe) }
            } label: {
                Label(mode.buttonLabel, systemImage: mode.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hcPrimaryLarge)

            Menu {
                ForEach(SessionStartMode.allCases, id: \.self) { candidate in
                    Button(candidate.menuLabel) {
                        model.settings.lastSessionStartMode = candidate
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.button)
            .buttonStyle(.hcSecondary)
            .help("開始する内容を選ぶ")
        }
    }

    /// 直前に終わったセッションへ戻るための行。停止したあと画面上では何も起きないため、
    /// 記録の終わりと「見返す」入口をここで繋ぐ。要約は停止から少し遅れて出来上がるので、
    /// 出来上がるまでは作成中であることを見せて、待てば要約が出ることを伝える。
    private func recentSessionCard(_ session: SessionInfo) -> some View {
        let awaitingSummary = model.isAwaitingSummary(session)
        let hasSummary = session.summaryURL != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("直前のセッション")
                Spacer()
                Text(session.startDate.formatted(date: .omitted, time: .shortened))
            }
            .font(HCFont.caption)
            .foregroundStyle(HCColor.textDim)

            Text(session.name.isEmpty ? SessionRow.untitledPlaceholder : session.name)
                .font(HCFont.style(.callout, weight: .semibold))
                .foregroundStyle(HCColor.textPrimary)
                .lineLimit(1)

            if awaitingSummary {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("要約を作成中")
                }
                .font(HCFont.caption)
                .foregroundStyle(HCColor.textDim)
            }

            Button {
                model.showHistory(selecting: session.id)
            } label: {
                Label(
                    hasSummary ? "要約を見る" : "文字起こしを見る",
                    systemImage: hasSummary ? "list.bullet.rectangle" : "text.quote")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hcSecondary)
        }
        .padding(10)
        .background(
            HCRadius.shape(HCRadius.card)
                .fill(HCColor.lift(0.06)))
    }

    /// 開始するセッションを入れるグループの選択。表示は「次のセッションが入る先」で、
    /// 保存先グループの確認・切替と資料フォルダ誘導を1行にまとめた控えめな行。
    /// 開始ボタンが主役なので、キャプション調のフォント・薄い色で脇役として添える。
    private var savingDestinationRow: some View {
        HStack(spacing: 4) {
            Text("保存先: ")
                .foregroundStyle(HCColor.textDim)

            // グループ名だけ本文色にして押せることを示す。この環境は Tab キーが
            // ボタンに止まらない設定のため、選択肢一覧は自前で組まず NSMenu 裏付けの
            // Menu にする(startButtonRow のモード切替と同じ理由)。
            Menu {
                // 素の Button の羅列だと選択中の印が出ない。Picker を入れ子にして、
                // 選択中項目へのチェックマーク描画をシステムに任せる。
                Picker("グループ", selection: groupBinding) {
                    Text("未分類").tag(String?.none)
                    ForEach(model.folders, id: \.self) { folder in
                        Text(folder).tag(String?.some(folder))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 2) {
                    Text(model.plannedFolder ?? "未分類")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(HCColor.textPrimary)
                // 短いグループ名でも一定の幅を占め、後ろの資料フォルダ誘導の位置が
                // 名前の長さで動かないようにする。
                .frame(minWidth: 60, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            // 標準の矢印はラベル内の手動シェブロン(名前の後ろ)と二重になるため消す。
            // パネル全体の accent tint がラベルへ乗るのも、ここだけ本文色へ戻す。
            .menuIndicator(.hidden)
            .tint(HCColor.textPrimary)
            // 行が狭いときはこのグループ名側から先に縮む(隣の固定文言は保つ)。
            .layoutPriority(-1)
            .pointingHandOnHover()

            if let target = referenceFolderLinkTarget {
                Text("・")
                    .foregroundStyle(HCColor.textDim)
                Button {
                    openReferenceFolderLink(target: target)
                } label: {
                    Text("資料フォルダを紐付ける")
                        .underline(pattern: .dot)
                        // グループ名の最低幅と両立させる。幅が足りない極端な場面でも
                        // 2 行に折り返さず 1 行を維持する。
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .foregroundStyle(HCColor.textDim)
            }
        }
        .font(HCFont.caption)
        // 行を左端に固定する。固定しないと VStack の中央寄せになり、グループ名の
        // 長さやリンクの有無で幅が変わるたびに行全体の位置がずれる。
        .frame(maxWidth: .infinity, alignment: .leading)
        // 今の予定に紐づくグループへ選択を寄せる。会議が始まっているのに
        // 前回のグループのままだと、そのまま開始して別のグループへ入ってしまう。
        .task {
            await model.syncGroupSelectionWithCurrentEvent()
            // 起動直後に検出が失敗していた場合の取り戻し(検出済みなら何もしない)。
            AgentCLIDetector.shared.detectIfNeeded()
        }
    }

    private var groupBinding: Binding<String?> {
        Binding(
            get: { model.plannedFolder },
            set: { model.selectFolder($0) })
    }

    /// 資料フォルダ紐付けの誘導を押した時の遷移先。既にグループを選んでいれば
    /// そのグループへ紐付けるだけ、「未分類」ならフォルダ選択から新規グループを作る
    /// (グループ機能を使っていないユーザーもこの導線に出会えるようにするため)。
    private enum ReferenceFolderLinkTarget {
        case existingGroup(String)
        case newGroupFromUnclassified
    }

    /// 資料フォルダの紐付けを勧める余地があるか。既に紐付け済みのグループでは出さない。
    /// エージェント CLI(claude/codex)がどちらも未検出なら紐付けても実益が無いため、
    /// 意味の無い項目を出さない(MainWindow.swift の同種の判定と同じ扱い)。
    private var referenceFolderLinkTarget: ReferenceFolderLinkTarget? {
        guard !AgentCLIDetector.shared.availableCLIs.isEmpty else { return nil }
        guard let folder = model.plannedFolder else {
            return .newGroupFromUnclassified
        }
        return model.settings.referenceFolders[folder] == nil ? .existingGroup(folder) : nil
    }

    /// 資料フォルダ誘導を押した時の遷移。このパネルはフォーカスが移ると閉じるため、
    /// パネルの親にはできない。貼り付け先を渡さず、FilePanel 側の保険
    /// (今フォーカスのあるスクリーンへ寄せる)に委ねる。
    private func openReferenceFolderLink(target: ReferenceFolderLinkTarget) {
        switch target {
        case .existingGroup(let folder):
            Task { await ReferenceFolderPicker.pick(forGroup: folder, from: nil) }
        case .newGroupFromUnclassified:
            // 選んだフォルダから新規グループを作り、次回からの既定グループにする。
            Task {
                guard let folder = await ReferenceFolderPicker.pickForNewGroup(from: nil)
                else { return }
                model.selectFolder(folder)
                model.refreshSessions()
            }
        }
    }

    // MARK: - セッション中

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 保存先グループはセッション中に変えられないため、確認のためだけに出す。
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(model.activeSessionFolder ?? "未分類")
            }
            .font(HCFont.caption)
            .foregroundStyle(HCColor.textDim)

            if let folder = model.activeSessionFolder, !pendingDecisions.isEmpty {
                UnresolvedDecisionsCard(
                    model: model, folder: folder, pendingDecisions: pendingDecisions)
            }

            toggleRow("録音", isOn: recordingBinding)
            toggleRow("文字起こし", isOn: transcribingBinding)

            VStack(alignment: .leading, spacing: 6) {
                meterRow(label: "自分", level: model.micLevel)
                if model.status.systemAudioError == nil {
                    meterRow(label: "相手", level: model.systemLevel)
                }
            }
            .padding(.top, 2)

            if model.status.systemAudioError != nil {
                Label("相手の音声: 取得できていません", systemImage: "speaker.slash")
                    .font(HCFont.caption)
                    .foregroundStyle(.orange)
                    .help(model.status.systemAudioError ?? "")
            }

            Button {
                model.openCodeImpactPanel()
            } label: {
                Label("会話について AI に質問", systemImage: "text.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hcSecondary)
            .disabled(!model.status.transcribing)

            Button(role: .destructive) {
                Task { await model.stopSession() }
            } label: {
                Label("セッションを停止", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hcSecondary)
            .disabled(model.busy)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        // body は状態変化のたびに再評価されるため、decisions.json の読み込みは
        // ここへ切り出し、.task(id:) で folder が変わった時だけ読んで @State に保つ
        // (body 内で毎回ディスクを読まない)。セッション中に決定記録が変わる頻度は
        // 低いため、パネルを開き直した時に読み直せば十分で、ファイル監視までは行わない。
        .task(id: model.activeSessionFolder) {
            guard let folder = model.activeSessionFolder else {
                pendingDecisions = []
                return
            }
            let log = DecisionLogStore.loadOrEmpty(folder: folder)
            pendingDecisions = log.unresolvedTopics().compactMap { topic in
                topic.current.map { PendingDecision(topic: topic, current: $0) }
            }
        }
    }

    /// ラベル左・スイッチ右端のトグル行。スイッチの縦の列を揃える。
    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .pointingHandOnHover()
        }
    }

    private func meterRow(label: String, level: Float) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(HCFont.caption)
                .foregroundStyle(HCColor.textDim)
                .frame(width: 28, alignment: .leading)
            LevelMeter(level: level)
        }
    }

    // MARK: - フッター

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.showHistory()
            } label: {
                Label("履歴", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
            }
            Button {
                model.showSettings()
            } label: {
                Label("設定", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            // 終了は誤クリック1回で押されないよう、他の操作と同列には置かず
            // メニューの奥(NSMenu 裏付けの Menu)に隔離する。
            Menu {
                Button("HearCat を終了", role: .destructive) {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
        }
        .buttonStyle(.hcSecondary)
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

/// 議題1件ぶんの表示用の中間形。DecisionTopic.current は Optional なので、
/// 「current が無い(=history 空)議題は未決の対象にならない」を読み込み時点で
/// 確定させ、行の描画側では force unwrap しなくて済むようにする。
///
/// 読み込み(MenuPanel.activeSection の .task)と表示(UnresolvedDecisionsCard)の
/// 両方から参照するため、MenuPanel 直下の fileprivate な型として置く。
fileprivate struct PendingDecision: Identifiable {
    let topic: DecisionTopic
    let current: DecisionEntry
    var id: String { topic.id }
}

/// 「開始 30 秒ブリーフ」。セッション中、その保存先グループに未決(保留/仮)の議題が
/// 残っている場合だけ、活動セクションの折り込みグループ行の直下に出す。会議に入ってすぐ
/// 「前回までに決まっていないこと」を思い出せるようにするための入口で、経緯そのものは
/// ここでは見せず、履歴ウィンドウの「決まったこと」タブへ委ねる。
///
/// 表示専用のビュー。decisions.json の読み込みは MenuPanel.activeSection 側の
/// .task(id:) で行い、結果をここへ引数で渡す(このビュー自身に .task を持たせると、
/// 初期状態で pendingDecisions が空 → 呼び出し側の Group が EmptyView に解決され、
/// EmptyView に付いた .task/.onAppear は発火しない罠を踏む)。
private struct UnresolvedDecisionsCard: View {
    let model: AppModel
    let folder: String
    let pendingDecisions: [PendingDecision]

    private static let maxVisibleRows = 3

    var body: some View {
        card
    }

    private var card: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                PawPrintShape()
                    .fill(HCColor.accent)
                    .frame(width: 12, height: 12)
                Text("まだ決まっていないこと")
                    .font(HCFont.style(.subheadline, weight: .bold))
                    .foregroundStyle(HCColor.textDim)
                Spacer()
            }

            VStack(spacing: 6) {
                ForEach(pendingDecisions.prefix(Self.maxVisibleRows)) { decision in
                    topicRow(decision)
                }
            }

            if pendingDecisions.count > Self.maxVisibleRows {
                Text("ほか \(pendingDecisions.count - Self.maxVisibleRows) 件")
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                model.showHistory(selecting: MainWindow.groupSelectionTag(folder))
            } label: {
                Text("経緯を開く")
                    .font(HCFont.callout)
                    .foregroundStyle(HCColor.accentText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        }
        .padding(10)
        .background(
            HCRadius.shape(HCRadius.card)
                .fill(HCColor.lift(0.06)))
    }

    private func topicRow(_ decision: PendingDecision) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(decision.topic.title)
                .font(HCFont.callout)
                .foregroundStyle(HCColor.textBody)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(decision.current.text)
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                DecisionStatusChip(status: decision.current.status)
                Text(HCDate.list.string(from: decision.current.recordedAt))
                    .font(HCFont.monospacedDigit(.caption1))
                    .foregroundStyle(HCColor.textDim)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

/// 入力レベル(RMS)を dB に直して出す横バー。
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(HCColor.lift(0.12))
                Capsule().fill(HCColor.accent)
                    .frame(width: max(0, geo.size.width * normalized))
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.1), value: level)
    }

    /// RMS を -60dB〜0dB のレンジで 0〜1 に写す(耳の感覚に近い対数スケール)。
    private var normalized: CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(level)
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }
}
