import AppKit
import SwiftUI

/// 会議中に手前へ出す非アクティブパネルの共通の作り。
///
/// 会議を邪魔しないための性質をここに集約する。
/// - 会議アプリからフォーカスを奪わない(.nonactivatingPanel)
/// - フルスクリーンの会議アプリや別の操作スペースの上にも出る
/// - 枠と背景は SwiftUI 側で描くため、AppKit 側は透過にしてタイトルバーを隠す
///
/// 閉じるボタンを付けないのは意図的。Cmd+W や × が NSPanel の close() を直接呼ぶと、
/// 各パネルが持つ後片付け(実行中の処理の取り消しなど)を素通りするため、
/// 閉じる導線は各コントローラ側に持たせる。
@MainActor
enum FloatingPanel {
    /// - Parameter resizable: true にすると、ユーザーがウィンドウ端をドラッグして
    ///   大きさを変えられるようにする(`contentMinSize` も併せて設定)。既定は false で、
    ///   他のパネルの挙動(固定サイズ)は変わらない。
    static func make(
        size: NSSize, title: String, content: some View, resizable: Bool = false
    ) -> NSPanel {
        var styleMask: NSWindow.StyleMask = [
            .titled, .fullSizeContentView, .utilityWindow, .nonactivatingPanel,
        ]
        if resizable {
            styleMask.insert(.resizable)
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false)
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let hostingController = NSHostingController(rootView: content)
        if resizable {
            panel.contentMinSize = NSSize(width: 460, height: 360)
            // 既定では NSHostingController が SwiftUI 側の理想サイズにウィンドウを引き戻そうとする。
            // リサイズ可能にした意味が無くなるため、この場合だけそれを止める。
            hostingController.sizingOptions = []
        }
        panel.contentViewController = hostingController
        // contentViewController を載せるとウィンドウの大きさは中身に合わせて決まる。
        // 位置決めの前に確定させておかないと、枠(タイトルバー分)を数えそこねてずれる。
        panel.setContentSize(size)
        return panel
    }

    /// 画面の右上に置くときの原点。画面は呼び出し側が選ぶ
    /// (どの画面に出すべきかは、そのパネルが何をきっかけに出るかで変わるため)。
    static func topRightOrigin(
        of panel: NSPanel, in screen: NSScreen, margin: CGFloat
    ) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.maxX - panel.frame.width - margin,
            y: visible.maxY - panel.frame.height - margin)
    }
}

extension NSScreen {
    /// マウスカーソルのある画面(取得できなければメイン画面)。ホットキーで自分から呼ぶ
    /// パネル(CodeImpactOverlayController)や、呼び出し元のウィンドウが分からないファイル
    /// パネル(FilePanel)など、「呼んだ瞬間の注意が向いている画面」に出したい場面で使う
    /// 共通ヘルパー(元は各所に同じ NSEvent.mouseLocation + NSScreen.screens.first の
    /// スニペットが重複していた)。
    @MainActor
    static var hcScreenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }
}

/// 非アクティブパネル(NudgeOverlayController / CodeImpactOverlayController)の
/// 開閉アニメーションの状態機械。フェード + 上下移動、世代ガード付き completionHandler、
/// 定位置(restingOrigin)の管理をここへ1本化する(元は両コントローラにほぼ同文で複製されていた)。
/// どこに置くか(位置決めポリシー)は呼び出し側の各コントローラが決めて target として渡す
/// ため、ここには持たない。
@MainActor
@Observable
final class FloatingPanelMotion {
    /// 開閉演出の対象パネル。この型を観測する SwiftUI content は panel より先に組み立てる
    /// 必要がある(NSHostingController に content を渡す時点で、observable な参照が既に
    /// 要る)一方、対象パネル自体は FloatingPanel.make の戻り値でしか手に入らないため、
    /// init 直後に attach(to:) で渡す2段構えにしている。
    private var panel: NSPanel!
    /// フェードのために位置を上下させるので、確定位置(定位置)を別に保持する。
    private(set) var restingOrigin: NSPoint?
    /// open/close を呼ぶたびに増やす世代カウンタ。close の completionHandler は
    /// 発火時にこれが自分の世代と一致するかを見て、後から呼ばれた open に
    /// 追い越されていないかを確かめる(閉じアニメーション中に開き直された場合、
    /// 古い completionHandler が新しい表示を消してしまわないように)。
    private var animationGeneration = 0
    /// 閉じアニメーションの最中かどうか。open はこれを見て、閉じかけのパネルへは
    /// 「表示中への合流」ではなく「非表示からの開き直し」で応じる。呼び出し側の
    /// 位置決めポリシーも、閉じ中の補間座標を定位置として採用しない判断にこれを使う。
    private(set) var isClosing = false
    /// NSPanel の show/close は同じ SwiftUI View インスタンスを表示・非表示にするだけで、
    /// .onAppear は初回設置時にしか発火しない。open が実際にパネルを開くたびにここを
    /// インクリメントし、View 側は .onChange で拾って登場スケールアニメーション
    /// (revealScale(trigger:))を毎回再生する。
    var revealTick = 0

    func attach(to panel: NSPanel) {
        self.panel = panel
    }

    /// パネルを target へ向けて開く。既に表示中(閉じかけでない)なら内容差し替え経路として
    /// 前面化のみ行い、登場演出は再生しない(false を返す)。それ以外は「下から・alpha 0」の
    /// フェードインを再生する(true を返す)。
    @discardableResult
    func open(target: NSPoint, makeKey: Bool) -> Bool {
        animationGeneration += 1
        if !isClosing && panel.isVisible {
            // 既に表示中なら、位置を維持したまま前面へ戻すだけ(連打で毎回フェードし直さない)。
            panel.orderFrontRegardless()
            if makeKey { panel.makeKey() }
            return false
        }
        // 閉じかけのパネルへの open は、中途半端な alpha からでも
        // 「非表示から開く」経路へ合流させる(下から・alpha 0 のフェードイン)。
        isClosing = false
        restingOrigin = target
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - HCMotion.panelRise))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // orderFrontRegardless は前面に出すだけでキーウィンドウにしない。makeKey が
        // 必要な呼び出し側(質問パネル等)は、開いた瞬間から入力欄に打てるよう明示的に
        // キーにする(.nonactivatingPanel なので、キーにしても会議アプリからアプリごと
        // フォーカスを奪うことはない)。
        if makeKey { panel.makeKey() }
        revealTick += 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = HCMotion.panelOpenDuration
            ctx.timingFunction = HCMotion.panelOpenTiming
            panel.animator().alphaValue = 1
            panel.animator().setFrame(
                NSRect(origin: target, size: panel.frame.size), display: true)
        }
        return true
    }

    /// パネルを閉じる。completionHandler は世代ガードを通ったときだけ発火し、
    /// cleanup(呼び出し側固有の後片付け)→ orderOut → 位置復元 → alpha 復元 → isClosing
    /// 解除の順で行う。
    func close(cleanup: @escaping @MainActor () -> Void) {
        guard panel.isVisible else { return }
        animationGeneration += 1
        let gen = animationGeneration
        isClosing = true
        let currentOrigin = panel.frame.origin
        let exitOrigin = NSPoint(x: currentOrigin.x, y: currentOrigin.y + HCMotion.panelRise)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = HCMotion.panelCloseDuration
            ctx.timingFunction = HCMotion.panelCloseTiming
            panel.animator().alphaValue = 0
            panel.animator().setFrame(
                NSRect(origin: exitOrigin, size: panel.frame.size), display: true)
        } completionHandler: { [weak self] in
            // NSAnimationContext の完了ハンドラは main thread で呼ばれるが Sendable 扱いなので、
            // main actor 分離を明示して panel(@MainActor)へ触れるようにする。
            MainActor.assumeIsolated {
                guard let self else { return }
                // 世代が変わっていたら、後から呼ばれた open がこの閉じるを追い越している。
                // 表示の後片付けはその open 側の役目なので、ここでは何もしない。
                guard gen == self.animationGeneration else { return }
                cleanup()
                self.panel.orderOut(nil)
                // 次回の open でまた「下から」始められるよう、位置と alpha を復元する。
                if let resting = self.restingOrigin {
                    self.panel.setFrameOrigin(resting)
                }
                self.panel.alphaValue = 1
                self.isClosing = false
            }
        }
    }
}

/// パネル登場のスケール演出(1 → 通常表示)。trigger の変化のたびに 0.965 へ戻してから
/// 1 へアニメーションし直す(NSPanel の再表示では .onAppear が毎回発火しないため、
/// 呼び出し側(FloatingPanelMotion.revealTick)からの合図で毎回再生する)。
private struct RevealScale: ViewModifier {
    let trigger: Int
    @State private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .top)
            .onChange(of: trigger) {
                guard !reduceMotion else { return }
                // scale = 0.965 だけを withAnimation なしで書くと、直後の
                // withAnimation(scale = 1) と同じ描画コミットにまとめられてしまい、
                // 0.965 が一度も画面に出ないまま 1 へ飛ぶことがある(View が使い回されて
                // ツリー再生成による @State リセットが起きないため)。Transaction で
                // 明示的にアニメーション無効の書き込みとして確定させ、次のランループで
                // 改めて 1 へアニメーションすることで、中間値の描画を確実に挟む。
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { scale = 0.965 }
                Task { @MainActor in
                    withAnimation(HCMotion.panelIn) { scale = 1 }
                }
            }
    }
}

extension View {
    /// パネル登場時のスケール演出を適用する。trigger(通常は FloatingPanelMotion.revealTick)が
    /// 変化するたびに再生する。
    func revealScale(trigger: Int) -> some View {
        modifier(RevealScale(trigger: trigger))
    }
}
