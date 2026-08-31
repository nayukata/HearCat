import AppKit
import HearCatKit
import SwiftUI

/// 履歴ウィンドウ。左にセッション一覧(進行中は先頭に固定)、右に詳細。
/// 左はプロジェクトフォルダでグループ化できる。フォルダは見出し1行だけで中身は展開せず、
/// 中身を見るにはグループ画面(右ペイン)を開く。フォルダの行はセッションのドラッグ&ドロップ、
/// 右クリックでの名前変更・削除に対応する。未分類セッションは開始日時で日付区分に分けて出す。
struct MainWindow: View {
    let model: AppModel
    /// 一覧の選択。単一選択と複数選択(Cmd/Shift+クリック)の両方を扱うため Set で持つ。
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: Set<String> = []
    /// 未分類の日付区分ごとの折りたたみ状態。既定は今日・昨日・今週が展開、
    /// 今月・それ以前が折りたたみ(init で計算、永続化はしない)。
    @State private var collapsedDateSections: Set<DateBucket>
    /// collapsedDateSections を最後に既定へ計算し直した日。ウィンドウを開いたまま日付が
    /// 変わると「今日」「昨日」の区分の中身が入れ替わるため、この値と実際の日付がずれたら
    /// 既定を計算し直す(同じ日のうちはユーザーの開閉操作を上書きしない)。
    @State private var dateSectionsDay: Date
    /// ドラッグ中にドロップ先として狙われているグループ。行のハイライトに使う
    /// (自前の dropDestination は List 標準の挿入インジケータが出ないため、自前で見せる)。
    @State private var dropTargetFolder: String?
    /// いまグループをドラッグ中なら、そのグループ名。ドラッグの種類 (グループの並べ替えか、
    /// セッションの移動か) で見せる表示を変えるために、ドラッグ開始時に記録する。
    /// ドロップ処理の完了時に必ず nil に戻す (キャンセル時は次のドロップまで残り得るが、
    /// 表示が一瞬変わるだけで動作は壊れない)。
    @State private var draggingFolder: String?
    /// 並べ替えのドロップ先として狙われているグループ (このグループの前に挿し込む)。
    @State private var insertionTargetFolder: String?
    /// 末尾への挿入 (未分類ヘッダー) が狙われているか。
    @State private var insertionTargetEnd = false
    /// 挿入線を消す予約。行間の隙間で targeting が一瞬 false になっても、すぐ次の行に
    /// 入るなら消さないためのデバウンス。
    @State private var insertionClearTask: DispatchWorkItem?
    /// 全文検索。入力中はフォルダ構造の代わりに横断ヒットの一覧を出す。
    @State private var searchText = ""
    @State private var searchResults: [SessionInfo] = []

    // ダイアログの対象と入力値。target が nil でない間だけ表示される。
    @State private var renameTarget: SessionInfo?
    @State private var renameText = ""
    @State private var newFolderTarget: SessionInfo?
    @State private var newFolderText = ""
    @State private var creatingFolder = false
    @State private var createFolderText = ""
    @State private var folderRenameTarget: String?
    @State private var folderRenameText = ""
    @State private var folderDeleteTarget: String?
    /// 一括削除の確認対象。空でない間だけ確認ダイアログが出る。
    @State private var deletingSessions: [SessionInfo] = []

    /// ライブ行の選択タグ。AppModel からも選択リクエストの値として参照するため internal にする。
    static let liveID = "live"

    /// グループ行のドラッグを、セッション行のドラッグ (session.id) と見分けるための接頭辞。
    /// セッション ID はディレクトリ名由来でこの形にならない。
    private static let folderDragPrefix = "folder-reorder:"

    private static func folderName(fromDragPayload payload: String) -> String? {
        guard payload.hasPrefix(folderDragPrefix) else { return nil }
        return String(payload.dropFirst(folderDragPrefix.count))
    }

    /// グループ選択の選択タグ接頭辞。セッション ID (ディレクトリ名由来) やライブ ID とは
    /// 形が被らないようにする (folderDragPrefix とは別物: こちらは List の selection、
    /// 上はドラッグ&ドロップのペイロード)。
    private static let groupSelectionPrefix = "group:"

    static func groupSelectionTag(_ folder: String) -> String {
        groupSelectionPrefix + folder
    }

    private static func groupName(fromSelectionTag tag: String) -> String? {
        guard tag.hasPrefix(groupSelectionPrefix) else { return nil }
        return String(tag.dropFirst(groupSelectionPrefix.count))
    }

    /// 未分類セッションを開始日時で振り分ける区分。並び順がそのまま表示順になる。
    private enum DateBucket: CaseIterable, Hashable {
        case today, yesterday, thisWeek, thisMonth, older

        var title: String {
            switch self {
            case .today: return "今日"
            case .yesterday: return "昨日"
            case .thisWeek: return "今週"
            case .thisMonth: return "今月"
            case .older: return "それ以前"
            }
        }
    }

    /// 選ばれたセッションが入っている日付区分を開く。取り込んだセッションは録音した
    /// 日時で並ぶため、既定で畳まれている「今月」「それ以前」に落ちると、選択された
    /// はずの行が一覧に現れない。
    private func expandDateSection(forSessionID id: String) {
        guard let session = model.sessions.first(where: { $0.id == id }),
              session.folder == nil
        else { return }
        collapsedDateSections.remove(Self.dateBucket(for: session.startDate))
    }

    private static func dateBucket(for date: Date, now: Date = Date()) -> DateBucket {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return .thisMonth }
        return .older
    }

    /// 今日・昨日・今週がすべて0件なら、最初に中身のある区分(今月→それ以前の順)を
    /// 開いた状態にする。それ以外は今日・昨日・今週だけ開いた既定に従う。
    private static func initialCollapsedDateSections(unclassified: [SessionInfo]) -> Set<DateBucket> {
        var collapsed: Set<DateBucket> = [.thisMonth, .older]
        let buckets = unclassified.map { dateBucket(for: $0.startDate) }
        let hasRecent = buckets.contains { [.today, .yesterday, .thisWeek].contains($0) }
        if !hasRecent {
            for bucket: DateBucket in [.thisMonth, .older] where buckets.contains(bucket) {
                collapsed.remove(bucket)
                break
            }
        }
        return collapsed
    }

    init(model: AppModel) {
        self.model = model
        let unclassified = model.sessions.filter {
            $0.id != model.status.sessionID && $0.folder == nil
        }
        _collapsedDateSections = State(
            initialValue: Self.initialCollapsedDateSections(unclassified: unclassified))
        _dateSectionsDay = State(initialValue: Calendar.current.startOfDay(for: Date()))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if selection.contains(Self.liveID), model.status.active {
                LiveSessionView(model: model)
            } else if selection.count == 1, let id = selection.first,
                let folder = Self.groupName(fromSelectionTag: id)
            {
                GroupDetailView(model: model, folder: folder, onSelectSession: { select($0) })
            } else if selection.count == 1, let id = selection.first,
                let session = model.sessions.first(where: { $0.id == id })
            {
                // ここで .id(session.id) を付けてビューごと作り直さない。作り直すと
                // 選択のたびにビュー階層とアクセシビリティのノードまで全部再構築になり、
                // 文字を差し替えるだけの切り替えが目に見えて遅くなる(実測でレイアウトが
                // 主要因)。セッション固有の状態は SessionDetailView 側が
                // .task(id: session.id) で畳み直す。
                SessionDetailView(
                    model: model, session: session,
                    onDelete: { selection = [] },
                    onMove: { select($0) })
            } else if selection.count > 1 {
                ContentUnavailableView(
                    "\(selection.count) 件のセッションを選択中",
                    systemImage: "text.bubble",
                    description: Text(
                        "右クリックまたは delete キーで、まとめて削除できます。"))
            } else {
                ContentUnavailableView(
                    "セッションを選択",
                    systemImage: "text.bubble",
                    description: Text("左の一覧からセッションを選ぶと、文字起こしと録音をここで確認できます。"))
            }
        }
        .background(WindowAccessor { window in
            model.mainWindow = window
        })
        .onAppear {
            model.refreshSessions()
            // ウィンドウがまだ無いうちに届いた選択リクエスト(閉じている状態から
            // パネル経由で開いた場合)は onChange では拾えないため、ここで消費する。
            if let request = model.mainWindowSelectionRequest {
                selection = [request]
                expandDateSection(forSessionID: request)
                model.mainWindowSelectionRequest = nil
            } else if selection.isEmpty {
                let first = model.status.active ? Self.liveID : model.sessions.first?.id
                if let first { selection = [first] }
            }
        }
        // AppModel からの明示的な選択リクエスト(例: セッション中に履歴を開いた時のライブ選択)。
        // 一方向のリクエストなので、受け取ったら消費して nil に戻す。
        .onChange(of: model.mainWindowSelectionRequest) {
            guard let request = model.mainWindowSelectionRequest else { return }
            selection = [request]
            expandDateSection(forSessionID: request)
            model.mainWindowSelectionRequest = nil
        }
        // ライブ画面を見ている最中に停止すると status.active が false になり、
        // そのままだと selection がライブの ID を指し続けてプレースホルダに落ちる。
        // 今終わったセッションの詳細へ自然に遷移させる。
        .onChange(of: model.status.active) {
            if !model.status.active, selection.contains(Self.liveID) {
                selection = model.lastEndedSessionID.map { [$0] } ?? []
            }
        }
        .onDeleteCommand(perform: requestDeletion)
        .modifier(BulkDeleteConfirmation(
            targets: $deletingSessions,
            onConfirm: performDeletion))
        .modifier(SessionImportPresentation(model: model))
        .alert(
            "セッション名を変更", isPresented: presented($renameTarget), presenting: renameTarget
        ) { session in
            TextField("名前 (例: 定例会議)", text: $renameText)
            Button("変更") {
                select(model.rename(session, to: renameText))
            }
            Button("キャンセル", role: .cancel) {}
        } message: { session in
            // 日時はセッション名とは別に管理していて変わらないことを伝える。
            Text("開始日時 (\(session.startDate.formatted(date: .abbreviated, time: .shortened))) はそのまま、フォルダとファイルの名前に反映されます。空にすると名前を外します。")
        }
        .alert(
            "新しいグループへ移動", isPresented: presented($newFolderTarget),
            presenting: newFolderTarget
        ) { session in
            TextField("グループ名 (例: プロジェクトA)", text: $newFolderText)
            Button("移動") {
                select(model.move(session, toFolder: newFolderText))
            }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("プロジェクトごとにセッションをまとめられます。")
        }
        .alert("新しいグループ", isPresented: $creatingFolder) {
            TextField("グループ名 (例: プロジェクトA)", text: $createFolderText)
            Button("作成") {
                model.createFolder(createFolderText)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("セッションはドラッグ&ドロップか右クリックでグループへ移せます。")
        }
        .alert(
            "グループ名を変更", isPresented: presented($folderRenameTarget),
            presenting: folderRenameTarget
        ) { folder in
            TextField("グループ名", text: $folderRenameText)
            Button("変更") {
                if let newName = model.renameFolder(folder, to: folderRenameText) {
                    remapSelection(fromFolder: folder, to: newName)
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog(
            "グループ「\(folderDeleteTarget ?? "")」を削除しますか？",
            isPresented: presented($folderDeleteTarget), titleVisibility: .visible,
            presenting: folderDeleteTarget
        ) { folder in
            Button("グループだけ削除", role: .destructive) {
                deleteFolder(folder, withSessions: false)
            }
            // 破壊ボタンには既定では Return が割り当てられない。安全な側(セッションを残す)
            // を Enter で選べるようにする。
            .keyboardShortcut(.defaultAction)
            let count = pastSessions.filter { $0.folder == folder }.count
            if count > 0 {
                Button("セッションも削除 (\(count) 件)", role: .destructive) {
                    deleteFolder(folder, withSessions: true)
                }
            }
        } message: { folder in
            Text(folderDeleteMessage(folder))
        }
    }

    // MARK: - サイドバー

    private var sidebar: some View {
        List(selection: $selection) {
            if isSearching {
                searchSection
            } else {
                if model.status.active {
                    Section("進行中") {
                        Label("ライブ", systemImage: "dot.radiowaves.left.and.right")
                            .tag(Self.liveID)
                    }
                }
                Section("グループ") {
                    if model.folders.isEmpty {
                        Text("下の「新しいグループ」から作れます")
                            .foregroundStyle(.tertiary)
                            .font(HCFont.caption)
                    } else {
                        ForEach(model.folders, id: \.self) { folder in
                            folderGroup(folder)
                        }
                    }
                }
                unclassifiedSection(pastSessions.filter { $0.folder == nil })
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "名前と本文を検索")
        // 検索中の名前変更や移動で一覧が変わっても、結果が古いまま残らないようにする。
        .onChange(of: searchText) { refreshSearch() }
        .onChange(of: model.sessions) { refreshSearch() }
        // 一覧が動くたびに日付が変わっていないか見る。ウィンドウを開いたままにしていると
        // 「今日」「昨日」の中身が日をまたいで入れ替わるため、そのときだけ開閉を既定へ戻す。
        .onChange(of: model.sessionsVersion) { resetDateSectionsIfDayChanged() }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            newFolderBar
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func refreshSearch() {
        searchResults = isSearching ? pastSessions.filter { $0.matches(searchText) } : []
    }

    /// 検索中はフォルダをまたいだフラットな結果一覧に切り替える。
    private var searchSection: some View {
        Section("検索結果") {
            if searchResults.isEmpty {
                Text("一致するセッションがありません")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(searchResults) { session in
                    sessionRow(session)
                }
            }
        }
    }

    /// 未分類節。セッションが1件もなければ案内文だけ、未分類が0件で全部フォルダ入りなら
    /// 節ごと隠す(ただしフォルダの並べ替えドラッグ中は末尾受け皿として見出しだけ出す)、
    /// それ以外は開始日時で分けた区分ごとにセッションを並べる。
    @ViewBuilder
    private func unclassifiedSection(_ unclassified: [SessionInfo]) -> some View {
        if pastSessions.isEmpty {
            Section {
                Text("録音したセッションがここに並びます")
                    .foregroundStyle(.tertiary)
                    .font(HCFont.caption)
            } header: {
                unclassifiedHeader
            }
        } else if !unclassified.isEmpty {
            Section {
                ForEach(DateBucket.allCases, id: \.self) { bucket in
                    let sessions = unclassified.filter { Self.dateBucket(for: $0.startDate) == bucket }
                    if !sessions.isEmpty {
                        dateSectionHeader(bucket, count: sessions.count)
                        if !collapsedDateSections.contains(bucket) {
                            ForEach(sessions) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
            } header: {
                unclassifiedHeader
            }
        } else if draggingFolder != nil {
            Section {
            } header: {
                unclassifiedHeader
            }
        }
    }

    /// 未分類節の見出し。グループの並べ替えでは「このグループの後ろが無い = 末尾へ」の
    /// 受け皿を兼ねる。
    private var unclassifiedHeader: some View {
        Text("未分類")
            .dropDestination(for: String.self) { ids, _ in
                debugLog("dnd " + "drop on=end ids=\(ids)")
                defer { endFolderDrag() }
                if let dragged = ids.compactMap(Self.folderName(fromDragPayload:)).first {
                    return moveFolderToEnd(dragged)
                }
                return moveSessions(ids, toFolder: nil)
            } isTargeted: { targeting in
                debugLog("dnd " +
                    "target end targeting=\(targeting) dragging=\(draggingFolder ?? "nil")")
                guard draggingFolder != nil else { return }
                setInsertionTarget(nil, end: true, targeting: targeting)
            }
            .overlay(alignment: .top) {
                if insertionTargetEnd {
                    Capsule().fill(HCColor.cinnamon).frame(height: 2.5)
                        .offset(y: -3)
                }
            }
    }

    /// 日付区分の小見出し。クリックで開閉する。閉じているときだけ件数を薄く出す
    /// (開いているときは中の行が件数の代わりになる)。
    private func dateSectionHeader(_ bucket: DateBucket, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(collapsedDateSections.contains(bucket) ? 0 : 90))
                .foregroundStyle(.secondary)
                .font(HCFont.caption)
                .frame(width: 16, height: 16)
            Text(bucket.title)
                .foregroundStyle(.secondary)
            Spacer()
            if collapsedDateSections.contains(bucket) {
                Text("\(count)")
                    .font(HCFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { toggleDateSection(bucket) } }
        .pointingHandOnHover()
    }

    private func toggleDateSection(_ bucket: DateBucket) {
        if collapsedDateSections.contains(bucket) {
            collapsedDateSections.remove(bucket)
        } else {
            collapsedDateSections.insert(bucket)
        }
    }

    /// 開いたままのウィンドウで日付が変わったら、日付区分の開閉を既定に計算し直す。
    private func resetDateSectionsIfDayChanged() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != dateSectionsDay else { return }
        dateSectionsDay = today
        let unclassified = pastSessions.filter { $0.folder == nil }
        collapsedDateSections = Self.initialCollapsedDateSections(unclassified: unclassified)
    }

    /// サイドバー下部の常設ボタン。グループ分けできることと、
    /// 受け取ったセッションをここから取り込めることを見えるようにする。
    private var newFolderBar: some View {
        HStack {
            Button {
                createFolderText = ""
                creatingFolder = true
            } label: {
                Label("新しいグループ", systemImage: "folder.badge.plus")
                    .font(HCFont.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .pointingHandOnHover()
            Spacer()
            Button {
                model.requestImportFromPanel()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(HCFont.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("受け取ったセッション (.hearcat) を取り込む")
            .pointingHandOnHover()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }

    /// グループの見出し行1行だけを出す(サイドバーではグループの中身を展開しない。
    /// 中身を見るにはグループ画面を開く)。
    private func folderGroup(_ folder: String) -> some View {
        let count = pastSessions.filter { $0.folder == folder }.count
        return folderHeader(folder, count: count)
    }

    /// グループの見出し行。フォルダ名、関連フォルダ chip、件数 badge を持つ。
    /// 行をクリックするとグループ画面を選択する。
    /// ドラッグ&ドロップ(並べ替え・セッションの受け入れ)と右クリックメニューはこの行に付く。
    private func folderHeader(_ folder: String, count: Int) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(folder)
                // どのグループに関連フォルダが設定済みかをサイドバーで一目で
                // 分かるようにする。badge(セッション数)と喧嘩しないよう、
                // タイトル側の HStack に収めて右端は badge に譲る。
                if let path = model.settings.referenceFolders[folder] {
                    referenceFolderChip(path: path)
                }
            }
        } icon: {
            Image(systemName: "folder")
        }
        .badge(count)
        // tag は List の選択ハイライト表示用。ただしドラッグ元の行は List のクリック選択が
        // 効かないため、実際の選択は下の onTapGesture が selection を直接書いて行う
        // (接頭辞 group: は folderDragPrefix (ドラッグのペイロード) とは別物)。
        .tag(Self.groupSelectionTag(folder))
        .contentShape(Rectangle())
        // 行名クリックでグループ画面を選択する。onTapGesture なのは、この行が
        // ドラッグ元(.onDrag)でもあり、そこでは List 任せのクリック選択が死ぬため。
        .onTapGesture { selection = [Self.groupSelectionTag(folder)] }
        .pointingHandOnHover()
        // ドラッグ元は contentShape の後ろに置き、名前ラベルだけでなく行のどこからでも
        // 掴めるようにする。onDrag なのは、draggable(_:preview:) がログ上ドロップ判定を
        // 一切発火させなかったため (プレビュー付き draggable はペイロード登録が壊れる疑い)。
        .onDrag {
            draggingFolder = folder
            debugLog("dnd " + "ondrag folder=\(folder)")
            return NSItemProvider(object: (Self.folderDragPrefix + folder) as NSString)
        } preview: {
            // ドラッグ中に「何を掴んでいるか」を見せるチップ。fixedSize が無いと名前が省略される。
            Label(folder, systemImage: "folder")
                .font(HCFont.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    HCRadius.shape(HCRadius.chip)
                        .fill(colorScheme == .dark ? HCColor.mistDarkSurface : HCColor.mistLightSurface))
                .foregroundStyle(colorScheme == .dark ? HCColor.mistWhite : HCColor.mistDark)
                .fixedSize()
        }
        .contextMenu {
            Button("グループ名を変更…") {
                folderRenameText = folder
                folderRenameTarget = folder
            }
            Button("上へ移動") { swapFolderOrder(folder, offset: -1) }
                .disabled(model.folders.first == folder)
            Button("下へ移動") { swapFolderOrder(folder, offset: 1) }
                .disabled(model.folders.last == folder)
            // 関連フォルダの設定はエージェント要約(claude/codex)が使うためのもの。
            // どちらも検出されていなければ意味のない項目になるため出さない。
            if !AgentCLIDetector.shared.availableCLIs.isEmpty {
                if model.settings.referenceFolders[folder] != nil {
                    Button("関連フォルダを変更…") {
                        Task { await ReferenceFolderPicker.pick(forGroup: folder, from: model.mainWindow) }
                    }
                    Button("関連フォルダを解除") {
                        model.settings.referenceFolders.removeValue(forKey: folder)
                    }
                } else {
                    // ラベルは機能名(関連フォルダ)でなく効能(要約精度が上がる)で語る。
                    // 「関連フォルダ」という名前だけでは初見で何が嬉しいか伝わらないため。
                    Button("資料フォルダと紐付けて要約精度を上げる…") {
                        Task { await ReferenceFolderPicker.pick(forGroup: folder, from: model.mainWindow) }
                    }
                }
            }
            Button("グループを削除…", role: .destructive) {
                folderDeleteTarget = folder
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            debugLog("dnd " + "drop on=\(folder) ids=\(ids)")
            defer { endFolderDrag() }
            if let dragged = ids.compactMap(Self.folderName(fromDragPayload:)).first {
                return insertFolder(dragged, onto: folder)
            }
            return moveSessions(ids, toFolder: folder)
        } isTargeted: { targeting in
            debugLog("dnd " + 
                "target folder=\(folder) targeting=\(targeting) dragging=\(draggingFolder ?? "nil")")
            // グループのドラッグなら挿入線、セッションのドラッグなら行の塗りを出す。
            if draggingFolder != nil {
                guard insertionEdge(for: folder) != nil else { return }
                setInsertionTarget(folder, targeting: targeting)
            } else {
                if targeting {
                    dropTargetFolder = folder
                } else if dropTargetFolder == folder {
                    dropTargetFolder = nil
                }
            }
        }
        .listRowBackground(
            dropTargetFolder == folder
                ? HCRadius.shape(HCRadius.chip).fill(HCColor.cinnamon.opacity(0.22))
                : nil)
        // 挿入線。行として挟むと List が最低高さを取って行間が開くため、行の上縁/下縁に重ねる。
        .overlay(alignment: .top) {
            if insertionTargetFolder == folder, insertionEdge(for: folder) == .top {
                insertionLine.offset(y: -3)
            }
        }
        .overlay(alignment: .bottom) {
            if insertionTargetFolder == folder, insertionEdge(for: folder) == .bottom {
                insertionLine.offset(y: 3)
            }
        }
    }

    /// 関連フォルダが設定済みのグループに添える控えめな chip。中身は関連フォルダの
    /// 末尾のパス要素(例: 「atnd」)で、フルパスは .help(ツールチップ)で見せる。
    private func referenceFolderChip(path: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "link")
            Text(URL(fileURLWithPath: path).lastPathComponent)
        }
        .font(HCFont.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary))
        .help(path)
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        SessionRow(session: session, sessionsVersion: model.sessionsVersion)
            .tag(session.id)
            // 実績のある素の draggable に戻す (プレビュー付きはドロップ判定が死んだ)。
            // ドラッグ開始のフックは onDrag 側 (グループ行) にしか無いため、
            // 直前のグループドラッグがキャンセルされていた場合の記録消しはここでは行わない。
            .draggable(session.id)
            .contextMenu {
                // 複数選択中に選択内の行を右クリックした場合は、選択全体を対象にする。
                // それ以外(未選択の行の右クリック)は、その行だけを対象にする。
                let bulkTargets = selection.count > 1 && selection.contains(session.id)
                    ? model.sessions.filter { selection.contains($0.id) }
                    : nil

                Button("名前を変更…") {
                    renameText = session.name
                    renameTarget = session
                }
                .disabled(bulkTargets != nil)
                Menu("グループへ移動") {
                    ForEach(model.folders.filter { $0 != session.folder }, id: \.self) { folder in
                        Button(folder) {
                            select(model.move(session, toFolder: folder))
                        }
                    }
                    if session.folder != nil {
                        Button("未分類へ戻す") {
                            select(model.move(session, toFolder: nil))
                        }
                    }
                    Divider()
                    Button("新しいグループ…") {
                        newFolderText = ""
                        newFolderTarget = session
                    }
                }
                .disabled(bulkTargets != nil)
                Divider()
                if let bulkTargets {
                    Button("\(bulkTargets.count) 件を削除…", role: .destructive) {
                        deletingSessions = bulkTargets
                    }
                } else {
                    Button("削除…", role: .destructive) {
                        deletingSessions = [session]
                    }
                }
            }
    }

    // MARK: - 操作の下請け

    /// 進行中のセッションは「ライブ」行で見せるため、履歴一覧からは除く。
    private var pastSessions: [SessionInfo] {
        model.sessions.filter { $0.id != model.status.sessionID }
    }

    /// ドラッグ&ドロップで受け取ったセッション ID をフォルダへ移す。
    private func moveSessions(_ ids: [String], toFolder folder: String?) -> Bool {
        debugLog("dnd " + "move-sessions ids=\(ids) to=\(folder ?? "nil")")
        var moved = false
        for id in ids {
            guard let session = model.sessions.first(where: { $0.id == id }),
                  session.folder != folder
            else { continue }
            select(model.move(session, toFolder: folder))
            moved = true
        }
        return moved
    }

    /// Delete キーが押された時と、行の右クリック「削除」から呼ぶ、削除確認の発火。
    private func requestDeletion() {
        let targets = model.sessions.filter { selection.contains($0.id) }
        if !targets.isEmpty { deletingSessions = targets }
    }

    /// 確認ダイアログの「削除」ボタンから呼ぶ、実削除と選択の追従。
    private func performDeletion() {
        let ids = Set(deletingSessions.map(\.id))
        for session in deletingSessions {
            model.delete(session)
        }
        selection.subtract(ids)
        deletingSessions = []
    }

    /// リネーム/移動でセッション ID が変わるため、成功したら選択を追従させる。
    /// 単一選択の枠(選択解除→対象を選び直す)は多選択時と混ざらないように独立で扱う。
    private func select(_ id: String?) {
        if let id { selection = [id] }
    }

    /// グループ削除の確認で見せる説明。件数の数え方は「セッションも削除」ボタンと
    /// 揃える(録音中のセッションは消さないので、どちらでも数に入れない)。
    private func folderDeleteMessage(_ folder: String) -> String {
        let recording = model.sessions.contains {
            $0.folder == folder && $0.id == model.status.sessionID
        }
        var text = ""
        if pastSessions.contains(where: { $0.folder == folder }) {
            text = "「グループだけ削除」なら、中のセッションは消えず未分類へ戻ります。"
                + "「セッションも削除」を選ぶと、文字起こしと録音も一緒に消えます。元に戻せません。"
        } else if !recording {
            text = "このグループにセッションは入っていません。"
        }
        if recording {
            text += "録音中のセッションは消さず、未分類へ戻します。"
        }
        return text
    }

    /// グループ削除の実行と、選択の後始末。
    private func deleteFolder(_ folder: String, withSessions: Bool) {
        let deleted = Set(
            pastSessions.filter { $0.folder == folder }.map(\.id))
        guard model.deleteFolder(folder, deletingSessions: withSessions) else { return }
        if withSessions { selection.subtract(deleted) }
        remapSelection(fromFolder: folder, to: nil)
        // グループ画面を開いたまま削除した場合の後始末。外さないと、消えたはずの
        // グループの画面が右に残り続ける。
        selection.remove(Self.groupSelectionTag(folder))
    }

    /// フォルダ名の変更/削除では中のセッション全部の ID が変わるため、選択を追従させる。
    private func remapSelection(fromFolder old: String, to new: String?) {
        let prefix = "\(old)/"
        selection = Set(selection.map { current -> String in
            guard current.hasPrefix(prefix) else { return current }
            let rest = String(current.dropFirst(prefix.count))
            return new.map { "\($0)/\(rest)" } ?? rest
        })
    }

    /// ドラッグ終了時の後始末。ドロップを受けた場所によらず、並べ替え関連の状態を全部戻す。
    private func endFolderDrag() {
        draggingFolder = nil
        insertionTargetFolder = nil
        insertionTargetEnd = false
        insertionClearTask?.cancel()
        insertionClearTask = nil
    }

    /// 挿入線の表示先を切り替える。行と行の隙間はどの行の判定にも入らないため、
    /// targeting=false を素直に反映すると行をまたぐたびに線が消えて点滅する。
    /// 消す方だけ 0.15 秒遅らせ、その間に次の行へ入ったら消さない。
    private func setInsertionTarget(_ folder: String?, end: Bool = false, targeting: Bool) {
        if targeting {
            insertionClearTask?.cancel()
            insertionClearTask = nil
            insertionTargetFolder = folder
            insertionTargetEnd = end
        } else {
            guard insertionTargetFolder == folder, insertionTargetEnd == end else { return }
            let task = DispatchWorkItem {
                if insertionTargetFolder == folder, insertionTargetEnd == end {
                    insertionTargetFolder = nil
                    insertionTargetEnd = false
                }
            }
            insertionClearTask?.cancel()
            insertionClearTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
        }
    }

    /// 乗せ先に対して、ドラッグ元がどちら側から来たか。上から来たなら .bottom (後ろに入る)、
    /// 下から来たなら .top (前に入る)。自分自身や不明なら nil。
    private func insertionEdge(for folder: String) -> VerticalEdge? {
        guard let dragging = draggingFolder,
            let from = model.folders.firstIndex(of: dragging),
            let to = model.folders.firstIndex(of: folder), from != to
        else { return nil }
        return from < to ? .bottom : .top
    }

    private var insertionLine: some View {
        Capsule().fill(HCColor.cinnamon).frame(height: 2.5)
    }

    /// ドラッグしたグループを乗せ先の位置へ挿し込む。上から来たら乗せ先の後ろ、
    /// 下から来たら乗せ先の前 (挿入線の表示位置と一致させる)。
    private func insertFolder(_ name: String, onto target: String) -> Bool {
        guard name != target else {
            debugLog("dnd " + "insert-reject same")
            return false
        }
        var order = model.folders
        guard let from = order.firstIndex(of: name),
            let to = order.firstIndex(of: target)
        else {
            debugLog("dnd " + "insert-reject missing")
            return false
        }
        order.remove(at: from)
        // remove で from より後ろが1つ詰まるため、from < to のときの to は「乗せ先の後ろ」を指す。
        order.insert(name, at: to)
        guard order != model.folders else {
            debugLog("dnd " + "insert-reject no-change")
            return false
        }
        debugLog("dnd " + "reorder \(name) onto \(target) -> \(order)")
        model.reorderFolders(order)
        return true
    }

    /// ドラッグしたグループを末尾へ回す (未分類ヘッダーへのドロップ)。
    private func moveFolderToEnd(_ name: String) -> Bool {
        var order = model.folders
        guard let from = order.firstIndex(of: name) else {
            debugLog("dnd " + "move-to-end-reject from-missing")
            return false
        }
        order.remove(at: from)
        order.append(name)
        guard order != model.folders else {
            debugLog("dnd " + "move-to-end-reject no-change")
            return false
        }
        debugLog("dnd " + "move-to-end \(name) -> \(order)")
        model.reorderFolders(order)
        return true
    }

    /// フォルダの並び順を1つ前後に入れ替える。先頭/末尾での呼び出しは右クリックメニュー側の
    /// disabled で防いでいるが、範囲外を渡されても何もしないだけにしておく。
    private func swapFolderOrder(_ folder: String, offset: Int) {
        guard let index = model.folders.firstIndex(of: folder) else { return }
        let target = index + offset
        guard model.folders.indices.contains(target) else { return }
        var order = model.folders
        order.swapAt(index, target)
        model.reorderFolders(order)
    }

}

/// 「対象が入っていたら表示」のダイアログ用 Binding。閉じる時に対象を空にする。
/// 対象を持つ形のダイアログは全部これを通す(閉じた時の後始末の作法を1つに保つため)。
@MainActor
func presented<T>(_ target: Binding<T?>) -> Binding<Bool> {
    Binding(
        get: { target.wrappedValue != nil },
        set: { if !$0 { target.wrappedValue = nil } })
}

/// セッション削除の確認で見せる文言。サイドバーからの一括削除と詳細画面の削除の
/// 2箇所から出るため、同じ操作なのに「何が消えるか」の説明が場所によって違わないよう
/// 1箇所にまとめる(詳細画面側は説明が薄く、消える中身が伝わっていなかった)。
enum SessionDeletionCopy {
    static func title(count: Int) -> String {
        count == 1 ? "このセッションを削除しますか？" : "\(count) 個のセッションを削除しますか？"
    }

    static func confirmButton(count: Int) -> String {
        count == 1 ? "文字起こしと録音を削除" : "\(count) 件を削除"
    }

    static let message = "元に戻せません。文字起こしと録音も一緒に消えます。"
}

/// 一括削除の確認ダイアログを提供する ViewModifier。MainWindow.body が
/// 型推論のタイムアウトに達したため、修飾子を外へ切り出す。
private struct BulkDeleteConfirmation: ViewModifier {
    @Binding var targets: [SessionInfo]
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            SessionDeletionCopy.title(count: targets.count),
            isPresented: Binding(
                get: { !targets.isEmpty },
                set: { if !$0 { targets = [] } }),
            titleVisibility: .visible
        ) {
            Button(
                SessionDeletionCopy.confirmButton(count: targets.count),
                role: .destructive, action: onConfirm)
                // 破壊ボタンは既定では Return が割り当てられず、Enter を押しても
                // ビープ音だけになる。キーボードで確定したい要望により明示的に既定にする
                // (Esc のキャンセルは confirmationDialog の標準挙動のまま)。
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(SessionDeletionCopy.message)
        }
    }
}

/// SwiftUI のビュー階層から NSWindow の実体を取り出す。
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // window はビューが階層に載った後でないと取れない。載るまでの時間は状況で変わり、
        // 1サイクル待ちでは間に合わず nil を掴んだまま取り直せないことがあった
        // (ようこそ画面の「はじめる」が close 先を失って空振りした)。取れるまで
        // 1サイクルずつ待ち直す。上限は、結局ウィンドウに載らなかった場合の打ち切り。
        func resolve(remaining: Int) {
            DispatchQueue.main.async {
                if let window = view.window {
                    onResolve(window)
                } else if remaining > 0 {
                    resolve(remaining: remaining - 1)
                }
            }
        }
        resolve(remaining: 120)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SessionRow: View {
    /// 名前が付いていないセッションのタイトル欄に出す文言。詳細画面と揃える。
    static let untitledPlaceholder = "名称未設定"

    let session: SessionInfo
    /// 一覧の版数。要約は停止したあと少し遅れて出来上がるため、一覧が更新されたら
    /// プレビューを問い合わせ直す(取り置きがあれば読み直しは起きない)。
    let sessionsVersion: Int

    /// 要約(無ければ文字起こし)の先頭1行。読み込み中と、読めるものが無い時は nil。
    @State private var preview: String?

    /// プレビューを取り直すきっかけ。セッションが変わった時と、一覧が更新された時。
    private struct PreviewKey: Equatable {
        let id: String
        let version: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 名前は「付けるもの」、開始日時は「常に残るもの」として、上下の役割を固定する。
            // 名前が無いときだけ日時をタイトル欄に出す作りは、日時がタイトルそのものに
            // 見えるため「名前を付けたら日時が分からなくなる」という誤解を生んでいた。
            // 未設定はプレースホルダの薄字にして、空欄であることを見せる。
            if session.name.isEmpty {
                Text(SessionRow.untitledPlaceholder)
                    .foregroundStyle(.tertiary)
            } else {
                Text(session.name)
            }
            HStack(spacing: 6) {
                Text(session.startDate.formatted(date: .numeric, time: .shortened))
                if session.transcriptURL != nil {
                    Image(systemName: "text.quote")
                }
                if session.audioURL != nil {
                    Image(systemName: "waveform")
                }
                if session.summaryURL != nil {
                    Image(systemName: "list.bullet.rectangle")
                }
            }
            .font(HCFont.caption)
            .foregroundStyle(.secondary)
            // 何の話だったかの手がかり。名前を付けていないセッションは日時しか
            // 手がかりが無く、1件ずつ開いて確かめることになるため。
            // 読めるものが無いセッションでは行を足さない(空行で高さだけ変えない)。
            if let preview, !preview.isEmpty {
                Text(preview)
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
        .task(id: PreviewKey(id: session.id, version: sessionsVersion)) {
            preview = await SessionPreviewCache.shared.preview(for: session)
        }
    }
}
