import HearCatKit
import SwiftUI

/// 履歴ウィンドウ。左にセッション一覧(進行中は先頭に固定)、右に詳細。
/// 左はプロジェクトフォルダでグループ化できる。フォルダは折りたたみ式の行で、
/// セッションのドラッグ&ドロップ、右クリックでの名前変更・削除に対応する。
struct MainWindow: View {
    let model: AppModel
    @State private var selection: String?
    /// 折りたたんだフォルダ。既定は全部展開。
    @State private var collapsedFolders: Set<String> = []

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

    private static let liveID = "live"

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if selection == Self.liveID, model.status.active {
                LiveSessionView(model: model)
            } else if let session = model.sessions.first(where: { $0.id == selection }) {
                SessionDetailView(model: model, session: session) {
                    selection = nil
                }
                // 選択が変わったらプレーヤー等の内部状態を作り直す。
                .id(session.id)
            } else {
                ContentUnavailableView(
                    "セッションを選択",
                    systemImage: "eye",
                    description: Text("左の一覧からセッションを選ぶと、文字起こしと録音をここで確認できます。"))
            }
        }
        .background(WindowAccessor { window in
            model.mainWindow = window
        })
        .onAppear {
            model.refreshSessions()
            if selection == nil {
                selection = model.status.active ? Self.liveID : model.sessions.first?.id
            }
        }
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
            "新しいフォルダへ移動", isPresented: presented($newFolderTarget),
            presenting: newFolderTarget
        ) { session in
            TextField("フォルダ名 (例: プロジェクトA)", text: $newFolderText)
            Button("移動") {
                select(model.move(session, toFolder: newFolderText))
            }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("プロジェクトごとにセッションをまとめられます。")
        }
        .alert("新しいフォルダ", isPresented: $creatingFolder) {
            TextField("フォルダ名 (例: プロジェクトA)", text: $createFolderText)
            Button("作成") {
                model.createFolder(createFolderText)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("セッションはドラッグ&ドロップか右クリックでフォルダへ移せます。")
        }
        .alert(
            "フォルダ名を変更", isPresented: presented($folderRenameTarget),
            presenting: folderRenameTarget
        ) { folder in
            TextField("フォルダ名", text: $folderRenameText)
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
            "フォルダ「\(folderDeleteTarget ?? "")」を削除しますか？",
            isPresented: presented($folderDeleteTarget), titleVisibility: .visible,
            presenting: folderDeleteTarget
        ) { folder in
            Button("フォルダを削除", role: .destructive) {
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
            if model.status.active {
                Section("進行中") {
                    Label("ライブ", systemImage: "dot.radiowaves.left.and.right")
                        .tag(Self.liveID)
                }
            }
            if !model.folders.isEmpty {
                Section("フォルダ") {
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
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            newFolderBar
        }
    }

    /// サイドバー下部の常設ボタン。フォルダ分けできることを見えるようにする。
    private var newFolderBar: some View {
        HStack {
            Button {
                createFolderText = ""
                creatingFolder = true
            } label: {
                Label("新しいフォルダ", systemImage: "folder.badge.plus")
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

    /// 折りたたみ式のフォルダ行。中にそのフォルダのセッションが入る。
    private func folderGroup(_ folder: String) -> some View {
        let sessions = pastSessions.filter { $0.folder == folder }
        return DisclosureGroup(isExpanded: expandedBinding(folder)) {
            ForEach(sessions) { session in
                sessionRow(session)
            }
        } label: {
            Label(folder, systemImage: "folder")
                .badge(sessions.count)
                .contextMenu {
                    Button("フォルダ名を変更…") {
                        folderRenameText = folder
                        folderRenameTarget = folder
                    }
                    Button("フォルダを削除…", role: .destructive) {
                        folderDeleteTarget = folder
                    }
                }
                .dropDestination(for: String.self) { ids, _ in
                    _ = moveSessions(ids, toFolder: folder)
                }
        }
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        SessionRow(session: session)
            .tag(session.id)
            .draggable(session.id)
            .contextMenu {
                Button("名前を変更…") {
                    renameText = session.name
                    renameTarget = session
                }
                Menu("フォルダへ移動") {
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
                    Button("新しいフォルダ…") {
                        newFolderText = ""
                        newFolderTarget = session
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

    /// リネーム/移動でセッション ID が変わるため、成功したら選択を追従させる。
    private func select(_ id: String?) {
        if let id { selection = id }
    }

    /// フォルダ名の変更/削除では中のセッション全部の ID が変わるため、選択を追従させる。
    private func remapSelection(fromFolder old: String, to new: String?) {
        guard let current = selection, current.hasPrefix("\(old)/") else { return }
        let rest = String(current.dropFirst(old.count + 1))
        selection = new.map { "\($0)/\(rest)" } ?? rest
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
