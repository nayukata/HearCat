import AppKit
import HearCatKit
import SwiftUI

/// 履歴ウィンドウ。左にセッション一覧(進行中は先頭に固定)、右に詳細。
/// 左はプロジェクトフォルダでグループ化できる。フォルダは折りたたみ式の行で、
/// セッションのドラッグ&ドロップ、右クリックでの名前変更・削除に対応する。
struct MainWindow: View {
    let model: AppModel
    /// 一覧の選択。単一選択と複数選択(Cmd/Shift+クリック)の両方を扱うため Set で持つ。
    @State private var selection: Set<String> = []
    /// 折りたたんだフォルダ。既定は全部展開。
    @State private var collapsedFolders: Set<String> = []
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

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if selection.contains(Self.liveID), model.status.active {
                LiveSessionView(model: model)
            } else if selection.count == 1, let id = selection.first,
                let session = model.sessions.first(where: { $0.id == id })
            {
                SessionDetailView(model: model, session: session) {
                    selection = []
                }
                // 選択が変わったらプレーヤー等の内部状態を作り直す。
                .id(session.id)
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
            if selection.isEmpty {
                let first = model.status.active ? Self.liveID : model.sessions.first?.id
                if let first { selection = [first] }
            }
        }
        // AppModel からの明示的な選択リクエスト(例: セッション中に履歴を開いた時のライブ選択)。
        // 一方向のリクエストなので、受け取ったら消費して nil に戻す。
        .onChange(of: model.mainWindowSelectionRequest) {
            guard let request = model.mainWindowSelectionRequest else { return }
            selection = [request]
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
                    if collapsedFolders.remove(folder) != nil {
                        collapsedFolders.insert(newName)
                    }
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog(
            "グループ「\(folderDeleteTarget ?? "")」を削除しますか？",
            isPresented: presented($folderDeleteTarget), titleVisibility: .visible,
            presenting: folderDeleteTarget
        ) { folder in
            Button("グループを削除", role: .destructive) {
                if model.deleteFolder(folder) {
                    remapSelection(fromFolder: folder, to: nil)
                    collapsedFolders.remove(folder)
                }
            }
        } message: { _ in
            Text("中のセッションは消えず、未分類へ戻ります。")
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
                if !model.folders.isEmpty {
                    Section("グループ") {
                        ForEach(model.folders, id: \.self) { folder in
                            folderGroup(folder)
                        }
                    }
                }
                // フォルダ分けが始まったら、直下は「未分類」という位置づけになる。
                Section {
                    ForEach(pastSessions.filter { $0.folder == nil }) { session in
                        sessionRow(session)
                    }
                } header: {
                    Text(model.folders.isEmpty ? "履歴" : "未分類")
                        .dropDestination(for: String.self) { ids, _ in
                            _ = moveSessions(ids, toFolder: nil)
                        }
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "名前と本文を検索")
        // 検索中の名前変更や移動で一覧が変わっても、結果が古いまま残らないようにする。
        .onChange(of: searchText) { refreshSearch() }
        .onChange(of: model.sessions) { refreshSearch() }
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

    /// サイドバー下部の常設ボタン。グループ分けできることを見えるようにする。
    private var newFolderBar: some View {
        HStack {
            Button {
                createFolderText = ""
                creatingFolder = true
            } label: {
                Label("新しいグループ", systemImage: "folder.badge.plus")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }

    /// 折りたたみ式のグループ行。中にそのグループのセッションが入る。
    private func folderGroup(_ folder: String) -> some View {
        let sessions = pastSessions.filter { $0.folder == folder }
        return DisclosureGroup(isExpanded: expandedBinding(folder)) {
            ForEach(sessions) { session in
                sessionRow(session)
            }
        } label: {
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
                .badge(sessions.count)
                .contextMenu {
                    Button("グループ名を変更…") {
                        folderRenameText = folder
                        folderRenameTarget = folder
                    }
                    // 関連フォルダの設定はエージェント要約(claude/codex)が使うためのもの。
                    // どちらも検出されていなければ意味のない項目になるため出さない。
                    if !AgentCLIDetector.shared.availableCLIs.isEmpty {
                        if model.settings.referenceFolders[folder] != nil {
                            Button("関連フォルダを変更…") {
                                ReferenceFolderPicker.pick(forGroup: folder)
                            }
                            Button("関連フォルダを解除") {
                                model.settings.referenceFolders.removeValue(forKey: folder)
                            }
                        } else {
                            Button("関連フォルダを設定…") {
                                ReferenceFolderPicker.pick(forGroup: folder)
                            }
                        }
                    }
                    Button("グループを削除…", role: .destructive) {
                        folderDeleteTarget = folder
                    }
                }
                .dropDestination(for: String.self) { ids, _ in
                    _ = moveSessions(ids, toFolder: folder)
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
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary))
        .help(path)
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        SessionRow(session: session)
            .tag(session.id)
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

    /// フォルダ名の変更/削除では中のセッション全部の ID が変わるため、選択を追従させる。
    private func remapSelection(fromFolder old: String, to new: String?) {
        let prefix = "\(old)/"
        selection = Set(selection.map { current -> String in
            guard current.hasPrefix(prefix) else { return current }
            let rest = String(current.dropFirst(prefix.count))
            return new.map { "\($0)/\(rest)" } ?? rest
        })
    }

    private func expandedBinding(_ folder: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(folder) },
            set: { expanded in
                if expanded {
                    collapsedFolders.remove(folder)
                } else {
                    collapsedFolders.insert(folder)
                }
            })
    }

    /// 「対象が入っていたら表示」のダイアログ用 Binding。閉じる時に対象を空にする。
    private func presented<T>(_ target: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { target.wrappedValue != nil },
            set: { if !$0 { target.wrappedValue = nil } })
    }
}

/// 一括削除の確認ダイアログを提供する ViewModifier。MainWindow.body が
/// 型推論のタイムアウトに達したため、修飾子を外へ切り出す。
private struct BulkDeleteConfirmation: ViewModifier {
    @Binding var targets: [SessionInfo]
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            targets.count == 1
                ? "このセッションを削除しますか？"
                : "\(targets.count) 個のセッションを削除しますか？",
            isPresented: Binding(
                get: { !targets.isEmpty },
                set: { if !$0 { targets = [] } }),
            titleVisibility: .visible
        ) {
            Button(
                targets.count == 1 ? "文字起こしと録音を削除" : "\(targets.count) 件を削除",
                role: .destructive, action: onConfirm)
        } message: {
            Text("元に戻せません。文字起こしと録音も一緒に消えます。")
        }
    }
}

/// SwiftUI のビュー階層から NSWindow の実体を取り出す。
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // window はビューが階層に載った後でないと取れないため1サイクル遅らせる。
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 名前があれば名前を主役に、日時は下の行へ。名前がなければ従来どおり日時だけ。
            Text(
                session.name.isEmpty
                    ? session.startDate.formatted(date: .abbreviated, time: .shortened)
                    : session.name)
            HStack(spacing: 6) {
                if !session.name.isEmpty {
                    Text(session.startDate.formatted(date: .numeric, time: .shortened))
                }
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
