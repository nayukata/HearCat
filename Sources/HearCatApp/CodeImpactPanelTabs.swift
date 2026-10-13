import HearCatKit
import SwiftUI

/// 質問パネルのタブ切り替え。選択は AppModel が持ち、⌘1〜⌘3 でも切り替わる(CodeImpactOverlayView 側で拾う)。
struct CodeImpactTabBar: View {
    let model: AppModel

    private static let titles: [(tab: CodeImpactPanelTab, title: String)] = [
        (.transcript, "文字起こし"), (.ask, "AI に質問"), (.decisions, "決まったこと"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.titles, id: \.tab) { entry in
                let selected = model.codeImpactPanelTab == entry.tab
                Button {
                    model.codeImpactPanelTab = entry.tab
                } label: {
                    Text(entry.title)
                        .font(HCFont.style(.subheadline, weight: selected ? .bold : .regular))
                        .foregroundStyle(selected ? HCColor.textPrimary : HCColor.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            HCRadius.shape(HCRadius.chip)
                                .fill(selected ? HCColor.dividerStrong : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .focusEffectDisabled()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(HCRadius.shape(HCRadius.control).fill(HCColor.surface))
    }
}

/// ヘッダーに出す録音中の印と経過時間。ライブ対象で、セッションが動いているときだけ。
struct CodeImpactLiveIndicator: View {
    let model: AppModel

    var body: some View {
        // パネルが閉じている間は秒ごとの更新を止める。
        if model.codeImpactPanelVisible, model.codeImpactTargetGroup == nil,
            model.codeImpactTargetDirectory == nil, model.status.active, let start = model.liveSessionStartDate
        {
            HStack(spacing: 6) {
                if model.status.recording {
                    Circle().fill(HCColor.rec).frame(width: 8, height: 8)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(
                        "\(model.status.recording ? "録音中" : "文字起こし中") \(Self.clock(context.date.timeIntervalSince(start)))"
                    )
                    .font(HCFont.timecode)
                    .foregroundStyle(HCColor.textDim)
                }
            }
            .lineLimit(1)
        }
    }

    private static func clock(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }
}

/// 時刻チップ。押すと文字起こしのその行へ飛ぶ。表示は経過時間、飛び先は壁時計(revealTranscript の物差し)。
struct PanelTimeChip: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(HCFont.monospaced(size: 10.5))
                .foregroundStyle(HCColor.accentText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(HCRadius.shape(HCRadius.chip).fill(HCColor.surface))
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }
}

/// 文字起こしも決まったことも出せない対象(グループ全体)や、まだ何も無い状態の案内。
private struct PanelNotice: View {
    let icon: String
    let title: String
    var detail: String?
    /// 親が既に左右の余白を持っているときは false。
    var inset = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(HCFont.title3)
                .foregroundStyle(HCColor.accentText)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(HCFont.style(.subheadline, weight: .semibold))
                    .foregroundStyle(HCColor.textPrimary)
                if let detail {
                    Text(detail)
                        .font(HCFont.callout)
                        .foregroundStyle(HCColor.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, inset ? 24 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 文字起こしタブ

/// 対象の文字起こし。ライブ対象は進行中の行を下に追いかけ、保存済みセッションは全文を出す。
struct PanelTranscriptTab: View {
    let model: AppModel
    /// 見えているときだけ中身を載せる。閉じたパネルや選ばれていないタブで、行の再描画と
    /// 認識中テキストの追いかけ表示(33ms ごとの更新)を続けないため。
    let active: Bool
    @State private var revealCoordinator = RevealCoordinator<String>()
    @State private var savedLines: [TranscriptLine] = []
    @State private var savedLoaded = false
    @State private var atBottom = true

    private var isLive: Bool {
        model.codeImpactTargetGroup == nil && model.codeImpactTargetDirectory == nil
    }

    var body: some View {
        Group {
            if model.codeImpactTargetGroup != nil {
                PanelNotice(
                    icon: "folder", title: "グループ全体では使えません",
                    detail: "会議を 1 つ選んでください。")
            } else if !active {
                Color.clear
            } else if isLive {
                liveList
            } else {
                savedList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: model.codeImpactTargetDirectory) { await loadSaved() }
    }

    // MARK: ライブ

    @ViewBuilder
    private var liveList: some View {
        if !model.status.active {
            PanelNotice(icon: "waveform.slash", title: "文字起こし中のセッションがありません")
        } else if model.liveTimeline.rows.isEmpty {
            PanelNotice(
                icon: "waveform", title: "まだ発話がありません",
                detail: "話し始めると、ここに文字起こしが増えていきます。")
        } else {
            let startDate = model.liveSessionStartDate
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.liveTimeline.rows) { row in
                            TranscriptRowView(
                                timeLabel: row.volatile
                                    ? nil : Self.elapsedLabel(for: row.time, startDate: startDate),
                                speaker: row.speaker, text: row.text, volatile: row.volatile,
                                isRevealed: row.id == revealCoordinator.revealedID)
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 開いた瞬間と、末尾を見ている間の行の増加では最新に追従する。
                // 上へスクロールして読んでいる間は動かさない。
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 24
                } action: { _, newValue in
                    atBottom = newValue
                }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(model.liveTimeline.rows.last?.id, anchor: .bottom)
                            }
                        } label: {
                            Label("最新へ", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.hcSecondary)
                        .controlSize(.small)
                        .padding(12)
                    }
                }
                .onAppear { consumeLiveReveal(proxy: proxy) }
                .onChange(of: model.codeImpactPanelReveal) { consumeLiveReveal(proxy: proxy) }
            }
        }
    }

    private func consumeLiveReveal(proxy: ScrollViewProxy) {
        guard isLive, let request = model.codeImpactPanelReveal else { return }
        model.codeImpactPanelReveal = nil
        // rows の並びは席固定で時刻順とは限らないため、確定行だけ時刻で並べて探す
        // (LiveSessionView.revealIfRequested と同じ)。
        let finalized = model.liveTimeline.rows.filter { !$0.volatile }.sorted { $0.time < $1.time }
        // 日をまたぐ会議で文字列の大小が逆転しないよう、開始からの経過秒で比べる。
        let target: String?
        if let start = model.liveSessionStartDate,
            let wanted = TranscriptParser.offsetSeconds(
                forWallClock: request.time, sessionStart: start, allowDayCrossing: true)
        {
            target = finalized.first(where: {
                TranscriptParser.offsetSeconds(
                    forWallClock: TranscriptWriter.timeString(from: $0.time), sessionStart: start,
                    allowDayCrossing: true) ?? 0 >= wanted
            })?.id ?? finalized.last?.id
        } else {
            target = finalized.first(where: {
                TranscriptWriter.timeString(from: $0.time) >= request.time
            })?.id ?? finalized.last?.id
        }
        guard let target else { return }
        revealCoordinator.reveal(target, proxy: proxy)
    }

    /// 開始時刻が引けないときは壁時計へ戻さず "--:--"(面ごとに単位が混ざるのを避ける。LiveSessionView と同じ)。
    private static func elapsedLabel(for time: Date, startDate: Date?) -> String {
        guard let startDate else { return "--:--" }
        return formatPlaybackTime(max(0, time.timeIntervalSince(startDate)))
    }

    // MARK: 保存済みセッション

    @ViewBuilder
    private var savedList: some View {
        if !savedLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if savedLines.isEmpty {
            PanelNotice(icon: "text.alignleft", title: "このセッションには文字起こしがありません")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(savedLines) { line in
                            TranscriptRowView(
                                timeLabel: line.offset.map(formatPlaybackTime) ?? "",
                                speaker: line.speaker?.rawValue, speakerName: line.speakerName,
                                text: line.speaker == nil ? line.body : line.text,
                                isRevealed: line.id == savedRevealedID)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { consumeSavedReveal(proxy: proxy) }
                .onChange(of: model.codeImpactPanelReveal) { consumeSavedReveal(proxy: proxy) }
                .onChange(of: savedLines.count) { consumeSavedReveal(proxy: proxy) }
            }
        }
    }

    @State private var savedReveal = RevealCoordinator<Int>()
    private var savedRevealedID: Int? { savedReveal.revealedID }

    private func loadSaved() async {
        savedLoaded = false
        guard let directory = model.codeImpactTargetDirectory,
            let session = model.sessions.first(where: { $0.directory.path == directory })
        else {
            savedLines = []
            savedLoaded = true
            return
        }
        let url = session.transcriptURL
        let start = session.startDate
        let lines = await Task.detached {
            url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                .map { TranscriptParser.lines(from: $0, sessionStart: start) } ?? []
        }.value
        // 読み込み中に対象が変わっていたら、古い結果で新しい対象を上書きしない。
        guard !Task.isCancelled, model.codeImpactTargetDirectory == directory else { return }
        savedLines = lines
        savedLoaded = true
    }

    private func consumeSavedReveal(proxy: ScrollViewProxy) {
        guard !isLive, !savedLines.isEmpty, let request = model.codeImpactPanelReveal else { return }
        model.codeImpactPanelReveal = nil
        // 行の offset は日またぎ補正済み。文字列で比べると日をまたぐ会議で先頭へ飛んでしまう。
        let stamped = savedLines.filter { $0.offset != nil }.sorted { $0.offset! < $1.offset! }
        let session = model.codeImpactTargetDirectory.flatMap { directory in
            model.sessions.first(where: { $0.directory.path == directory })
        }
        let wanted = session.flatMap {
            TranscriptParser.offsetSeconds(
                forWallClock: request.time, sessionStart: $0.startDate, allowDayCrossing: true)
        }
        let target =
            wanted.flatMap { wanted in stamped.first(where: { $0.offset! >= TimeInterval(wanted) }) }
            ?? stamped.last
        guard let target else { return }
        savedReveal.reveal(target.id, proxy: proxy)
    }
}

// MARK: - 決まったことタブ

/// ライブ対象は押したときだけ AI にまとめさせ、保存済みセッションは記録済みの決まったことを並べる。
struct PanelDecisionsTab: View {
    let model: AppModel
    @State private var savedRows: [DecisionRow] = []
    @State private var carriedOver: [DecisionTopic] = []

    private var isLive: Bool {
        model.codeImpactTargetGroup == nil && model.codeImpactTargetDirectory == nil
    }

    var body: some View {
        Group {
            if model.codeImpactTargetGroup != nil {
                PanelNotice(
                    icon: "folder", title: "グループ全体では使えません",
                    detail: "会議を 1 つ選んでください。")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if isLive { liveContent } else { savedContent }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(model.codeImpactTargetDirectory ?? "live")|\(model.activeSessionFolder ?? "")") {
            await loadRecorded()
        }
    }

    // MARK: 保存済みセッション

    @ViewBuilder
    private var savedContent: some View {
        if savedRows.isEmpty {
            Text("このセッションで決まったことの記録はありません。")
                .font(HCFont.callout)
                .foregroundStyle(HCColor.textDim)
        } else {
            sectionLabel("この会議で決まった・変わったこと")
            let start = model.codeImpactTargetSessionStartDate
            ForEach(savedRows) { row in
                decisionCard(
                    dot: row.status, title: row.title, detail: row.currentText,
                    chip: row.timeSeconds.map { seconds in
                        (Self.elapsed(seconds), {
                            guard let start else { return }
                            model.revealTranscript(
                                atTime: TranscriptWriter.timeString(
                                    from: start.addingTimeInterval(TimeInterval(seconds))))
                        })
                    })
            }
        }
    }

    // MARK: ライブ

    /// 別の会議や終了後に作ったまとめは「ライブ」として出さない。
    private var briefState: MeetingBriefState {
        if case .done = model.meetingBriefState, !model.meetingBriefMatchesLiveSession {
            return .idle
        }
        return model.meetingBriefState
    }

    @ViewBuilder
    private var liveContent: some View {
        if model.status.active {
            briefControls
            if case .done(let brief, let trimmed) = briefState {
                briefSections(brief, trimmed: trimmed)
            }
        } else {
            // 記録していないあいだはまとめる材料が無い。ボタンは出さない。
            PanelNotice(
                icon: "waveform.slash", title: "文字起こし中のセッションがありません", inset: false)
        }
        if !carriedOver.isEmpty {
            sectionLabel("これまでの会議から持ち越し").padding(.top, 10)
            ForEach(carriedOver, id: \.id) { topic in
                if let current = topic.current {
                    decisionCard(dot: current.status, title: topic.title, detail: current.text, chip: nil)
                }
            }
        }
    }

    @ViewBuilder
    private var briefControls: some View {
        switch briefState {
        case .idle, .done:
            HStack(spacing: 10) {
                Button(isDone ? "もう一度まとめる" : "ここまでをまとめる") {
                    model.requestMeetingBrief()
                }
                .buttonStyle(.hcSecondary)
                .controlSize(.small)
                if !isDone {
                    Text("押したときだけ、ここまでの文字起こしから AI が抜き出します。")
                        .font(HCFont.caption)
                        .foregroundStyle(HCColor.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .needsConsent(let cli):
            VStack(alignment: .leading, spacing: 8) {
                Text("文字起こしを \(cli.displayName) が読み取ってまとめます。初回のみ確認が必要です。コードは変更しません。")
                    .font(HCFont.callout)
                    .foregroundStyle(HCColor.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("同意してまとめる") { model.confirmMeetingBrief(using: cli) }
                        .buttonStyle(.hcPrimary)
                    Button("やめる") { model.cancelMeetingBrief(discardResult: true) }
                        .buttonStyle(.plain)
                        .foregroundStyle(HCColor.textBody)
                        .pointingHandOnHover()
                }
            }
        case .running(let cli):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(cli.displayName) がここまでをまとめています…")
                    .font(HCFont.callout)
                    .foregroundStyle(HCColor.textDim)
                Spacer()
                Button("中止") { model.cancelMeetingBrief() }
                    .buttonStyle(.plain)
                    .foregroundStyle(HCColor.textBody)
                    .pointingHandOnHover()
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(HCFont.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("もう一度試す") { model.requestMeetingBrief() }
                    .buttonStyle(.hcSecondary)
                    .controlSize(.small)
            }
        }
    }

    private var isDone: Bool {
        if case .done = briefState { return true }
        return false
    }

    @ViewBuilder
    private func briefSections(_ brief: MeetingBrief, trimmed: MeetingBriefTrim?) -> some View {
        let start = model.liveSessionStartDate
        if let trimmed {
            Text(
                trimmed.minutes.map { "長いので、直近の約 \($0) 分だけをまとめました。" }
                    ?? "長いので、直近の部分だけをまとめました。"
            )
            .font(HCFont.caption)
            .foregroundStyle(HCColor.textDim)
        }
        if brief.isEmpty {
            Text("ここまでに、決まったことも、保留になっていることも見つかりませんでした。")
                .font(HCFont.callout)
                .foregroundStyle(HCColor.textDim)
                .padding(.top, 6)
        }
        if !brief.decided.isEmpty {
            sectionLabel("この会議で決まったこと").padding(.top, 6)
            ForEach(Array(brief.decided.enumerated()), id: \.offset) { _, item in
                briefCard(item, decided: true, start: start)
            }
        }
        if !brief.open.isEmpty {
            sectionLabel("まだ決まっていないこと").padding(.top, 10)
            ForEach(Array(brief.open.enumerated()), id: \.offset) { _, item in
                briefCard(item, decided: false, start: start)
            }
        }
    }

    private func briefCard(_ item: MeetingBrief.Item, decided: Bool, start: Date?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            statusDot(decided: decided)
            Text(item.text)
                .font(HCFont.body)
                .foregroundStyle(HCColor.textBody)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let time = item.time {
                PanelTimeChip(label: Self.chipLabel(forWallClock: time, start: start)) {
                    model.revealTranscript(atTime: time)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HCRadius.shape(HCRadius.card).fill(HCColor.surface))
    }

    private func decisionCard(
        dot status: DecisionStatus, title: String, detail: String,
        chip: (label: String, action: () -> Void)?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            statusDot(decided: status == .confirmed)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(HCFont.style(.body, weight: .semibold))
                    .foregroundStyle(HCColor.textPrimary)
                Text(detail)
                    .font(HCFont.callout)
                    .foregroundStyle(HCColor.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            DecisionStatusChip(status: status)
            if let chip {
                PanelTimeChip(label: chip.label, action: chip.action)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HCRadius.shape(HCRadius.card).fill(HCColor.surface))
    }

    private func statusDot(decided: Bool) -> some View {
        Group {
            if decided {
                Circle().fill(HCColor.confirmedTextLight)
            } else {
                Circle().stroke(HCColor.textDeeper, lineWidth: 1.5)
            }
        }
        .frame(width: 7, height: 7)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(HCFont.caption)
            .foregroundStyle(HCColor.textDeeper)
    }

    private static func elapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// 表示は経過時間、飛び先は壁時計。開始時刻が引けない・変換できないときは壁時計のまま出す。
    private static func chipLabel(forWallClock time: String, start: Date?) -> String {
        guard let start,
            let offset = TranscriptParser.offsetSeconds(
                forWallClock: time, sessionStart: start, allowDayCrossing: false)
        else { return time }
        return elapsed(offset)
    }

    /// 記録済みの決まったことを読む。保存済みセッションはそのセッション由来の行、
    /// ライブは所属グループから持ち越している未決。壊れた記録は画面を塞がず空のままにする。
    private func loadRecorded() async {
        if let directory = model.codeImpactTargetDirectory {
            guard let session = model.sessions.first(where: { $0.directory.path == directory }),
                let folder = session.folder,
                let log = try? DecisionLogStore.load(folder: folder)
            else {
                savedRows = []
                return
            }
            savedRows = DecisionRow.rows(
                from: log, sessionDirectoryName: session.directory.lastPathComponent)
            return
        }
        guard model.codeImpactTargetGroup == nil, let folder = model.activeSessionFolder else {
            carriedOver = []
            return
        }
        carriedOver = DecisionLogStore.loadOrEmpty(folder: folder).unresolvedTopics()
    }
}
