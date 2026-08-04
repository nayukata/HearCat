import AppKit
import HearCatKit
import SwiftUI

/// メニューバーから開くパネル。開始/停止・トグル・入力メーターをここに集約する。
/// (MenuBarExtra の .window スタイルで表示するリッチ版メニュー)
struct MenuPanel: View {
    let model: AppModel

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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            divider
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 300)
        .background(HCColor.mistDark)
        // パネルは LP と同じネイビー基調で固定する。
        .environment(\.colorScheme, .dark)
        .tint(HCColor.cinnamon)
        .background(WindowAccessor { window in
            model.panelWindow = window
        })
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
    }

    // MARK: - ヘッダー

    private var header: some View {
        HStack(spacing: 9) {
            // マークが塗り1枚になったので、稼働中と待機の差は明度で付ける。
            HCLogoShape()
                .fill(
                    model.status.active ? HCColor.mistWhite : HCColor.mistWhiteDim,
                    style: FillStyle(eoFill: true))
                .frame(width: 17, height: 17)
            Text("HearCat")
                .font(HCFont.brand)
                .foregroundStyle(.white)
            Spacer()
            if model.status.active, let startedAt = model.status.startedAt {
                // 経過時間。Text(_:style: .timer) が毎秒勝手に進んでくれる。
                Text(startedAt, style: .timer)
                    .font(HCFont.monospacedDigit(.subheadline))
                    .foregroundStyle(HCColor.mistWhiteDim)
            } else {
                Text("待機中")
                    .font(HCFont.subheadline)
                    .foregroundStyle(HCColor.mistWhiteDim)
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
            groupPicker
                // 今の予定に紐づくグループへ選択を寄せる。会議が始まっているのに
                // 前回のグループのままだと、そのまま開始して別のグループへ入ってしまう。
                .task {
                    await model.syncGroupSelectionWithCurrentEvent()
                    // 起動直後に検出が失敗していた場合の取り戻し(検出済みなら何もしない)。
                    AgentCLIDetector.shared.detectIfNeeded()
                }
            if let target = referenceFolderLinkTarget {
                referenceFolderHint(target: target)
            }

            Button {
                Task { await model.startSession(record: true, transcribe: true) }
            } label: {
                Label("録音 ＋ 文字起こしを開始", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                Task { await model.startSession(record: false, transcribe: true) }
            } label: {
                Label("文字起こしのみ開始", systemImage: "text.quote")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hcSecondary)
        }
        .disabled(model.busy)
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
            .foregroundStyle(HCColor.mistWhiteDim)

            Text(session.name.isEmpty ? SessionRow.untitledPlaceholder : session.name)
                .font(HCFont.style(.callout, weight: .semibold))
                .foregroundStyle(HCColor.mistWhite)
                .lineLimit(1)

            if awaitingSummary {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("要約を作成中")
                }
                .font(HCFont.caption)
                .foregroundStyle(HCColor.mistWhiteDim)
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
                .fill(.white.opacity(0.06)))
    }

    /// 開始するセッションを入れるグループの選択。表示は「次のセッションが入る先」で、
    /// 今の予定から推測した結果もここに出る。手で選び直すと、その予定の間はその選択が
    /// 優先され、同時に「予定が無いときの既定」としても覚える(AppModel.selectFolder)。
    private var groupPicker: some View {
        Picker("グループ", selection: groupBinding) {
            Text("未分類").tag(String?.none)
            ForEach(model.folders, id: \.self) { folder in
                Text(folder).tag(String?.some(folder))
            }
        }
        .pickerStyle(.menu)
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

    /// 録音を始める前、グループ選択の直下に添える控えめな誘導。ラベルは機能名(関連フォルダ)
    /// でなく効能(要約精度が上がる)で語る。押した先(ReferenceFolderPicker)の
    /// NSOpenPanel.message で「紐付けるとどう良くなるか」を1〜2文説明する
    /// (ここでは専用のチュートリアル画面は作らない)。
    private func referenceFolderHint(target: ReferenceFolderLinkTarget) -> some View {
        Button {
            // このパネルはフォーカスが移ると閉じるため、パネルの親にはできない。
            // 貼り付け先を渡さず、FilePanel 側の保険(今フォーカスのあるスクリーンへ寄せる)に委ねる。
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
        } label: {
            Label("資料フォルダと紐付けて要約精度を上げる", systemImage: "link")
                .font(HCFont.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(HCColor.mistWhiteDim)
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
            .foregroundStyle(HCColor.mistWhiteDim)

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
                Label("会議内容を関連資料と照合", systemImage: "text.magnifyingglass")
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
    }

    /// ラベル左・スイッチ右端のトグル行。スイッチの縦の列を揃える。
    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Toggle(label, isOn: isOn)
                .labelsHidden()
        }
    }

    private func meterRow(label: String, level: Float) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(HCFont.caption)
                .foregroundStyle(HCColor.mistWhiteDim)
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
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("HearCat を終了")
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

/// 入力レベル(RMS)を dB に直して出す横バー。
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(HCColor.cinnamon)
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
