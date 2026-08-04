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
            // doc.on.doc と checkmark は SF Symbols 上の横幅が異なり、Image を単純に
            // 差し替えるとボタン自身の確保領域が変わって周囲がわずかに動く
            // (Spacer の反対側に置かれた要素でも、ボタンの見た目上の位置が揺れて見える)。
            // 両方を重ねて同じ固定フレームに収め、opacity だけを切り替えることで
            // 確保領域を状態に関わらず一定にする。
            ZStack {
                Image(systemName: "doc.on.doc")
                    .opacity(copied ? 0 : 1)
                Image(systemName: "checkmark")
                    .opacity(copied ? 1 : 0)
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .pointingHandOnHover()
        .help("コピー")
    }
}
