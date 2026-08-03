import AppKit
import SwiftUI

/// システム設定のプライバシー系ペインを開く。pane は x-apple.systempreferences の識別子
/// (例: "Privacy_Microphone")。WelcomeView・HealthIssueBanner の両方から使う共通部品。
func openSystemSettings(pane: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    else { return }
    NSWorkspace.shared.open(url)
}

/// SwiftUI のボタンから NSMenu を出すための共通部品。
///
/// SwiftUI の Menu を使わずに NSMenu を自前で出しているのは2つの理由による。
/// 1つは見た目で、Menu はラベルのレイアウト指定を無視して隣のボタンと余白が揃わない
/// (SessionDetailView の要約ボタンのコメント参照)。
/// もう1つは操作で、NSMenu は上下キーでの移動・頭文字での絞り込み・Return での決定・
/// Escape での取り消しを最初から持っている。macOS の「キーボードナビゲーション」が
/// 切られている環境(既定)でもキーボードだけで完結する。

/// ボタンの直下に出すメニューの土台。
/// NSMenu は既定で autoenablesItems = true で、この場合 target/action が有効な
/// 項目は isEnabled への手動代入を無視して常に有効化される。使えない項目が
/// 押せてしまうため、自動有効化を切って isEnabled をそのまま尊重させる。
func makeHCMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    return menu
}

/// メニューをボタンの直下に出す。popUp の指定点はメニューの左上角。素の NSView は
/// isFlipped = false(非 flipped、y=0 が下端)なので、ボタン直下に出すには負のオフセットを
/// 使う。NSHostingView 等の flipped なビューに載る場合は上端 y=0 なので、そちらは
/// 高さぶん下げる。
func popUpMenu(_ menu: NSMenu, below anchor: NSView) {
    let point = anchor.isFlipped
        ? NSPoint(x: 0, y: anchor.bounds.height + 4)
        : NSPoint(x: 0, y: -4)
    menu.popUp(positioning: nil, at: point, in: anchor)
}

/// SwiftUI の Button からは実体の NSView に直接アクセスできないため、透明な NSView を
/// background に仕込んで実体を取り出す。取り出した NSView は NSMenu.popUp(in:) の
/// アンカーに使う(ボタンの直下にメニューを出すため)。
struct MenuAnchorView: NSViewRepresentable {
    @Binding var anchor: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // view はビューが階層に載った後でないと座標系が確定しないため1サイクル遅らせる。
        DispatchQueue.main.async { anchor = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// NSMenuItem の target/action を SwiftUI のクロージャに橋渡しする。NSMenuItem は
/// Objective-C のセレクタ経由でしか反応せずクロージャを直接渡せないため、
/// representedObject にクロージャを積み、共通のセレクタから呼び出す。
/// NSMenuItem は target を弱参照するため、呼び出し側(View)がこのインスタンスを
/// @State 等で強参照し続ける必要がある。
final class MenuActionHandler: NSObject {
    func makeItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        return item
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }
}
