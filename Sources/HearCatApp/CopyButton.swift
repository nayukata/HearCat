import AppKit
import SwiftUI

/// クリップボードへコピーする共通ボタン。要約と文字起こしのコピーで見た目とフィードバックを
/// 揃えるために切り出した(押した直後だけ checkmark に変わり、しばらくして doc.on.doc に戻る)。
/// text はボタンが押された時点の最新の内容を取れるよう、値ではなくクロージャで受け取る。
struct CopyButton: View {
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("コピー")
    }
}
