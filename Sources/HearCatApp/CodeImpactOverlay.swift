import AppKit
import SwiftUI

/// 会議中の作業を中断せずに結果を見られる、常に手前の非アクティブパネル。
/// 通常ウィンドウを開かないため、ホットキーを押しても会議アプリからフォーカスを奪わない。
///
/// 見せ場「気配のように現れる」: パネルを表示する瞬間は、そこに居たかのように
/// 少し下から浮き上がってフェードイン(200ms 前後)、閉じるときは逆再生。
/// ぱっと出す・ぱっと消すのは主旨(そっと寄り添う)と噛み合わないためやらない。
@MainActor
final class CodeImpactOverlayController {
    private let panel: NSPanel
    private var positioned = false
    /// フェードのために位置を上下させるので、確定位置(定位置)を別に保持する。
    private var restingOrigin: NSPoint?
    /// フェードの初期オフセット(下から現れる高さ)。閉じるときも同じ量だけ上へ抜ける。
    private static let entryOffsetY: CGFloat = 6

    init(model: AppModel) {
        // 閉じるボタンを持たないのは FloatingPanel の方針どおり。このパネルでは特に、
        // Cmd+W や × が NSPanel の close() を直接呼ぶと SwiftUI 側の onExitCommand →
        // dismissCodeImpactOverlay を経由せず、codeImpactTask(claude/codex サブプロセス)が
        // キャンセルされないまま裏で走り続ける。閉じる導線は、ヘッダー右上の × ボタンと
        // onExitCommand(Esc)、フッターの ⌘W 相当のショートカットに集約する。
        panel = FloatingPanel.make(
            size: NSSize(width: 520, height: 480),
            title: "関連資料との照合",
            content: CodeImpactOverlayView(model: model))
    }

    func show() {
        if !positioned || !isPanelOnVisibleScreen() {
            positionNearTopRight()
            positioned = true
        }
        // 既に表示中なら、位置を維持したまま前面へ戻すだけ(連打で毎回フェードし直さない)。
        if panel.isVisible {
            panel.orderFrontRegardless()
            return
        }
        let target = panel.frame.origin
        restingOrigin = target
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - Self.entryOffsetY))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(
                NSRect(origin: target, size: panel.frame.size), display: true)
        }
    }

    func close() {
        guard panel.isVisible else { return }
        let currentOrigin = panel.frame.origin
        let exitOrigin = NSPoint(x: currentOrigin.x, y: currentOrigin.y + Self.entryOffsetY)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(
                NSRect(origin: exitOrigin, size: panel.frame.size), display: true)
        } completionHandler: { [weak self] in
            // NSAnimationContext の完了ハンドラは main thread で呼ばれるが Sendable 扱いなので、
            // main actor 分離を明示して panel(@MainActor)へ触れるようにする。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                // 次回の show でまた「下から」始められるよう、位置と alpha を復元する。
                if let resting = self.restingOrigin {
                    self.panel.setFrameOrigin(resting)
                }
                self.panel.alphaValue = 1
            }
        }
    }

    /// 現在のパネル位置が、マウスカーソルのある画面(なければメイン画面)の
    /// visibleFrame と交差しているか。false ならパネルは画面外に居る。
    private func isPanelOnVisibleScreen() -> Bool {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return false }
        return visibleFrame.intersects(panel.frame)
    }

    /// このパネルはユーザーがホットキーで自分から呼ぶため、マウスのある画面に出す
    /// (呼んだ瞬間の注意はカーソルの近くにある)。
    private func positionNearTopRight() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        panel.setFrameOrigin(
            FloatingPanel.topRightOrigin(of: panel, in: screen, margin: 24))
    }
}

/// パネル本体のビュー。Raycast 風の 3 段構成(ヘッダー / 入力欄 / 結果 / フッター)。
///
/// 入力欄は常時表示するが、実際に受け付ける操作は状態に応じて変わる:
/// - idle / requiresConsent / failed で送信 → 新規調査(consent が必要なら requiresConsent へ)
/// - completed で送信 → 直前の結果を context にした追加質問
/// - analyzing 中は入力欄を無効化(2 重リクエストの抑止)
private struct CodeImpactOverlayView: View {
    let model: AppModel
    @State private var input: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Rectangle().fill(HCColor.mistDivider).frame(height: 1)
            inputField
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            Rectangle().fill(HCColor.mistDivider).frame(height: 1)
            content
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)
            Spacer(minLength: 0)
            Rectangle().fill(HCColor.mistDividerStrong).frame(height: 1)
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .frame(width: 520, height: 480)
        .background(HCColor.mistDark)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HCColor.mistDarkStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onExitCommand { model.dismissCodeImpactOverlay() }
        .onAppear { inputFocused = true }
    }

    // MARK: - ヘッダー

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(HCColor.mistDarkSurface)
                    .frame(width: 18, height: 18)
                Circle()
                    .stroke(HCColor.cinnamonStroke, lineWidth: 1)
                    .frame(width: 18, height: 18)
                Text("?")
                    .font(HCFont.system(size: 10, weight: .semibold))
                    .foregroundStyle(HCColor.cinnamon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("関連資料との照合")
                    .font(HCFont.style(.subheadline, weight: .semibold))
                    .foregroundStyle(HCColor.mistWhite)
                Text("会議中に追加で質問できます")
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.mistWhiteDim)
            }
            Spacer()
            Button {
                model.dismissCodeImpactOverlay()
            } label: {
                Image(systemName: "xmark")
                    .font(HCFont.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(HCColor.mistWhiteDim)
            }
            .buttonStyle(.plain)
            .help("閉じる (Esc)")
        }
    }

    // MARK: - 入力欄

    private var inputField: some View {
        HStack(spacing: 10) {
            Text("›")
                .font(HCFont.system(size: 14, weight: .regular))
                .foregroundStyle(HCColor.mistPlaceholder)
            TextField(inputPlaceholder, text: $input)
                .textFieldStyle(.plain)
                .font(HCFont.callout)
                .foregroundStyle(HCColor.mistBody)
                .focused($inputFocused)
                .disabled(!canAcceptInput)
                .onSubmit { submit() }
            Spacer()
            keyCap("⌘ ↩")
                .opacity(canAcceptInput ? 1 : 0.35)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(HCColor.mistDarkSurface))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(inputFocused ? HCColor.cinnamonStroke : HCColor.mistDarkStroke,
                        lineWidth: inputFocused ? 1.2 : 1))
    }

    private var inputPlaceholder: String {
        switch model.codeImpactAnalysisState {
        case .completed:
            return "追加で聞きたいこと (例: v1 廃止の期限は文字起こしに出た?)"
        case .analyzing:
            return "調査中…"
        default:
            return "聞きたいこと (空のまま ⌘↩ で直近の会話を調査)"
        }
    }

    private var canAcceptInput: Bool {
        if case .analyzing = model.codeImpactAnalysisState { return false }
        return true
    }

    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch model.codeImpactAnalysisState {
        case .completed where !trimmed.isEmpty:
            model.requestFollowUpCodeImpact(question: trimmed)
            input = ""
        case .analyzing:
            break
        default:
            // 初回調査。空でも走らせて OK (デフォルトの調査プロンプトで動く)。
            model.requestCodeImpactAnalysis()
            input = ""
        }
    }

    // MARK: - 結果(state 別)

    @ViewBuilder
    private var content: some View {
        switch model.codeImpactAnalysisState {
        case .idle:
            idlePlaceholder
        case .requiresConsent(let cli):
            consentView(cli: cli)
        case .analyzing(let cli):
            analyzingView(cli: cli)
        case .completed(let cli, let result):
            completedView(cli: cli, result: result)
        case .failed(let error):
            failedView(error: error)
        }
    }

    private var idlePlaceholder: some View {
        messageBlock(
            icon: "sparkle.magnifyingglass",
            title: "気配だけ残して、そっと調べます",
            detail: "上の欄に聞きたいことを打つか、空のまま ⌘↩ で直近の会話を調査します。")
    }

    private func consentView(cli: AgentCLI) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            messageBlock(
                icon: "lock.shield",
                title: "初回のみ確認が必要です",
                detail: "文字起こしと紐付けた資料フォルダを \(cli.displayName) が読み取ります。コードは変更しません。")
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("閉じる") { model.dismissCodeImpactOverlay() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(HCColor.mistBody)
                Button {
                    model.confirmCodeImpactAnalysis(using: cli)
                } label: {
                    Text("同意して調べる")
                        .font(HCFont.style(.callout, weight: .semibold))
                        .foregroundStyle(HCColor.mistDark)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(HCColor.cinnamon))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func analyzingView(cli: AgentCLI) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(HCColor.cinnamon)
            Text("\(cli.displayName) が調査中")
                .font(HCFont.style(.subheadline, weight: .semibold))
                .foregroundStyle(HCColor.mistWhite)
            Text("直近の文字起こしと必要なコードだけを読み取っています")
                .font(HCFont.caption)
                .foregroundStyle(HCColor.mistWhiteDim)
            Button("中止") { model.cancelCodeImpactAnalysis() }
                .buttonStyle(.plain)
                .font(HCFont.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(HCColor.mistWhiteDim)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(HCColor.mistDarkStroke, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func completedView(cli: AgentCLI, result: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(HCColor.cinnamon).frame(width: 6, height: 6)
                Text("\(cli.displayName) · 直近の文字起こしを調査")
                    .font(HCFont.style(.footnote, weight: .semibold))
                    .foregroundStyle(HCColor.cinnamon)
                Spacer()
                CopyButton { result }
            }
            ScrollView {
                markdownResult(result)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func failedView(error: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            messageBlock(icon: "exclamationmark.triangle", title: "調査できませんでした", detail: error)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button {
                    model.requestCodeImpactAnalysis()
                } label: {
                    Text("再試行")
                        .font(HCFont.style(.callout, weight: .semibold))
                        .foregroundStyle(HCColor.mistDark)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(HCColor.cinnamon))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func messageBlock(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(HCFont.title3)
                .foregroundStyle(HCColor.cinnamon)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(HCFont.style(.subheadline, weight: .semibold))
                    .foregroundStyle(HCColor.mistWhite)
                Text(detail)
                    .font(HCFont.callout)
                    .foregroundStyle(HCColor.mistWhiteDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - フッター(キーバインドヒント)

    private var footer: some View {
        HStack(spacing: 6) {
            keyCap("⌘ ↩")
            Text("送信")
                .font(HCFont.footnote)
                .foregroundStyle(HCColor.mistWhiteDim)
                .padding(.trailing, 10)
            keyCap("⌘ C")
            Text("コピー")
                .font(HCFont.footnote)
                .foregroundStyle(HCColor.mistWhiteDim)
                .padding(.trailing, 10)
            keyCap("Esc")
            Text("閉じる")
                .font(HCFont.footnote)
                .foregroundStyle(HCColor.mistWhiteDim)
            Spacer()
            if case .completed(let cli, _) = model.codeImpactAnalysisState {
                Text("追加質問できます · \(cli.displayName)")
                    .font(HCFont.footnote)
                    .foregroundStyle(HCColor.mistWhiteDim)
            }
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(HCFont.monospaced(size: 11))
            .foregroundStyle(HCColor.mistKeyText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(HCColor.mistKeyCap))
    }

    // MARK: - 簡易 Markdown レンダー

    /// `## セクション` 見出しと本文段落だけを含むエージェント出力を、
    /// 見出しは cinnamon アクセント・本文は mistBody で表示する簡易 Markdown 描画。
    /// 要約側の SummaryParser は 4 セクション固定のスキーマ判定で流用できないため、
    /// この画面専用の最小実装を持つ。
    @ViewBuilder
    private func markdownResult(_ raw: String) -> some View {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let text = String(line)
                if text.hasPrefix("## ") {
                    Text(String(text.dropFirst(3)))
                        .font(HCFont.style(.callout, weight: .semibold))
                        .foregroundStyle(HCColor.cinnamon)
                        .padding(.top, 6)
                } else if text.hasPrefix("### ") {
                    Text(String(text.dropFirst(4)))
                        .font(HCFont.style(.footnote, weight: .semibold))
                        .foregroundStyle(HCColor.mistWhite)
                        .padding(.top, 2)
                } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Spacer().frame(height: 2)
                } else {
                    Text(inlineMarkdown(text))
                        .font(HCFont.callout)
                        .foregroundStyle(HCColor.mistBody)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 行内の Markdown 装飾(**強調** など)だけを解釈する。ブロック要素は上の
    /// markdownResult 側で扱うため inlineOnly に絞る。
    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
