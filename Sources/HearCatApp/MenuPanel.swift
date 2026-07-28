import AppKit
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
            Group {
                if model.status.active {
                    CatHeadShape(includesEyes: true)
                        .fill(HCColor.cinnamon, style: FillStyle(eoFill: true))
                } else {
                    CatHeadShape()
                        .stroke(
                            HCColor.mistWhiteDim,
                            style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                        .overlay(CatHeadShape.Eyes().fill(HCColor.mistWhiteDim))
                }
            }
            .frame(width: 17, height: 17)
            Text("HearCat")
                .font(HCFont.system(size: 14, weight: .black))
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

    // MARK: - 待機中

    private var idleSection: some View {
        VStack(spacing: 10) {
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
            .buttonStyle(PanelButtonStyle())
        }
        .disabled(model.busy)
    }

    /// 開始するセッションを入れるグループの選択。選択は即座に defaultSessionGroup へ
    /// 保存し、次回の既定にする(ここで選んだ内容が、次にホットキーで開始する時の
    /// 既定グループにもなる)。
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
            get: { model.settings.defaultSessionGroup },
            set: { model.settings.defaultSessionGroup = $0 })
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
        guard let folder = model.settings.defaultSessionGroup else {
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
                    model.settings.defaultSessionGroup = folder
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
                model.requestCodeImpactAnalysis()
            } label: {
                Label("会議内容を関連資料と照合", systemImage: "text.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(!model.status.transcribing)

            Button {
                Task { await model.stopSession() }
            } label: {
                Label("セッションを停止", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PanelButtonStyle(foreground: HCColor.rec))
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
        .buttonStyle(PanelButtonStyle())
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

/// パネル用の控えめなボタン。ネイビー地に白の半透明で描き、
/// 青は主ボタン(開始)だけに残して色の役割を分ける(青=開始 / 赤=停止 / 無彩色=その他)。
struct PanelButtonStyle: ButtonStyle {
    var foreground: Color = .white.opacity(0.85)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HCFont.system(size: 12, weight: .medium))
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(.white.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .foregroundStyle(foreground)
            .contentShape(RoundedRectangle(cornerRadius: 7))
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
