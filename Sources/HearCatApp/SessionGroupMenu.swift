import AppKit
import HearCatKit
import SwiftUI

/// 要約が終わってから実行する移動の予約。folder が nil なら未分類へ戻す。
struct PendingMove: Equatable {
    var folder: String?
}

/// セッション ID が変わったこと。serial が違えば別の変化として扱う。
struct SessionIDChange: Equatable {
    /// 変わる前の ID。同じ処理の中で続けて変わった(改名してすぐ移動など)場合は、途中の ID も含む。
    /// 画面の更新は最後の変化しか見ないため、どの段階の ID を選んでいても新 ID へ張り替えられるようにする。
    var olds: [String]
    var new: String
    var serial: Int

    /// 直前の変化の行き先から続けて変わったなら、途中の ID を引き継ぐ。
    static func next(after previous: SessionIDChange?, old: String, new: String, serial: Int)
        -> SessionIDChange
    {
        let carried = previous.flatMap { $0.new == old ? $0.olds : nil } ?? []
        return SessionIDChange(olds: carried + [old], new: new, serial: serial)
    }
}

enum PendingMoveLogic {
    /// 要約中に行き先が選ばれたときの予約。今のグループと同じ行き先なら予約を取り消す(nil)。
    /// 既にある予約は新しい選択で上書きされる。
    static func reservation(requested: String?, actual: String?) -> PendingMove? {
        requested == actual ? nil : PendingMove(folder: requested)
    }

    /// 選択に旧 ID が含まれるときだけ新 ID へ差し替える。含まれなければ選択はそのまま。
    static func remapSelection(_ selection: Set<String>, olds: [String], new: String) -> Set<String> {
        guard !selection.isDisjoint(with: olds) else { return selection }
        var result = selection.subtracting(olds)
        result.insert(new)
        return result
    }
}

/// 「グループへ移動」メニューの中身の並びと、ボタンの表示名を決める純粋ロジック。
enum SessionGroupMenuLogic {
    /// 今のグループ以外の既存グループ。並びは folders のまま。
    static func moveTargets(folders: [String], current: String?) -> [String] {
        folders.filter { $0 != current }
    }

    /// 「未分類へ戻す」は所属があるときだけ出す。
    static func showsReturnToUnclassified(current: String?) -> Bool {
        current != nil
    }

    /// 予約があるときは行き先を出し、要約のあとに移すことを添える。
    static func label(for folder: String?, pending: PendingMove? = nil, waitingForDrive: Bool = false)
        -> String
    {
        guard let pending else { return "グループ: \(folder ?? "未分類")" }
        let reason = waitingForDrive ? "書き出し" : "要約"
        return "グループ: \(pending.folder ?? "未分類") (\(reason)のあとに移します)"
    }

    /// 新しいグループ名として使える文字列。空・空白だけは nil(何もしない)。
    static func validNewGroupName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// グループ移動の項目(既存グループ・未分類へ戻す・区切り・新しいグループ…)。
/// 右クリックメニューと、メニューバーパネル・詳細画面の Menu で共用する。
@MainActor
@ViewBuilder
func sessionMoveMenuItems(
    for session: SessionInfo,
    current: String?,
    folders: [String],
    onMove: @escaping (SessionInfo, String?) -> Void,
    onNewFolder: @escaping (SessionInfo) -> Void
) -> some View {
    ForEach(
        SessionGroupMenuLogic.moveTargets(folders: folders, current: current), id: \.self
    ) { folder in
        Button(folder) {
            onMove(session, folder)
        }
    }
    if SessionGroupMenuLogic.showsReturnToUnclassified(current: current) {
        Button("未分類へ戻す") {
            onMove(session, nil)
        }
    }
    Divider()
    Button("新しいグループ…") {
        onNewFolder(session)
    }
}

/// 「グループ: ○○ ▾」の Menu。選択肢一覧は自前で組まず NSMenu 裏付けの Menu にする。
/// 移動と新規作成はこのビューが完結させ、移動後の ID を onMoved で返す。
struct SessionGroupMenu: View {
    let model: AppModel
    let session: SessionInfo
    /// ダイアログを出す画面の基準ウィンドウ(呼び出し元の画面に出すため)。
    let anchorWindow: () -> NSWindow?
    let onMoved: (String) -> Void

    private var isRecording: Bool { session.id == model.status.sessionID }
    private var pending: PendingMove? { model.pendingMove(for: session) }
    /// 予約があるときは予約先を「今のグループ」として扱う。今の実グループを選ぶと予約の取り消しになる。
    private var displayedFolder: String? { pending.map(\.folder) ?? session.folder }

    var body: some View {
        Menu {
            sessionMoveMenuItems(
                for: session, current: displayedFolder, folders: model.folders,
                onMove: { session, folder in
                    if let newID = model.move(session, toFolder: folder) { onMoved(newID) }
                },
                onNewFolder: { session in
                    // メニューが閉じ切ってからモーダルを出す。
                    Task { @MainActor in
                        guard
                            let name = NewGroupPrompt.ask(near: anchorWindow()),
                            let newID = model.move(session, toFolder: name)
                        else { return }
                        onMoved(newID)
                    }
                })
        } label: {
            HStack(spacing: 2) {
                Text(
                    SessionGroupMenuLogic.label(
                        for: session.folder, pending: pending,
                        waitingForDrive: !model.isAwaitingSummary(session)
                            && model.driveExports.isRunning(session)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(HCColor.textPrimary)
        .disabled(isRecording)
        .help(isRecording ? "録音中のセッションはグループへ移せません" : "")
        .pointingHandOnHover()
    }
}

/// 新しいグループ名の入力。SwiftUI の .alert はメニューバーパネルの窓(MenuBarExtra)の
/// 上では出せるか保証がないため、NSAlert で出し、基準ウィンドウと同じ画面の中央に置く。
@MainActor
enum NewGroupPrompt {
    /// 入力された名前(前後の空白は除去)。キャンセル・空は nil。
    static func ask(near window: NSWindow?) -> String? {
        let alert = NSAlert()
        alert.messageText = "新しいグループへ移動"
        alert.informativeText = "プロジェクトごとにセッションをまとめられます。"
        alert.addButton(withTitle: "移動")
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "グループ名 (例: プロジェクトA)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        alert.layout()
        let screen = window?.screen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        center(alert.window, on: screen)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard SessionGroupMenuLogic.validNewGroupName(field.stringValue) != nil else { return nil }
        // 作成・改名と同じ検証(日時で始まる予約名など)。弾いた理由は出して終わる。
        do {
            return try SessionStore.validatedFolderName(field.stringValue)
        } catch {
            let failure = NSAlert()
            failure.messageText = "このグループ名は使えません"
            failure.informativeText = error.localizedDescription
            failure.addButton(withTitle: "OK")
            center(failure.window, on: screen)
            failure.runModal()
            return nil
        }
    }

    private static func center(_ target: NSWindow, on screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        let size = target.frame.size
        target.setFrameOrigin(
            NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }
}
