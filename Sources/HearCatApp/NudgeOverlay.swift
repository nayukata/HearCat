import AppKit
import Observation
import SwiftUI

/// 会議を邪魔せずに一言だけ確かめるための、常に手前の小さなパネル。
///
/// 会議中に出るものなので、通常ウィンドウにはしない(会議アプリからフォーカスを奪う)。
/// システム通知にもしない(通知の許可が下りていないと黙って出ないため、
/// 「聞いたつもりで聞けていない」状態を作ってしまう)。
///
/// 用途は2つ。どちらも「勝手にやらず、まず確かめる」ためのもの。
/// - 会議が始まる前の、自動で録音を始めてよいかの予告
/// - 無音が続いたときの、セッションを止めてよいかの確認
struct NudgeAction: Identifiable {
    let id = UUID()
    let title: String
    /// 強調して置く方の選択肢(1つだけ)。
    let isPrimary: Bool
    let handler: @MainActor () -> Void

    init(title: String, isPrimary: Bool = false, handler: @escaping @MainActor () -> Void) {
        self.title = title
        self.isPrimary = isPrimary
        self.handler = handler
    }
}

struct NudgePrompt {
    let icon: String
    let title: String
    let detail: String
    /// 残り時間を出す締め切り。nil なら出さない。
    /// 「あと何秒で勝手に始まるのか」が見えないと、予告の意味がないため。
    var deadline: Date?
    var actions: [NudgeAction]
}

/// パネルの表示内容。SwiftUI 側が監視できるよう @Observable の箱に入れる。
@MainActor
@Observable
final class NudgeOverlayState {
    var prompt: NudgePrompt?
}

@MainActor
final class NudgeOverlayController {
    static let shared = NudgeOverlayController()

    private let state: NudgeOverlayState
    private let panel: NSPanel
    /// 選択肢は横1列に並べる。幅が足りないとボタンの文字が2行に折り返して、
    /// 「今後録らない」だけ高さが変わり押し間違えやすくなる。
    /// 内訳(実測、日本語は同梱の Noto Sans JP): 6文字のボタンが3つで約 300pt、
    /// パネルの左右余白 32pt。折り返さない下限は約 340pt だが、字幅は環境で少し動くため
    /// 400pt にして余裕を持たせる。ボタンの文言を長くする時はここも見直す。
    static let size = NSSize(width: 400, height: 178)

    private init() {
        let state = NudgeOverlayState()
        self.state = state
        panel = FloatingPanel.make(
            size: Self.size, title: "HearCat", content: NudgeOverlayView(state: state))
    }

    func present(_ prompt: NudgePrompt) {
        state.prompt = prompt
        positionNearTopRight()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard panel.isVisible else { return }
        state.prompt = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// メニューバーの下、画面の右上に出す。位置は毎回計算し直す
    /// (前回と別のディスプレイで会議していることがあるため)。
    private func positionNearTopRight() {
        guard let screen = Self.targetScreen() else { return }
        panel.setFrameOrigin(
            FloatingPanel.topRightOrigin(of: panel, in: screen, margin: 16))
    }

    /// 確認を出すディスプレイ。ユーザーから呼ばれて出るパネルではないので、
    /// 「今その人が見ている画面」を当てにいく必要がある。
    ///
    /// 最優先はキーボード入力を受けているウィンドウのある画面(NSScreen.main)。
    /// 会議中はその会議アプリを操作している画面がそこになる。マウスの位置を先に
    /// 見ないのは、別のディスプレイにカーソルを置いたまま話していることが普通に
    /// あるため(そこに出すと、話している画面には何も出ないまま気付かれない)。
    private static func targetScreen() -> NSScreen? {
        if let focused = NSScreen.main { return focused }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
    }
}

private struct NudgeOverlayView: View {
    let state: NudgeOverlayState

    var body: some View {
        Group {
            if let prompt = state.prompt {
                content(prompt)
            } else {
                Color.clear
            }
        }
        .frame(
            width: NudgeOverlayController.size.width,
            height: NudgeOverlayController.size.height)
        .background(HCColor.panel)
        .overlay(
            HCRadius.shape(HCRadius.panel)
                .stroke(HCColor.strokeLine, lineWidth: 1))
        .clipShape(HCRadius.shape(HCRadius.panel))
    }

    private func content(_ prompt: NudgePrompt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: prompt.icon)
                    .font(HCFont.title3)
                    .foregroundStyle(HCColor.accentText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.title)
                        .font(HCFont.style(.subheadline, weight: .semibold))
                        .foregroundStyle(HCColor.textPrimary)
                    Text(prompt.detail)
                        .font(HCFont.caption)
                        .foregroundStyle(HCColor.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
            }
            if let deadline = prompt.deadline {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(HCFont.caption)
                    Text(timerInterval: Date.now...deadline, countsDown: true)
                        .font(HCFont.timecode)
                }
                .foregroundStyle(HCColor.accentText)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Spacer()
                ForEach(prompt.actions) { action in
                    if action.isPrimary {
                        Button(action.title, action: action.handler)
                            .buttonStyle(.hcPrimary)
                    } else {
                        Button(action.title, action: action.handler)
                            .buttonStyle(.hcSecondary)
                    }
                }
            }
            // 幅が足りない時は折り返さず、はみ出す方に倒す。折り返すと選択肢ごとに
            // 高さが変わり、並びが崩れて押し間違えやすくなる。
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(16)
    }
}
