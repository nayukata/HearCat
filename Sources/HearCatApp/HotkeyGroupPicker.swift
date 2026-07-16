import AppKit
import HearCatKit
import SwiftUI

/// ホットキーでセッションを開始する直前に、グループ(プロジェクトフォルダ)を選ばせる
/// 小さい画面。ホットキー起動はどのウィンドウの手前でも割り込むため、SwiftUI の
/// alert/confirmationDialog(特定のビュー階層に属する)ではなく、独立して呼べる
/// NSAlert + SwiftUI アクセサリで組む。
enum HotkeyGroupPicker {
    /// 選択結果。folder は選ばれたグループ(nil は未分類)。
    struct Result {
        var folder: String?
        var skipNextTime: Bool
    }

    /// グループを選ばせる。ESC・キャンセルの場合は nil を返し、呼び出し側は
    /// セッション開始自体を中止すること。NSAlert.runModal は同期呼び出しのため、
    /// この関数はメインスレッドをブロックする(=ユーザーの選択を待つ、が期待通りの挙動)。
    @MainActor
    static func choose(defaultGroup: String?) -> Result? {
        let folders = SessionStore.listFolders()
        let state = PickerState(selection: defaultGroup)

        let alert = NSAlert()
        alert.messageText = "どのグループに入れますか？"
        alert.informativeText = "このセッションの保存先グループを選んでください。"
        alert.addButton(withTitle: "開始")
        alert.addButton(withTitle: "キャンセル")
        alert.accessoryView = NSHostingView(
            rootView: PickerAccessoryView(folders: folders, state: state))

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Result(folder: state.selection, skipNextTime: state.skipNextTime)
    }
}

/// NSHostingView に載せる状態。SwiftUI の Binding を NSAlert 側から読み出すための橋渡し。
@MainActor
private final class PickerState: ObservableObject {
    @Published var selection: String?
    @Published var skipNextTime = false

    init(selection: String?) {
        self.selection = selection
    }
}

private struct PickerAccessoryView: View {
    let folders: [String]
    @ObservedObject var state: PickerState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("グループ", selection: $state.selection) {
                Text("未分類").tag(String?.none)
                ForEach(folders, id: \.self) { folder in
                    Text(folder).tag(String?.some(folder))
                }
            }
            Toggle("次回からこの選択をスキップ", isOn: $state.skipNextTime)
        }
        .padding(.vertical, 8)
        .frame(width: 280)
    }
}
