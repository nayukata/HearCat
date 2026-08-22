import AppKit
import HearCatKit
import HearCatSummarize
import SwiftUI
import UniformTypeIdentifiers
import os

/// 決定事項ログ(decisions.json)の読み書き失敗を残すための内部ログ。決定事項の抽出側
/// (AppModel.swift の decisionExtractionLogger)とは別カテゴリにする(取り込み時の失敗と、
/// この画面での閲覧・検品操作の失敗は原因が別なので、ログ上でも分けて追える方がよい)。
private let decisionInspectionLogger = Logger(
    subsystem: SessionStore.bundleIdentifier, category: "decision-inspection")

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
    /// 共有メニューの位置の基準。要約メニューとはボタンの位置が違うため別に持つ
    /// (項目の target は同時に開かないので summarizeMenuActionHandler を共用する)。
    @State private var shareMenuAnchor: NSView?
    /// セッションの書き出し中。数十 MB の録音を含むとすぐには終わらないため、
    /// ボタンを進捗表示に差し替えて二重実行も防ぐ。
    @State private var exporting = false
    /// 共有(画像コピー・書き出し)の結果。成功は一定時間で消え、失敗は理由を残す。
    @State private var shareNotice: ShareNotice?
    /// 録音があるか。session.audioURL は実体の存在確認を伴うため、body の評価のたびに
    /// ディスクを見にいかないよう、読み込み時に控えた値を使う。
    @State private var hasAudio = false
    /// 再生位置が今どの行にあたるか。再生位置そのもの(0.25 秒ごとに変わる)ではなく
    /// 行の切り替わりだけをここに持つことで、文字起こしの描き直しを最小限にする。
    @State private var currentLineID: TranscriptLine.ID?
    /// 再生に合わせて文字起こしを自動で送るか。手でスクロールした時点で切れる。
    @State private var followsPlayback = true
    /// 質問応答パネルからのジャンプで、今フェード中にハイライトしている行(currentLineID =
    /// 再生位置とは独立、再生していなくてもジャンプできる)。収束スクロール・点灯・フェード
    /// 消灯の一連の演出は RevealCoordinator(LiveSessionView と共有)に委ねる。
    @State private var revealCoordinator = RevealCoordinator<TranscriptLine.ID>()
    /// content の ScrollViewReader が持つ proxy。session.id をまたいでもビューは
    /// 使い回す(header 直下のコメント参照)ため、onAppear で一度だけ取れれば以後も使い回せる。
    /// body 側の .task(id: session.id) からもジャンプを試したいが、そこは ScrollViewReader の
    /// スコープの外にあるため、ここに控えて共有する。
    @State private var scrollProxy: ScrollViewProxy?
    /// クリックによる行選択(TranscriptLine.id)。複数行コピーの対象。空なら行内の
    /// 文字単位選択(.textSelection)だけが有効な通常状態。
    @State private var selectedLineIDs: Set<TranscriptLine.ID> = []
    /// Shift+クリックで範囲選択する起点。単独クリック・Cmd+クリックのたびに選んだ行へ更新する。
    @State private var selectionAnchorID: TranscriptLine.ID?
    /// ドラッグ範囲選択(handleRowDragChanged)のために測った各行の表示位置
    /// (transcriptRowsSpace 基準)。LazyVStack でまだ実体化していない行は含まれない。
    @State private var rowFrames: [TranscriptLine.ID: CGRect] = [:]
    /// ドラッグ範囲選択の起点。ドラッグ中だけ値を持ち、指を離すと nil に戻す。
    @State private var dragSelectionAnchorID: TranscriptLine.ID?
    /// 行選択がある間だけ張る Cmd+C / Esc の監視。このアプリは LSUIElement(メニューバー
    /// 非表示)で Edit メニューを持たないため、選択中の Cmd+C は標準メニュー経由では届かない
    /// (前例: SettingsView.swift の HotkeyRecorderField)。選択が空の間は張らず、行内の
    /// 文字選択の既定の Cmd+C を妨げない。
    @State private var lineSelectionMonitor: Any?
    /// この会議で決まった・変わったこと(検品ブロック)の表示行。所属グループが無い、
    /// このセッション由来のエントリが1件も無い、decisions.json が壊れている、のいずれかで
    /// 空のまま(見出しだけの空ブロックは出さない)。
    @State private var decisionRows: [DecisionRow] = []
    /// 「内容を修正…」で開くシートの対象。nil でない間だけ出る。
    @State private var editingDecision: DecisionRow?

    /// Cmd+F のページ内検索バーを表示中か。
    @State private var searchBarVisible = false
    @State private var searchQuery = ""
    @FocusState private var searchFieldFocused: Bool
    /// 検索語に一致した行の ID。transcriptLines の表示順のまま保持する。
    @State private var searchMatchIDs: [TranscriptLine.ID] = []
    /// searchMatchIDs 内での現在位置。0件、または未検索なら nil。
    @State private var currentMatchOrdinal: Int?
    /// Cmd+F・検索バー表示中の Enter 以外のキー操作(Esc・Cmd+G 系)を拾う監視。
    /// lineSelectionMonitor と違い、この画面が表示されている間ずっと張る
    /// (Cmd+F はいつでも押せる必要があるため)。
    @State private var searchKeyMonitor: Any?
    /// ヒット行への収束スクロール(jumpToCurrentMatch)を実行中のタスク。新しいジャンプが
    /// 割り込んだら前回分をキャンセルする(RevealCoordinator.reveal と同じ理屈)。
    @State private var searchScrollTask: Task<Void, Never>?

    private struct ShareNotice: Equatable {
        let message: String
        let isError: Bool
    }

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

    /// 停止直後の自動要約が失敗していた場合の理由。要約が無い理由が分からないままだと
    /// 直しようがないため、この画面(= 要約を作り直せる場所)に出す。
    private var autoSummaryFailureMessage: String? {
        guard summary == nil, let failure = model.autoSummaryFailure,
            failure.sessionID == session.id
        else { return nil }
        return "自動要約に失敗しました: \(failure.message)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let player, player.hasAudio {
                PlayerView(player: player)
                    // 再生位置の監視はレイアウトに出ない小さなビューへ閉じ込める。
                    // 位置は 0.25 秒ごとに変わるため、これを本体の body で読むと
                    // 文字起こし全体がその頻度で描き直しの対象になる。
                    .background {
                        PlaybackTracker(
                            player: player, lines: transcriptLines,
                            currentLineID: $currentLineID)
                    }
                Divider()
            }
            // 検索は本文 (文字起こし) に対する操作なので、再生バーより本文側に置く。
            searchBar
            content
        }
        .task(id: session.id) {
            resetForNewSession()
            load(forceNewPlayer: true)
            // セッション切り替え(質問応答パネルからのジャンプで別セッションへ移った場合を含む)
            // の直後に、このセッション宛てのジャンプ要求が積まれていれば拾う。scrollProxy は
            // content 側の onAppear で控えたものを使う(このタスクは ScrollViewReader の
            // スコープの外にあるため)。
            revealIfRequested()
        }
        // 成功の合図は用が済んだら消す。失敗は理由が読めるよう残す。
        // 画面を離れた時と次の合図が来た時に、この待機は自動でキャンセルされる。
        .task(id: shareNotice) {
            guard let shareNotice, !shareNotice.isError else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.shareNotice = nil
        }
        // 停止直後に詳細へ遷移した場合、最後の発話の確定はまだファイルに
        // 書かれていないことがある。refreshSessions のたびに読み直して追従する。
        .onChange(of: model.sessionsVersion) { load(forceNewPlayer: false) }
        .onChange(of: selectedLineIDs.isEmpty) { updateLineSelectionMonitor() }
        .onChange(of: searchQuery) { updateSearchMatches() }
        // ライブ中に文字起こしが追記された場合、新しい行も検索対象に含める。
        // 現在位置(currentMatchOrdinal)はジャンプさせず据え置く。
        .onChange(of: transcriptLines.count) {
            guard searchBarVisible, !searchQuery.isEmpty else { return }
            updateSearchMatches(preserveCurrent: true)
        }
        .onAppear { installSearchKeyMonitor() }
        .onDisappear {
            player?.teardown()
            removeLineSelectionMonitor()
            removeSearchKeyMonitor()
            searchScrollTask?.cancel()
        }
        .sheet(item: $editingDecision) { row in
            DecisionEditSheet(row: row) { newText in
                updateDecision(row, newText: newText)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                // 一覧と同じ役割分担。開始日時は名前の有無に関わらず必ず下の行に出す
                // (名前を付けても日時は消えないことを、画面上で保証する)。
                Group {
                    if session.name.isEmpty {
                        Text(SessionRow.untitledPlaceholder)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(session.name)
                    }
                }
                .font(HCFont.headline)
                Text(session.startDate.formatted(date: .complete, time: .shortened))
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            summarizeButton
            codeImpactButton
            if isSummarizing, let agentSummarizeTask {
                Button("キャンセル") {
                    agentSummarizeTask.cancel()
                }
                .controlSize(.small)
            }
            shareButton
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
                SessionDeletionCopy.title(count: 1), isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button(SessionDeletionCopy.confirmButton(count: 1), role: .destructive) {
                    player?.teardown()
                    model.delete(session)
                    onDelete()
                }
                // 一括削除側(BulkDeleteConfirmation)と同じく、Enter で確定できるよう明示する。
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(SessionDeletionCopy.message)
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

    /// Cmd+F で開くページ内検索バー。文字起こしの本文(body)だけを対象にする
    /// (要約・検品ブロックは対象外)。0件でも移動ボタンは disabled にするだけで、
    /// バー自体は開いたままにする(閉じると入力途中の語が消えてしまうため)。
    @ViewBuilder
    private var searchBar: some View {
        if searchBarVisible {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("文字起こしを検索", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFieldFocused)
                        .onSubmit {
                            let backwards = NSEvent.modifierFlags.contains(.shift)
                            jumpToMatch(direction: backwards ? -1 : 1)
                        }
                        .onExitCommand { closeSearch() }
                    Text(searchMatchCountLabel)
                        .font(HCFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Button {
                        jumpToMatch(direction: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(searchMatchIDs.isEmpty)
                    Button {
                        jumpToMatch(direction: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(searchMatchIDs.isEmpty)
                    Button {
                        closeSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
            }
        }
    }

    private var searchMatchCountLabel: String {
        guard !searchMatchIDs.isEmpty else { return "0 件" }
        let ordinal = (currentMatchOrdinal ?? 0) + 1
        return "\(searchMatchIDs.count) 件中 \(ordinal) 件目"
    }

    /// 検索対象の行 ID を今のヒット位置を跨いで指す(現在ヒットの持続点灯に使う)。
    private var currentSearchMatchID: TranscriptLine.ID? {
        guard let currentMatchOrdinal, searchMatchIDs.indices.contains(currentMatchOrdinal)
        else { return nil }
        return searchMatchIDs[currentMatchOrdinal]
    }

    private func openSearch() {
        searchBarVisible = true
        searchFieldFocused = true
        // 検索バー表示中は Esc を検索を閉じる操作として確定させたいため、行選択の
        // Esc/Cmd+C 監視(lineSelectionMonitor)と競合しないよう選択を解除する。
        if !selectedLineIDs.isEmpty {
            clearLineSelection()
        }
    }

    private func closeSearch() {
        searchScrollTask?.cancel()
        searchBarVisible = false
        searchFieldFocused = false
        searchQuery = ""
        searchMatchIDs = []
        currentMatchOrdinal = nil
    }

    /// searchQuery(または追記された文字起こし)からヒット行を作り直す。
    /// preserveCurrent: true の場合、今指している行が新しい結果にまだ含まれていれば
    /// その位置を維持してジャンプしない(追記によるヒット再計算で表示位置が飛ばないように)。
    /// それ以外は先頭のヒットへジャンプする。
    private func updateSearchMatches(preserveCurrent: Bool = false) {
        let keepID = preserveCurrent ? currentSearchMatchID : nil
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchMatchIDs = []
            currentMatchOrdinal = nil
            return
        }
        searchMatchIDs = transcriptLines
            .filter { $0.body.localizedCaseInsensitiveContains(query) }
            .map(\.id)
        guard !searchMatchIDs.isEmpty else {
            currentMatchOrdinal = nil
            return
        }
        if let keepID, let idx = searchMatchIDs.firstIndex(of: keepID) {
            currentMatchOrdinal = idx
            return
        }
        currentMatchOrdinal = 0
        jumpToCurrentMatch()
    }

    /// 次(direction: 1)/前(direction: -1)のヒットへ移動する。末尾から次へ進むと先頭へ、
    /// 先頭から前へ戻ると末尾へ循環する(サイドバー検索など他の検索 UI に合わせた挙動)。
    private func jumpToMatch(direction: Int) {
        guard !searchMatchIDs.isEmpty else { return }
        let count = searchMatchIDs.count
        let current = currentMatchOrdinal ?? 0
        currentMatchOrdinal = (current + direction + count) % count
        jumpToCurrentMatch()
    }

    /// 文字起こしは LazyVStack なので、未実体化の遠い行への scrollTo は推定高さで着地し、
    /// 行き過ぎたり手前止まりになったりする(RevealCoordinator.reveal と同じ理屈)。同じ
    /// target へ間隔を空けて複数回投げて収束させ、最後の 1 回だけアニメーション付きで寄せる。
    /// RevealCoordinator 自体は流用しない(あちらはフェード点灯の演出込みの型のため。
    /// 検索の現在ヒットは SearchMatchHighlight の持続点灯で別に表現している)。
    private func jumpToCurrentMatch() {
        guard let proxy = scrollProxy, let target = currentSearchMatchID else { return }
        // 検索ジャンプ中は再生位置への自動追従と競合させない(revealIfRequested と同じ理屈)。
        followsPlayback = false
        searchScrollTask?.cancel()
        searchScrollTask = Task {
            for _ in 0..<RevealTiming.convergeCount {
                guard !Task.isCancelled else { return }
                proxy.scrollTo(target, anchor: .center)
                try? await Task.sleep(for: RevealTiming.convergeInterval)
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: RevealTiming.finalScrollDuration)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    private func installSearchKeyMonitor() {
        guard searchKeyMonitor == nil else { return }
        searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let lowercasedCharacters = event.charactersIgnoringModifiers?.lowercased()
            let eventWindowID = event.window.map(ObjectIdentifier.init)
            let consumed = MainActor.assumeIsolated {
                handleSearchKeyDown(
                    keyCode: keyCode, flags: flags, lowercasedCharacters: lowercasedCharacters,
                    eventWindowID: eventWindowID)
            }
            return consumed ? nil : event
        }
    }

    private func removeSearchKeyMonitor() {
        if let searchKeyMonitor {
            NSEvent.removeMonitor(searchKeyMonitor)
        }
        searchKeyMonitor = nil
    }

    /// 消費したら true を返す(handleLineSelectionKeyDown と同じ規約)。Enter は
    /// TextField の onSubmit、検索欄フォーカス中の Esc は onExitCommand に譲る
    /// (フォーカスが NSText にある間、この監視はそれらを奪わない)ため、ここでは
    /// Cmd+F・Cmd+G 系・検索欄以外にフォーカスがある間の Esc だけを扱う。
    /// Cmd+F・Cmd+G は、サイドバーの検索欄や改名フィールドなど他のテキスト編集欄で
    /// 入力中なら奪わない(inOtherTextField)。ただし検索バー自身の検索欄
    /// (searchFieldFocused)は例外にする。この画面の TextField も AppKit 上は NSText
    /// になるため、区別なく弾くと検索欄にフォーカスがある間 Cmd+G で次のヒットへ
    /// 移動できなくなってしまう。
    private func handleSearchKeyDown(
        keyCode: UInt16, flags: NSEvent.ModifierFlags, lowercasedCharacters: String?,
        eventWindowID: ObjectIdentifier?
    ) -> Bool {
        guard let ownWindow = model.mainWindow, eventWindowID == ObjectIdentifier(ownWindow) else {
            return false
        }
        let inOtherTextField = !searchFieldFocused && (NSApp.keyWindow?.firstResponder is NSText)
        if flags == .command, lowercasedCharacters == "f" {
            guard !inOtherTextField else { return false }
            openSearch()
            return true
        }
        guard searchBarVisible else { return false }
        if flags == [.command, .shift], lowercasedCharacters == "g" {
            guard !inOtherTextField else { return false }
            jumpToMatch(direction: -1)
            return true
        }
        if flags == .command, lowercasedCharacters == "g" {
            guard !inOtherTextField else { return false }
            jumpToMatch(direction: 1)
            return true
        }
        if keyCode == 53, !(NSApp.keyWindow?.firstResponder is NSText) {  // Escape
            closeSearch()
            return true
        }
        return false
    }

    /// 本文の先頭を指すスクロール目標。切り替え時に頭出しするためだけの固定 ID。
    private static let contentTop = "content-top"

    /// 行ドラッグでの範囲選択に使う、行位置(frame)を測る座標空間の名前。
    /// onGeometryChange の of: クロージャ(@Sendable)から参照するため nonisolated にする
    /// (ただの String 定数なので隔離を外しても安全)。
    private nonisolated static let transcriptRowsSpace = "transcript-rows"

    private var content: some View {
        ScrollViewReader { proxy in
            scrollBody
                // ビューを使い回すため、スクロール位置は前のセッションのまま残る。
                // 新しいセッションは先頭から読めるように頭出しする。
                .onChange(of: session.id) {
                    proxy.scrollTo(Self.contentTop, anchor: .top)
                }
                // 再生が次の行へ進んだら、その行が見える位置まで送る。
                .onChange(of: currentLineID) {
                    guard followsPlayback, let currentLineID else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(currentLineID, anchor: .center)
                    }
                }
                .overlay(alignment: .bottom) { resumeFollowButton(proxy) }
                // proxy はビュー生成のたびに作り直されるが、同じ ScrollView を指すハンドルなので
                // 1度控えれば以後もそのまま使える。onAppear は(ビューを使い回す都合上)最初に
                // この画面が現れた時にしか呼ばれないため、直後に revealIfRequested() も試す
                // (ウィンドウを閉じている状態からのジャンプでは、この初回呼び出しが本番になる)。
                .onAppear {
                    scrollProxy = proxy
                    revealIfRequested()
                }
                // ウィンドウを開いたまま(このセッションを表示中のまま)続けてジャンプされた場合。
                .onChange(of: model.transcriptRevealRequest) {
                    revealIfRequested()
                }
        }
    }

    /// 質問応答パネルの「根拠と補足」からのジャンプ要求を消費する。自分が表示している
    /// セッション(session.id)宛てでなければ何もしない(ライブ側や、まだこの画面に
    /// 切り替わっていない他セッションの詳細画面に委ねる)。scrollProxy 未取得や
    /// transcriptLines 未ロードの間も何もしない(呼び出し元を複数用意しているので、
    /// 条件が揃ったタイミングのどれかで拾える)。
    private func revealIfRequested() {
        guard let proxy = scrollProxy,
            let request = model.transcriptRevealRequest, request.sessionID == session.id,
            !transcriptLines.isEmpty
        else { return }
        model.transcriptRevealRequest = nil

        // 比較の前に stamp で安定ソートしておく。ファイルは基本的に時刻順で書かれるが、
        // 将来なんらかの事情で順不同になっても「以降で最初の行」の選択が壊れないようにするため。
        let stamped = transcriptLines.filter { $0.stamp != nil }.sorted { $0.stamp! < $1.stamp! }
        guard let target = stamped.first(where: { $0.stamp! >= request.time }) ?? stamped.last
        else { return }

        // 指定時刻を見せるためのジャンプなので、再生位置への自動追従とは競合させない
        // (追従が生きていると、次に再生位置が進んだ瞬間にここへスクロールし直されてしまう)。
        followsPlayback = false
        revealCoordinator.reveal(target.id, proxy: proxy)
    }

    /// 追従を切った後に戻るための唯一の導線。追従できている間は出さない
    /// (常設のトグルにすると、正常時にも操作対象が1つ増えるため)。
    @ViewBuilder
    private func resumeFollowButton(_ proxy: ScrollViewProxy) -> some View {
        if !followsPlayback, let currentLineID, player?.hasAudio == true {
            Button {
                followsPlayback = true
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(currentLineID, anchor: .center)
                }
            } label: {
                Label("再生位置へ戻る", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.hcSecondary)
            .controlSize(.small)
            .padding(.bottom, 12)
            .transition(.opacity)
        }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = summaryError ?? autoSummaryFailureMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let shareNotice {
                    Label(
                        shareNotice.message,
                        systemImage: shareNotice.isError
                            ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(shareNotice.isError ? .orange : .secondary)
                }
                if !decisionRows.isEmpty {
                    GroupBox {
                        DecisionBlockView(
                            rows: decisionRows,
                            onJump: { jumpToTranscript(offsetSeconds: $0) },
                            onEdit: { editingDecision = $0 },
                            onRemove: { removeDecision($0) })
                    } label: {
                        Text("この会話で決まった・変わったこと")
                    }
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
                                // 見えている行だけを作る。長い会議は数百行になり、
                                // 全行を一度に組み立てるとセッションを選んだ瞬間に
                                // そのぶん画面が止まる(1行あたり時刻・話者・本文と
                                // 部品が複数あるため、行数がそのまま効く)。
                                LazyVStack(alignment: .leading, spacing: 3) {
                                    ForEach(transcriptLines) { line in
                                        transcriptRow(line)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .coordinateSpace(name: Self.transcriptRowsSpace)
                                .gesture(
                                    DragGesture(
                                        minimumDistance: 5, coordinateSpace: .named(Self.transcriptRowsSpace)
                                    )
                                    .onChanged(handleRowDragChanged)
                                    .onEnded { _ in dragSelectionAnchorID = nil }
                                )
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
            .id(Self.contentTop)
        }
        // 手でスクロールした時点で追従をやめる。読み返している最中に表示位置を
        // 奪われないようにするため。追従による移動は .animating、静止は .idle なので、
        // それ以外(指やホイールに由来する動き)を人の操作とみなす。トラックパッドと
        // マウスホイールで報告される段階が違うため、.interacting だけを見ない。
        .onScrollPhaseChange { _, phase in
            if phase != .idle && phase != .animating { followsPlayback = false }
        }
    }

    /// 1行ぶんの文字起こし。行頭には録音内の経過時間(分:秒。再生バーと同じ物差し)を出し、
    /// クリックで録音のその位置から再生する。ファイル内の壁時計時刻(stamp)は表示しない。
    /// 表示の単位は、ライブ画面・質問応答パネルの根拠チップと同じく経過時間で統一する方針
    /// (壁時計へ寄せた時期もあったが、ユーザーの決定により経過時間へ戻した)。
    @ViewBuilder
    private func transcriptRow(_ line: TranscriptLine) -> some View {
        if let offset = line.offset {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let player, player.hasAudio {
                    Button(formatPlaybackTime(offset)) {
                        // 位置を指定した以上、以後は再生を追いかけたいはずなので追従を戻す。
                        followsPlayback = true
                        player.playFrom(offset)
                    }
                    .buttonStyle(.plain)
                    .font(HCFont.timecode)
                    .foregroundStyle(.tint)
                    .help("この位置から再生")
                } else {
                    Text(formatPlaybackTime(offset))
                        .font(HCFont.timecode)
                        .foregroundStyle(.secondary)
                }
                // 話者はライブ画面と同じチップで示す。同じ内容を2度読ませないよう、
                // 本文からは話者ラベルを外す(コピーは元の「話者: 発言」のまま)。
                if let speaker = line.speaker {
                    SpeakerChip(speaker: speaker.rawValue)
                    Text(line.text)
                } else {
                    Text(line.body)
                }
            }
            .modifier(CurrentLineHighlight(isCurrent: line.id == currentLineID))
            .modifier(RevealHighlight(isRevealed: line.id == revealCoordinator.revealedID))
            .modifier(LineSelectionHighlight(isSelected: selectedLineIDs.contains(line.id)))
            .modifier(SearchMatchHighlight(isCurrentMatch: line.id == currentSearchMatchID))
            .contentShape(Rectangle())
            // 時刻ボタンとの競合対策は GroupDetailView.TopicRow と同じ理屈: SwiftUI は
            // Button 自身のヒットテストを外側の onTapGesture より優先するため、時刻ボタンの
            // 当たり判定内はボタンの再生アクションだけが起き、行選択は起きない。
            .onTapGesture { handleLineClick(line.id) }
            // ドラッグ範囲選択(handleRowDragChanged)が使う行位置を測る。LazyVStack で
            // まだ実体化していない行はここを通らないため rowFrames に載らない。
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.transcriptRowsSpace))
            } action: { rowFrames[line.id] = $0 }
            .contextMenu {
                if !selectedLineIDs.isEmpty {
                    Button("選択範囲をコピー (\(selectedLineIDs.count) 行)") {
                        copySelectedLines()
                    }
                }
            }
            .id(line.id)
        } else {
            Text(line.body)
                .textSelection(.enabled)
        }
    }

    /// 単独クリックは新規選択にする。選択がその1行だけの状態でもう一度押した場合は、
    /// 選び直すのではなく解除にする(トグルとして自然に振る舞わせるため)。
    private func handleLineClick(_ id: TranscriptLine.ID) {
        let flags = NSEvent.modifierFlags.intersection([.command, .shift])
        if flags.contains(.shift), let anchor = selectionAnchorID {
            selectedLineIDs.formUnion(lineIDRange(from: anchor, to: id))
            return
        }
        if flags.contains(.command) {
            if selectedLineIDs.contains(id) {
                selectedLineIDs.remove(id)
            } else {
                selectedLineIDs.insert(id)
            }
            selectionAnchorID = id
            return
        }
        if selectedLineIDs == [id] {
            selectedLineIDs = []
            selectionAnchorID = nil
        } else {
            selectedLineIDs = [id]
            selectionAnchorID = id
        }
    }

    private func lineIDRange(
        from anchor: TranscriptLine.ID, to id: TranscriptLine.ID
    ) -> [TranscriptLine.ID] {
        guard let anchorIndex = transcriptLines.firstIndex(where: { $0.id == anchor }),
            let targetIndex = transcriptLines.firstIndex(where: { $0.id == id })
        else { return [id] }
        let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        return transcriptLines[range].map(\.id)
    }

    /// ドラッグ開始で既存の選択を捨てるのは、なぞり直しがそのまま選び直しになる
    /// 操作感にするため(追加選択は Shift+クリックに寄せる)。
    private func handleRowDragChanged(_ value: DragGesture.Value) {
        if dragSelectionAnchorID == nil {
            guard let startID = lineID(atY: value.startLocation.y) else { return }
            dragSelectionAnchorID = startID
            selectionAnchorID = startID
        }
        guard let anchor = dragSelectionAnchorID, let currentID = lineID(atY: value.location.y)
        else { return }
        selectedLineIDs = Set(lineIDRange(from: anchor, to: currentID))
    }

    /// 行間の隙間やリストの上下端の外でもドラッグ選択が途切れないよう、
    /// 行に当たらない座標は最も近い行へ丸める。
    private func lineID(atY y: CGFloat) -> TranscriptLine.ID? {
        if let hit = rowFrames.first(where: { $0.value.minY <= y && y <= $0.value.maxY }) {
            return hit.key
        }
        return rowFrames.min(by: { abs($0.value.midY - y) < abs($1.value.midY - y) })?.key
    }

    /// 選択行を、元ファイルと同じ「[HH:mm:ss] 話者: 発言」形式で改行区切りにしてコピーする。
    /// 書き込み側の区切り書式が変わると、全文コピー(TranscriptParser.bodyText)と
    /// 食い違う。選択順ではなく表示順に整列する。
    private func copySelectedLines() {
        guard !selectedLineIDs.isEmpty else { return }
        let text = transcriptLines
            .filter { selectedLineIDs.contains($0.id) }
            .map { line -> String in
                guard let stamp = line.stamp else { return line.body }
                return "[\(stamp)] \(line.body)"
            }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func clearLineSelection() {
        selectedLineIDs = []
        selectionAnchorID = nil
    }

    /// 選択行の有無に応じて Cmd+C / Esc の監視を張り替える。
    private func updateLineSelectionMonitor() {
        guard !selectedLineIDs.isEmpty else {
            removeLineSelectionMonitor()
            return
        }
        guard lineSelectionMonitor == nil else { return }
        lineSelectionMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // NSEvent/NSWindow は Sendable ではないため、MainActor.assumeIsolated の
            // クロージャへそのまま渡せない。必要な値だけを先に取り出してから渡す
            // (ウィンドウは identity 比較にしか使わないので ObjectIdentifier で足りる)。
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let lowercasedCharacters = event.charactersIgnoringModifiers?.lowercased()
            let eventWindowID = event.window.map(ObjectIdentifier.init)
            let consumed = MainActor.assumeIsolated {
                handleLineSelectionKeyDown(
                    keyCode: keyCode, flags: flags, lowercasedCharacters: lowercasedCharacters,
                    eventWindowID: eventWindowID)
            }
            return consumed ? nil : event
        }
    }

    private func removeLineSelectionMonitor() {
        if let lineSelectionMonitor {
            NSEvent.removeMonitor(lineSelectionMonitor)
        }
        lineSelectionMonitor = nil
    }

    /// 消費したら true を返す(呼び出し側がそれを見て nil を返し、ビープ等の既定動作を止める)。
    private func handleLineSelectionKeyDown(
        keyCode: UInt16, flags: NSEvent.ModifierFlags, lowercasedCharacters: String?,
        eventWindowID: ObjectIdentifier?
    ) -> Bool {
        // ローカル監視はアプリ内の全ウィンドウの keyDown に掛かる。自分(= このビューが
        // 乗っている model.mainWindow)宛てのキーだけを対象にしないと、質問応答パネル
        // (CodeImpactOverlay、別ウィンドウの NSPanel)がキーになっている間の Esc/Cmd+C まで
        // 横取りし、パネル側の onExitCommand などへ届かなくなる。
        guard let ownWindow = model.mainWindow, eventWindowID == ObjectIdentifier(ownWindow) else {
            return false
        }
        // フォーカスが他のテキスト編集欄(改名フィールドや決定事項の修正シートなど)にある間は
        // 素通しし、そちらの Cmd+C を奪わない。
        guard !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
        // 検索バー表示中は Esc を検索を閉じる操作として確定させる(openSearch で選択は
        // 既に解除済みだが、表示中に別の行を選び直した場合の Esc もここで奪わない)。
        guard !searchBarVisible else { return false }
        if keyCode == 53 {  // Escape
            clearLineSelection()
            return true
        }
        if flags == .command, lowercasedCharacters == "c" {
            copySelectedLines()
            return true
        }
        return false
    }

    /// セッションが切り替わった時に、前のセッションの一時的な表示を持ち越さないようにする。
    /// 以前はビュー自体を .id(session.id) で作り直すことでこれを済ませていたが、
    /// 切り替えのたびにビュー階層ごと再構築になり表示が遅かった(MainWindow のコメント参照)。
    /// 書き出し中(exporting)は畳まない。処理自体は裏で続いているため、ここで false に
    /// 戻すと二重に走らせられてしまう。
    private func resetForNewSession() {
        summaryError = nil
        shareNotice = nil
        currentLineID = nil
        followsPlayback = true
        confirmingDelete = false
        confirmingAgentCLI = nil
        // 実行中のエージェント要約は止めない(生成は AppModel 側で走り続ける)。
        // この画面から離れた以上キャンセル UI は出せないので、参照だけ外す。
        agentSummarizeTask = nil
        decisionRows = []
        editingDecision = nil
        closeSearch()
    }

    /// forceNewPlayer が false の再読込(sessionsVersion 変化時)では、再生中に
    /// 途切れさせないよう、既に音声を持っているプレーヤーは作り直さない。
    private func load(forceNewPlayer: Bool) {
        transcript = session.transcriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        transcriptLines = TranscriptParser.lines(
            from: transcript ?? "", sessionStart: session.startDate)
        // 行の並びや ID(行番号)が変わり得るタイミングなので選択は持ち越さない
        // (古い ID が入れ替わった後の別の内容を指してしまうのを防ぐ)。同じ理由で
        // 測り直しが必要な行位置(rowFrames)も捨てる。
        selectedLineIDs = []
        selectionAnchorID = nil
        rowFrames = [:]
        dragSelectionAnchorID = nil
        summary = session.summaryURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        summaryEngine = session.summaryEngine
        let audioURL = session.audioURL
        hasAudio = audioURL != nil
        if forceNewPlayer || player?.hasAudio != true {
            // 前のセッションの再生と読み込みを止めてから差し替える。ビューを使い回すように
            // なったため、ここで畳まないと切り替え後も前の録音が鳴り続ける。
            player?.teardown()
            player = SessionPlayer(audioURL: audioURL, otherURL: session.audioOtherURL)
        }
        loadDecisions()
    }

    /// 検品ブロックの表示行を、所属グループの decisions.json から作り直す。
    /// 所属グループが無いセッションにはそもそも記録先が無いので空のまま。
    /// ファイルが壊れている場合も、画面をエラーで塞がず空のまま(ログにだけ残す)。
    private func loadDecisions() {
        guard let folder = session.folder else {
            decisionRows = []
            return
        }
        do {
            let log = try DecisionLogStore.load(folder: folder)
            decisionRows = DecisionRow.rows(
                from: log, sessionDirectoryName: session.directory.lastPathComponent)
        } catch {
            decisionInspectionLogger.error(
                "decisions.json の読み込みに失敗: \(error.localizedDescription, privacy: .public)")
            decisionRows = []
        }
    }

    /// 「内容を修正…」の保存。書き込みに失敗しても画面は塞がず、ログにだけ残す
    /// (このシートの操作は要約の再生成でいつでも復元できる軽い操作という位置づけのため)。
    private func updateDecision(_ row: DecisionRow, newText: String) {
        guard let folder = session.folder else { return }
        do {
            try DecisionLogStore.updateEntryText(
                folder: folder, sessionDirectoryName: session.directory.lastPathComponent,
                topicID: row.topicID, newText: newText)
        } catch {
            decisionInspectionLogger.error(
                "決定事項の修正に失敗: \(error.localizedDescription, privacy: .public)")
        }
        loadDecisions()
    }

    /// 「記録に残さない」。確認ダイアログは出さない(要約の再生成でいつでも復元できるため)。
    /// 行が消えること自体が視覚的なフィードバックになる。
    private func removeDecision(_ row: DecisionRow) {
        guard let folder = session.folder else { return }
        do {
            try DecisionLogStore.removeEntries(
                folder: folder, sessionDirectoryName: session.directory.lastPathComponent,
                topicID: row.topicID)
        } catch {
            decisionInspectionLogger.error(
                "決定事項の削除に失敗: \(error.localizedDescription, privacy: .public)")
        }
        loadDecisions()
    }

    /// 検品ブロックの時刻チップから文字起こしの該当位置へ移動する。録音があれば
    /// transcriptRow の時刻チップと同じ「その位置から再生」に、録音が無ければ
    /// 質問応答パネルからのジャンプと同じ「収束スクロール + 一時ハイライト」に倣う
    /// (このセッション由来のエントリしか出さないブロックなので、time は必ず
    /// このセッション内の経過秒として解釈できる)。
    private func jumpToTranscript(offsetSeconds: Int) {
        let offset = TimeInterval(offsetSeconds)
        if let player, player.hasAudio {
            followsPlayback = true
            player.playFrom(offset)
            return
        }
        guard let proxy = scrollProxy,
            let lineID = transcriptLineID(at: offset, in: transcriptLines)
        else { return }
        revealCoordinator.reveal(lineID, proxy: proxy)
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

    /// この会話について AI に質問するパネルを開くボタン。エージェント CLI(claude/codex)を
    /// 1つも検出できていなければ、押しても何もできないので出さない
    /// (summarizeButton の availableAgentCLIs 判定と同じパターン)。
    @ViewBuilder
    private var codeImpactButton: some View {
        if !availableAgentCLIs.isEmpty {
            let hasTranscript = !(transcript?.isEmpty ?? true)
            Button {
                model.openCodeImpactPanel(for: session)
            } label: {
                Label("質問", systemImage: "questionmark.bubble")
            }
            .disabled(!hasTranscript)
            .help(hasTranscript ? "この会話について AI に質問します" : "文字起こしがありません")
        }
    }

    /// NSMenu を要約ボタンの直下にポップアップする。項目: オンデバイス、検出済み
    /// エージェント CLI ごと、(関連フォルダ未設定のグループなら)関連フォルダの設定。
    private func popUpSummarizeMenu() {
        guard let anchor = summarizeMenuAnchor else { return }
        let menu = makeHCMenu()

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
                    Task { await ReferenceFolderPicker.pick(forGroup: folder, from: model.mainWindow) }
                case .newGroupFromUnclassified:
                    linkToNewGroup()
                }
            }
            referenceFolderItem.subtitle = "会議に関連する資料やコードを Claude / Codex が読み、誤変換の修正や参加者の前提を踏まえた要約になります"
            menu.addItem(referenceFolderItem)
        }

        popUpMenu(menu, below: anchor)
    }

    // MARK: - 共有

    /// 共有の入り口。渡す相手が HearCat を使っているかどうかで必要なものが違うため、
    /// 「要約の画像」(使っていない人向け)と「セッションの書き出し」(使っている人向け)を
    /// 1つのメニューに並べ、選ぶだけで済むようにする。
    private var shareButton: some View {
        Button {
            popUpShareMenu()
        } label: {
            if exporting {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 4) {
                    // square.and.arrow.up は矢印ぶん字形の箱が縦に高く(実測 18pt、隣のボタンは 15pt)、
                    // Label のままだとボタンの箱が上に膨らんで文字が中心より下に押される。
                    // 高さ 0 の枠でレイアウト高さを文字側に決めさせ、字形は上下にはみ出させる。
                    // Label の外に出すと VoiceOver がシンボル名を英語で読み上げるため、装飾扱いを明示する。
                    Image(systemName: "square.and.arrow.up").frame(height: 0)
                        .accessibilityHidden(true)
                    Text("共有")
                    Image(systemName: "chevron.down").imageScale(.small)
                }
            }
        }
        .disabled(exporting || (summary == nil && transcript == nil && !hasAudio))
        .background(MenuAnchorView(anchor: $shareMenuAnchor))
    }

    private func popUpShareMenu() {
        guard let anchor = shareMenuAnchor else { return }
        let menu = makeHCMenu()

        // 画像は要約があってこそ意味があるため、要約が無いセッションでは選べない。
        for scope in SummaryShareScope.allCases {
            let item = summarizeMenuActionHandler.makeItem(scope.menuTitle) {
                copySummaryImage(scope: scope)
            }
            item.subtitle = scope.menuSubtitle
            item.isEnabled = summary != nil
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let withAudio = summarizeMenuActionHandler.makeItem("セッションを書き出す (録音つき)…") {
            exportSession(includeAudio: true)
        }
        withAudio.subtitle = "相手の HearCat に、文字起こし・要約・録音がそのまま入る"
        withAudio.isEnabled = hasAudio
        menu.addItem(withAudio)

        let textOnly = summarizeMenuActionHandler.makeItem("セッションを書き出す (テキストのみ)…") {
            exportSession(includeAudio: false)
        }
        textOnly.subtitle = "録音を含めないぶん軽い。メールにも添付しやすい"
        textOnly.isEnabled = transcript != nil
        menu.addItem(textOnly)

        popUpMenu(menu, below: anchor)
    }

    private func copySummaryImage(scope: SummaryShareScope) {
        guard let summary else { return }
        do {
            try SummaryShareImage.copyToPasteboard(
                session: session, markdown: summary, scope: scope)
            notifyShare("要約の画像をコピーしました", isError: false)
        } catch {
            notifyShare(error.localizedDescription, isError: true)
        }
    }

    /// 保存先を選ばせてから .hearcat を書き出す。録音を含めると数十 MB になり得るため、
    /// 圧縮は別スレッドで走らせて UI を止めない。
    private func exportSession(includeAudio: Bool) {
        let target = session
        Task {
            guard let destination = await SessionPackagePicker.chooseDestination(
                for: target, from: model.mainWindow)
            else { return }
            exporting = true
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SessionPackage.export(
                        target, includeAudio: includeAudio, to: destination)
                }.value
                notifyShare("\(destination.lastPathComponent) に書き出しました", isError: false)
            } catch {
                notifyShare(error.localizedDescription, isError: true)
            }
            exporting = false
        }
    }

    /// 共有の結果を伝える。成功は用が済んだら自然に消し、失敗は消さずに残す。
    /// 消すのは .task(id:) に任せる(自前のタスクを眠らせると、その間ビューと
    /// 親から渡されたクロージャを掴んだままになる)。
    private func notifyShare(_ message: String, isError: Bool) {
        shareNotice = ShareNotice(message: message, isError: isError)
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
        Task {
            guard let folder = await ReferenceFolderPicker.pickForNewGroup(from: model.mainWindow),
                let newID = model.move(session, toFolder: folder)
            else { return }
            onMove(newID)
        }
    }
}

/// 再生位置から今の行を割り出して控えるだけの、レイアウトに出ないビュー。
///
/// 独立したビューにするのは、`onChange(of:)` に渡す値が「渡した先の body」ではなく
/// 「渡した側の body」の評価中に読まれるため。SessionDetailView のメソッドとして書くと、
/// 0.25 秒ごとに変わる `player.currentTime` への依存が詳細画面そのものに登録され、
/// 再生中は毎秒4回、ヘッダーから文字起こしの全行までが描き直しの対象になる。
private struct PlaybackTracker: View {
    let player: SessionPlayer
    let lines: [TranscriptLine]
    @Binding var currentLineID: TranscriptLine.ID?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: player.currentTime, initial: true) {
                let id = transcriptLineID(at: player.currentTime, in: lines)
                if id != currentLineID { currentLineID = id }
            }
    }
}

/// 指定の経過秒にあたる行。その位置までに始まった最後の行を選ぶ。最初の発話より前
/// (頭出し直後など)は、どの行でもないので nil。offset が nil の行(旧形式ヘッダーの
/// 混入時のみ)は選ばれない。再生位置の追従(PlaybackTracker)と検品ブロックの時刻ジャンプ
/// (jumpToTranscript)が、この「経過秒→行」の規則を共有するための切り出し。
private func transcriptLineID(
    at time: TimeInterval, in lines: [TranscriptLine]
) -> TranscriptLine.ID? {
    lines.last { ($0.offset ?? .infinity) <= time }?.id
}

/// 要約を生成したエンジンのバッジ。「この要約はどのエンジンが作ったか」を後から見ても
/// 分かるようにする(表示のたびに現在の設定から推測せず、生成時点に固定した値を出す。
/// 詳細は SummaryEngine のコメント参照)。
private struct EngineChip: View {
    let engine: SummaryEngine

    var body: some View {
        HCTextChip(text: engine.displayName)
    }
}

/// 選択された行の目印。CurrentLineHighlight・RevealHighlight と同じく、既に
/// 適用済みのパディングを含む content にそのまま background を重ねるだけ(サイズは変えない)。
/// アクセント色にすることで、現在再生行(無彩色の薄い塗り)や一時ハイライト(cinnamon)と
/// 見分けが付くようにする。
private struct LineSelectionHighlight: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if isSelected {
                    HCRadius.shape(HCRadius.chip)
                        .fill(HCColor.accent.opacity(0.16))
                }
            }
    }
}

/// 検索の現在ヒット行の目印。RevealHighlight と違いフェードせず持続点灯する
/// (次のヒットへ移動するまで、または検索バーを閉じるまで点いたまま)。
/// 色は RevealHighlight と同じ cinnamon を使い回す(同時に立つ場面は無い前提)。
private struct SearchMatchHighlight: ViewModifier {
    let isCurrentMatch: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if isCurrentMatch {
                    HCRadius.shape(HCRadius.chip)
                        .fill(HCColor.cinnamon.opacity(0.22))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isCurrentMatch)
    }
}

/// 再生中の行の目印。塗りは色味を持たない薄さにして、話者の色分けと喧嘩させない。
/// 余白は現在行かどうかに関わらず同じにする(行が移るたびに文字が動かないように)。
private struct CurrentLineHighlight: ViewModifier {
    let isCurrent: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .background {
                if isCurrent {
                    HCRadius.shape(HCRadius.chip)
                        .fill(Color.primary.opacity(0.07))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.tint)
                                .frame(width: 3)
                                .padding(.vertical, 2)
                        }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isCurrent)
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
                .font(HCFont.timecode)
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
                // 録音を開き終えるまでは長さが分からない。掴めてしまうと、意味のない
                // 位置へ飛ばせる見た目になるため、その間だけ触れなくする。
                .disabled(!player.isReady)

            Text(formatPlaybackTime(player.duration))
                .font(HCFont.timecode)
                .foregroundStyle(.secondary)

            channelPicker
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// 鳴らす音の選択。相手の音も録ったセッションにしか出さない
    /// (選べるものが1つしかない場面で、意味のない操作対象を増やさない)。
    @ViewBuilder
    private var channelPicker: some View {
        if player.availableChannels.count > 1 {
            Picker("音声", selection: channelBinding) {
                ForEach(player.availableChannels) { channel in
                    Text(channel.label).tag(channel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("聞く声を選べます。会議アプリでマイクを切っていた場面でも、自分の声を拾っていることがあります")
        }
    }

    private var channelBinding: Binding<PlaybackChannel> {
        Binding(get: { player.channel }, set: { player.select($0) })
    }
}

/// 経過時間(分:秒)の表示書式。再生バー(PlayerView)・文字起こしの行(transcriptRow)・
/// ライブ画面(LiveSessionView.elapsedLabel)が、同じ物差し・同じ見た目にするためにこれを共有する
/// (private にしない理由: LiveSessionView.swift からも呼ぶため)。
func formatPlaybackTime(_ time: TimeInterval) -> String {
    let seconds = Int(time.rounded())
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
