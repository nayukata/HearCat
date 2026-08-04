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
            content: CodeImpactOverlayView(model: model),
            resizable: true)
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
        .frame(minWidth: 460, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HCColor.mistDark)
        .overlay(
            HCRadius.shape(HCRadius.panel)
                .stroke(HCColor.mistDarkStroke, lineWidth: 1))
        .clipShape(HCRadius.shape(HCRadius.panel))
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
                    .font(HCFont.style(.caption1, weight: .semibold))
                    .foregroundStyle(HCColor.cinnamon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("関連資料との照合")
                    .font(HCFont.style(.subheadline, weight: .semibold))
                    .foregroundStyle(HCColor.mistWhite)
                Text("質問に答えます。空のまま送信で直近の会話を調査")
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.mistWhiteDim)
            }
            Spacer()
            Button {
                model.dismissCodeImpactOverlay()
            } label: {
                Image(systemName: "xmark")
                    .font(HCFont.style(.callout, weight: .semibold))
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
                .font(HCFont.body)
                .foregroundStyle(HCColor.mistPlaceholder)
            TextField(inputPlaceholder, text: $input)
                .textFieldStyle(.plain)
                .font(HCFont.callout)
                .foregroundStyle(HCColor.mistBody)
                .focused($inputFocused)
                .disabled(!canAcceptInput)
                .onSubmit { submit() }
            Spacer()
            keyCap("↩")
                .opacity(canAcceptInput ? 1 : 0.35)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            HCRadius.shape(HCRadius.control)
                .fill(HCColor.mistDarkSurface))
        .overlay(
            HCRadius.shape(HCRadius.control)
                .stroke(inputFocused ? HCColor.cinnamonStroke : HCColor.mistDarkStroke,
                        lineWidth: inputFocused ? 1.2 : 1))
    }

    private var inputPlaceholder: String {
        switch model.codeImpactAnalysisState {
        case .completed:
            return "追加質問をここに入力して ↩ で送信"
        case .analyzing:
            return "調査中…"
        default:
            return "聞きたいこと (空のまま ↩ で直近の会話を調査)"
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
            // 初回調査。空文字と nil は消費側(requestCodeImpactAnalysis)で同じ扱いなので、
            // 空なら nil を渡してデフォルトの調査プロンプトで走らせる。
            model.requestCodeImpactAnalysis(question: trimmed.isEmpty ? nil : trimmed)
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
        case .completed(let cli):
            completedView(cli: cli)
        case .failed(let error):
            failedView(error: error)
        }
    }

    private var idlePlaceholder: some View {
        messageBlock(
            icon: "sparkle.magnifyingglass",
            title: "気配だけ残して、そっと調べます",
            detail: "上の欄に聞きたいことを打つか、空のまま ↩ で直近の会話を調査します。")
    }

    private func consentView(cli: AgentCLI) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            messageBlock(
                icon: "lock.shield",
                title: "初回のみ確認が必要です",
                detail: "文字起こしと、紐付けた資料フォルダがあればその中身を \(cli.displayName) が読み取ります。コードは変更しません。")
            Spacer(minLength: 0)
            HStack {
                Spacer()
                quietButton("閉じる") { model.dismissCodeImpactOverlay() }
                Button("同意して調べる") { model.confirmCodeImpactAnalysis(using: cli) }
                    .buttonStyle(.hcPrimary)
            }
        }
    }

    /// claude はストリーミングで部分テキストが届くため、届き始めたら中央のスピナー表示から
    /// 進捗行 + 部分テキスト表示へ切り替える。codex は partialText が常に空のままなので、
    /// 従来どおり中央スピナーのままになる。
    @ViewBuilder
    private func analyzingView(cli: AgentCLI) -> some View {
        if model.codeImpactPartialText.isEmpty {
            centeredSpinnerView(cli: cli)
        } else {
            streamingView()
        }
    }

    private func centeredSpinnerView(cli: AgentCLI) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(HCColor.cinnamon)
            Text("\(cli.displayName) が調査中")
                .font(HCFont.style(.subheadline, weight: .semibold))
                .foregroundStyle(HCColor.mistWhite)
            if let question = model.codeImpactQuestion, !question.isEmpty {
                Text("「\(question)」を調査しています")
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.mistWhiteDim)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else {
                Text("直近の文字起こしと必要なコードだけを読み取っています")
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.mistWhiteDim)
            }
            cancelButton()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// 部分テキストが届き始めてからの表示。上端に進捗行(ツール利用など) + 中止ボタン、
    /// その下に確定済みターン履歴 + 進行中のターン(質問エコー + 届いた分の Markdown)を
    /// turnsScrollView に描かせる。
    private func streamingView() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(model.codeImpactActivity ?? "調査中…")
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.mistWhiteDim)
                    .lineLimit(1)
                Spacer()
                cancelButton()
            }
            turnsScrollView(streaming: true)
        }
    }

    /// チップ型の「中止」ボタン。centeredSpinnerView(中央スピナー時)と streamingView
    /// (部分テキスト表示時)の両方で使う共通の見た目。
    private func cancelButton() -> some View {
        Button("中止") { model.cancelCodeImpactAnalysis() }
            .buttonStyle(.plain)
            .font(HCFont.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(HCColor.mistWhiteDim)
            .overlay(
                HCRadius.shape(HCRadius.chip)
                    .stroke(HCColor.mistDarkStroke, lineWidth: 1))
    }

    /// completedView と streamingView が共通で使う、ターン履歴込みのスクロール領域。
    /// `streaming: true` の場合は、確定済みターン列(すべて過去扱い)の下に、進行中の
    /// 質問と model.codeImpactPartialText を1ターンぶん追加で描く。
    /// 最後のターン以外は .opacity(0.75) + ターン間の区切り線を入れて「過去」と分かるようにする。
    /// 調査開始時(このビューが現れた直後)と新しいターン確定時(このビューが作り直された直後)の
    /// 両方で、appear のたびに最新ターンの先頭へスクロールする。
    private func turnsScrollView(streaming: Bool) -> some View {
        // 会議切替で codeImpactTurns がリセットされた分の古いパース結果を捨てる
        // (AppModel 側からキャッシュへ直接触れないため、生きている id 集合との
        // 突き合わせでここから間引く)。
        CodeImpactSectionsCache.shared.prune(keeping: Set(model.codeImpactTurns.map(\.id)))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.codeImpactTurns.enumerated()), id: \.element.id) { index, turn in
                        if index > 0 {
                            Rectangle().fill(HCColor.mistDivider).frame(height: 1)
                                .padding(.vertical, 12)
                        }
                        let isLatest = !streaming && index == model.codeImpactTurns.count - 1
                        turnView(
                            turnIndex: index, turnID: turn.id, question: turn.question,
                            result: turn.result, isLatest: isLatest)
                            .opacity(isLatest ? 1 : 0.75)
                            .id(turn.id)
                    }
                    if streaming {
                        if !model.codeImpactTurns.isEmpty {
                            Rectangle().fill(HCColor.mistDivider).frame(height: 1)
                                .padding(.vertical, 12)
                        }
                        turnView(
                            turnIndex: model.codeImpactTurns.count, turnID: nil,
                            question: model.codeImpactQuestion, result: model.codeImpactPartialText,
                            isLatest: true)
                            .id(Self.streamingTurnAnchorID)
                    }
                }
            }
            .onAppear {
                if streaming {
                    proxy.scrollTo(Self.streamingTurnAnchorID, anchor: .top)
                } else if let last = model.codeImpactTurns.last {
                    proxy.scrollTo(last.id, anchor: .top)
                }
            }
        }
    }

    /// 進行中のターン(まだ codeImpactTurns に積まれていない)を指すスクロール先の id。
    private static let streamingTurnAnchorID = "code-impact-streaming-turn"

    /// ターン 1 件分(質問行 + 結果)の共通レイアウト。turnID が非 nil の確定ターンは、
    /// CodeImpactSectionsCache 経由でパース済み sections を使い回す(結果文字列は
    /// 確定後に変わらないため)。turnID が nil の進行中ターン(ストリーミングの断片)は
    /// 毎回パースし直す。
    private func turnView(
        turnIndex: Int, turnID: UUID?, question: String?, result: String, isLatest: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(questionLabel(for: question))
                .font(HCFont.style(.subheadline, weight: .semibold))
                .foregroundStyle(HCColor.mistWhite)
                .fixedSize(horizontal: false, vertical: true)
            resultView(turnIndex: turnIndex, turnID: turnID, result: result, isLatest: isLatest)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func resultView(
        turnIndex: Int, turnID: UUID?, result: String, isLatest: Bool
    ) -> some View {
        if let turnID {
            let sections = CodeImpactSectionsCache.shared.sections(for: turnID) {
                CodeImpactResultView.parseSections(from: result)
            }
            CodeImpactResultView(sections: sections, model: model, turnIndex: turnIndex, isLatest: isLatest)
        } else {
            CodeImpactResultView(result: result, model: model, turnIndex: turnIndex, isLatest: isLatest)
        }
    }

    /// 質問なし(ダイジェスト調査)のターンには、質問文の代わりにこのラベルを出す。
    private func questionLabel(for question: String?) -> String {
        guard let question, !question.isEmpty else { return "直近の会話を調査" }
        return "Q. \(question)"
    }

    /// ステータス行の文言は、質問の有無と資料フォルダの有無で決まる:
    /// - 質問なし(ダイジェスト): 資料の有無に関わらず「直近の文字起こしを調査」
    /// - 質問あり + 資料フォルダあり: 「質問への回答」
    /// - 質問あり + 資料フォルダなし: 「文字起こしから回答」(コード・資料は見ていないと伝える)
    /// codeImpactTurns の最後が「今の結果」なので、別枠の Q エコーや result 直渡しはせず
    /// turnsScrollView(ターン履歴)だけで描く。コピーボタンとステータス行が必要な結果本文は
    /// model.codeImpactTurns.last?.result(正本)から読む。
    private func completedView(cli: AgentCLI) -> some View {
        // codeImpactQuestion ではなく表示中の最新ターンの質問を読む。追加質問が失敗した
        // 直後は codeImpactQuestion が失敗した質問のままで、表示している結果と食い違うため。
        let question = model.codeImpactTurns.last?.question
        let hasQuestion = !(question ?? "").isEmpty
        let hasReferenceFolder = model.codeImpactActiveReferenceFolder != nil
        let statusText: String
        if !hasQuestion {
            statusText = "\(cli.displayName) · 直近の文字起こしを調査"
        } else if hasReferenceFolder {
            statusText = "\(cli.displayName) · 質問への回答"
        } else {
            statusText = "\(cli.displayName) · 文字起こしから回答"
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(HCColor.cinnamon).frame(width: 6, height: 6)
                Text(statusText)
                    .font(HCFont.style(.caption1, weight: .semibold))
                    .foregroundStyle(HCColor.cinnamon)
                Spacer()
                CopyButton { model.codeImpactTurns.last?.result ?? "" }
            }
            turnsScrollView(streaming: false)
            if let turnError = model.codeImpactTurnError {
                turnErrorBanner(turnError)
            }
            // 資料フォルダ未紐付けのまま文字起こしだけで答えた回にだけ、そのまま資料と
            // 照合したい場合の導線を出す。フッターではなく結果の直下に置くのは、
            // 常時出る他の操作ヒントと違い「この回の結果だけに関わる案内」のため。
            if !hasReferenceFolder {
                Button {
                    model.linkReferenceFolderForCodeImpact()
                } label: {
                    Text("資料フォルダを紐付けると、コードや資料とも照合できます")
                        .font(HCFont.caption)
                        .foregroundStyle(HCColor.mistWhiteDim)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    /// 追加質問(または履歴がある状態からの再調査)が失敗したときのバナー。
    /// 履歴を消す全画面の failedView は履歴が無い初回失敗専用で、履歴があるときは
    /// このバナーでエラーと再試行だけを最新ターンの下に出す。
    private func turnErrorBanner(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(HCFont.style(.caption1, weight: .semibold))
                .foregroundStyle(HCColor.cinnamon)
            VStack(alignment: .leading, spacing: 2) {
                Text(turnErrorTitle)
                    .font(HCFont.style(.caption1, weight: .semibold))
                    .foregroundStyle(HCColor.mistWhite)
                    .fixedSize(horizontal: false, vertical: true)
                Text(error)
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.mistWhiteDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("再試行") { retryFailedTurn() }
                .buttonStyle(.plain)
                .font(HCFont.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(HCColor.cinnamon)
                .overlay(
                    HCRadius.shape(HCRadius.chip)
                        .stroke(HCColor.cinnamonStroke, lineWidth: 1))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            HCRadius.shape(HCRadius.control)
                .fill(HCColor.mistDarkSurface))
        .padding(.top, 8)
    }

    private var turnErrorTitle: String {
        let question = model.codeImpactQuestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !question.isEmpty else { return "調査できませんでした" }
        return "「\(question)」を調査できませんでした"
    }

    /// バナーからの再試行。失敗したのが追加質問なら follow-up(直前の結果を踏まえる)として
    /// 投げ直し、質問なしのダイジェスト再調査ならそのまま投げ直す。
    private func retryFailedTurn() {
        let question = model.codeImpactQuestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if question.isEmpty {
            model.requestCodeImpactAnalysis(question: nil)
        } else {
            model.requestFollowUpCodeImpact(question: question)
        }
    }

    private func failedView(error: String) -> some View {
        let question = model.codeImpactQuestion
        return VStack(alignment: .leading, spacing: 16) {
            messageBlock(icon: "exclamationmark.triangle", title: "調査できませんでした", detail: error)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("再試行") { model.requestCodeImpactAnalysis(question: question) }
                    .buttonStyle(.hcPrimary)
            }
        }
    }

    /// 塗り無しのプレーンなボタン。consentView の閉じるで使う。
    private func quietButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(HCColor.mistBody)
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
            keyCap("↩")
            Text("送信")
                .font(HCFont.caption)
                .foregroundStyle(HCColor.mistWhiteDim)
                .padding(.trailing, 10)
            keyCap("⌘ C")
            Text("コピー")
                .font(HCFont.caption)
                .foregroundStyle(HCColor.mistWhiteDim)
                .padding(.trailing, 10)
            keyCap("Esc")
            Text("閉じる")
                .font(HCFont.caption)
                .foregroundStyle(HCColor.mistWhiteDim)
            Spacer()
            if case .completed = model.codeImpactAnalysisState {
                Text("上の入力欄から追加質問できます")
                    .font(HCFont.caption)
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
                HCRadius.shape(HCRadius.keycap)
                    .fill(HCColor.mistKeyCap))
    }
}

/// エージェント出力を `## セクション` 見出し単位でアコーディオン表示する。
/// 要約側の SummaryParser は 4 セクション固定のスキーマ判定で流用できないため、
/// この画面専用の最小実装を持つ。
///
/// 最初の `## ` より前に本文があれば、それを見出し無しのセクションとして常時表示する。
/// 見出し付きセクションの開閉は、ビューの @State ではなく model.codeImpactSectionOverrides に
/// 持たせる。ストリーミング表示と完了表示でこのビューの実体が作り直されても
/// (ユーザーが開いた・畳んだセクションが)引き継がれるようにするため。
/// key は「ターン番号:見出しタイトル」("\(turnIndex):\(title)")にし、複数ターンをまたいで
/// 同じ見出し("根拠と補足" など)が出ても開閉状態が衝突しないようにする。
/// 未操作なら、最新ターン(isLatest)は全セクション展開、過去ターンは折りたたみを初期値にする。
///
/// タイトルが「回答」のセクションは見出し行(chevron 含む)を出さず、本文だけを常時展開で
/// 表示する。「Q. 質問文」の直下に答えがそのまま続く見た目にするための特例。
///
/// タイトルが「次の一手」のセクションも同様にアコーディオンにせず常時表示するが、こちらは
/// 「回答」と違って面を持つアクションブロックとして目立たせる(質問の目的に対して実際に
/// 確認・作業すべきことがあるときだけ AI が出力するセクションのため)。プロンプト側
/// (AgentCodeImpactAnalyzer.questionPrompt)が該当なしでは丸ごとセクションを出力しない
/// 仕様なので、このビュー側では「無ければ表示しない」を別途分岐する必要はなく、
/// sections に含まれていなければ自然に描画されない。
///
/// セクション本文は行単位で流す前にフェンスブロック(```)を切り出す。```mermaid だけ図として
/// 描画対象にし、それ以外のフェンスは言語名を捨ててコード表示にする(詳細は Segment 参照)。
private struct CodeImpactResultView: View {
    let model: AppModel
    /// このターンが codeImpactTurns の何番目か(進行中のターンは turns.count)。
    /// セクション開閉の overrides キーをターンごとに分けるために使う。
    let turnIndex: Int
    /// このターンが「今の結果」(最新ターン、または進行中のターン)か。
    /// セクションの初期展開/折りたたみの既定値を決める。
    let isLatest: Bool
    /// init 時に一度だけパースした結果。View の body は result が変わるたびに
    /// (ストリーミングの断片・完了時の確定結果それぞれで)このビュー自体が作り直されるため、
    /// computed property にして body 評価ごとに全文パースし直す必要はない。
    /// 確定ターンは呼び出し側(turnsScrollView)が CodeImpactSectionsCache 経由で
    /// パース済みの sections を渡す(下の sections: init)ため、ここでの再パースは
    /// 進行中のターン(ストリーミングの断片)だけで起きる。
    private let sections: [Section]

    init(result: String, model: AppModel, turnIndex: Int, isLatest: Bool) {
        self.model = model
        self.turnIndex = turnIndex
        self.isLatest = isLatest
        self.sections = Self.parseSections(from: result)
    }

    /// 確定ターン用: 呼び出し側で既にパース済みの sections を受け取り、再パースを省く。
    init(sections: [Section], model: AppModel, turnIndex: Int, isLatest: Bool) {
        self.model = model
        self.turnIndex = turnIndex
        self.isLatest = isLatest
        self.sections = sections
    }

    fileprivate struct Section {
        let title: String?
        let segments: [Segment]
    }

    /// セクション本文をフェンスブロック単位で切り出したもの。
    /// ```mermaid フェンスだけ特別扱いし、それ以外のフェンスは言語名を捨てて
    /// 一律コード表示にする。フェンスに挟まれていない行は従来どおり行単位で描画する。
    fileprivate enum Segment {
        case text([Substring])
        case code(String)
        case mermaid(String)
    }

    /// 行の並びをテキスト/コード/mermaid のセグメントに分割する。
    /// 閉じフェンスが無いまま入力が終わる(ストリーミング途中)場合は、開始行の言語に関わらず
    /// そこまでをコードセグメントとして扱う(mermaid として確定させない)。
    private static func segments(from lines: [Substring]) -> [Segment] {
        var result: [Segment] = []
        var textBuffer: [Substring] = []

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            result.append(.text(textBuffer))
            textBuffer = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("```") else {
                textBuffer.append(line)
                index += 1
                continue
            }
            let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
            var body: [Substring] = []
            var cursor = index + 1
            var closed = false
            while cursor < lines.count {
                if lines[cursor].hasPrefix("```") {
                    closed = true
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            flushText()
            let joined = body.joined(separator: "\n")
            if closed {
                result.append(language == "mermaid" ? .mermaid(joined) : .code(joined))
                index = cursor + 1
            } else {
                result.append(.code(joined))
                index = lines.count
            }
        }
        flushText()
        return result
    }

    fileprivate static func parseSections(from result: String) -> [Section] {
        var sections: [Section] = []
        var title: String?
        var lines: [Substring] = []
        var started = false

        func flush() {
            guard started else { return }
            sections.append(Section(title: title, segments: Self.segments(from: lines)))
        }

        for line in result.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                title = String(line.dropFirst(3))
                lines = []
                started = true
            } else {
                started = true
                lines.append(line)
            }
        }
        flush()
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                sectionView(section: section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 本文中のファイルパスをクリックで開けるようにする(下の linkedInlineMarkdown が
        // .link にセットした file:// URL だけを対象にする)。http 等が AI 出力に混ざっても
        // 会議中に勝手にブラウザを開かないよう、file URL 以外は discarded にする。
        .environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    @ViewBuilder
    private func sectionView(section: Section) -> some View {
        if let title = section.title {
            if title == AgentCodeImpactAnalyzer.answerSectionTitle {
                segmentBlock(section.segments)
            } else if title == AgentCodeImpactAnalyzer.nextStepSectionTitle {
                actionBlock(section.segments)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { toggle(title: title) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(HCFont.style(.caption1, weight: .semibold))
                                .foregroundStyle(HCColor.cinnamon)
                                .rotationEffect(.degrees(isExpanded(title: title) ? 90 : 0))
                            Text(title)
                                .font(HCFont.style(.callout, weight: .semibold))
                                .foregroundStyle(HCColor.cinnamon)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isExpanded(title: title) {
                        segmentBlock(section.segments)
                            .padding(.leading, 18)
                    }
                }
            }
        } else {
            segmentBlock(section.segments)
        }
    }

    /// このターム内で見出しタイトルを一意にする key(ターンをまたいだ同名見出しの衝突防止)。
    private func overrideKey(title: String) -> String {
        "\(turnIndex):\(title)"
    }

    /// 開閉判定。ユーザーが未操作なら、最新ターンは展開・過去ターンは折りたたみを初期値にする。
    private func isExpanded(title: String) -> Bool {
        model.codeImpactSectionOverrides[overrideKey(title: title)] ?? isLatest
    }

    private func toggle(title: String) {
        model.codeImpactSectionOverrides[overrideKey(title: title)] = !isExpanded(title: title)
    }

    /// 「次の一手」セクション専用の見た目。他のセクションの見出し行(`.padding(.top, 10)`)と
    /// 上マージンを揃えつつ、面を持つブロックとして本文を囲む。
    private func actionBlock(_ segments: [Segment]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.right")
                .font(HCFont.style(.callout, weight: .semibold))
                .foregroundStyle(HCColor.cinnamon)
            VStack(alignment: .leading, spacing: 4) {
                Text("次の一手")
                    .font(HCFont.style(.caption1, weight: .semibold))
                    .foregroundStyle(HCColor.cinnamon)
                segmentBlock(segments)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            HCRadius.shape(HCRadius.control)
                .fill(HCColor.mistDarkSurface))
        .padding(.top, 10)
    }

    @ViewBuilder
    private func segmentBlock(_ segments: [Segment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        switch segment {
        case .text(let lines):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineView(String(line))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let code):
            fenceCodeView(code)
        case .mermaid(let code):
            mermaidSegmentView(code)
        }
    }

    /// mermaid セグメントの描画。閉じフェンスが無い間はセグメント分割の時点で `.code` 扱いに
    /// なる(segments(from:) 参照)ため、ここに来るのは常に閉じフェンス済みの確定した mermaid。
    /// 描画は MermaidBlockView に委ね、そちらが描画失敗時のフォールバック
    /// (コードと同じ見た目の raw 表示)を持つ。
    @ViewBuilder
    private func mermaidSegmentView(_ code: String) -> some View {
        MermaidBlockView(code: code)
    }

    /// セクション本文 1 行分の描画。箇条書き(`- ` / `* `)は先頭に `•` を置き、
    /// 行頭の空白 2 文字ごとに 12pt のインデントを足す。`### ` は小見出し、
    /// それ以外は本文段落として折り返し表示する。
    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let leadingSpaces = raw.prefix(while: { $0 == " " }).count
        let text = raw.drop(while: { $0 == " " })
        if text.hasPrefix("- ") || text.hasPrefix("* ") {
            let bulletContent = String(text.dropFirst(2))
            if let path = Self.pathBulletComponents(
                bulletContent, referenceFolder: model.codeImpactActiveReferenceFolder)
            {
                pathBulletRow(pathToken: path.path, description: path.description, url: path.url)
                    .padding(.leading, CGFloat(leadingSpaces / 2) * 12)
            } else if let timestamp = Self.timestampBulletComponents(bulletContent) {
                timestampBulletRow(chip: timestamp.chip, rest: timestamp.rest)
                    .padding(.leading, CGFloat(leadingSpaces / 2) * 12)
            } else {
                bulletRow(body: bulletContent) { EmptyView() }
                    .padding(.leading, CGFloat(leadingSpaces / 2) * 12)
            }
        } else if text.hasPrefix("### ") {
            Text(String(text.dropFirst(4)))
                .font(HCFont.style(.caption1, weight: .semibold))
                .foregroundStyle(HCColor.mistWhite)
                .padding(.top, 4)
        } else if raw.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer().frame(height: 2)
        } else {
            Text(linkedInlineMarkdown(raw))
                .font(HCFont.body)
                .foregroundStyle(HCColor.mistBody)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 箇条書き 1 行の共通の骨組み(• + 先頭の特別要素(あれば)+ 本文)。デフォルトの
    /// 箇条書き・pathBulletRow・timestampBulletRow の 3 箇所がここを共有する。
    /// leading が無い(EmptyView)場合は、バレットの直後に本文が続く従来どおりの見た目になる。
    private func bulletRow<Leading: View>(
        body: String, @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
                .font(HCFont.body)
                .foregroundStyle(HCColor.mistPlaceholder)
            leading()
            Text(linkedInlineMarkdown(body))
                .font(HCFont.body)
                .foregroundStyle(HCColor.mistBody)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 「- 相対パス — 説明」形式の箇条書き行専用のレイアウト。パス部分をボタンにして、
    /// ホバーで指カーソルに変える(AttributedString の .link のままだと I ビームのままになるため)。
    private func pathBulletRow(pathToken: String, description: String, url: URL) -> some View {
        bulletRow(body: "— \(description)") {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(pathToken)
                    .font(HCFont.monospaced(size: 12))
                    .foregroundStyle(HCColor.cinnamon)
                    .underline()
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }

    /// 箇条書き 1 行の中身(先頭の「- 」を除いた文字列)が「相対パス — 説明」の形になっていて、
    /// かつ先頭トークン(区切りより前の全体)が資料フォルダを基準に実在解決できる場合だけ、
    /// パス部分と説明部分を分けて返す。それ以外(区切りが無い/パスが実在しない)は nil を返し、
    /// 呼び出し側は従来どおりの行全体を1本のテキストとして扱う。
    private static func pathBulletComponents(
        _ content: String, referenceFolder: String?
    ) -> (path: String, description: String, url: URL)? {
        guard let separatorRange = content.range(of: " — ") else { return nil }
        let pathToken = String(content[content.startIndex..<separatorRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !pathToken.isEmpty,
            let url = ResolvedPathCache.shared.resolvedURL(for: pathToken, referenceFolder: referenceFolder)
        else { return nil }
        let description = String(content[separatorRange.upperBound...])
        return (pathToken, description, url)
    }

    /// 箇条書き行頭のタイムスタンプ(`HH:MM` / `HH:MM:SS`、または `〜` `~` `-` で繋いだ範囲)を
    /// 検出する正規表現。`^` で行頭に固定し、末尾に空白か文字列終端が続く場合だけ
    /// マッチさせる(`12:345` のような数字列の続きを誤って時刻と見なさないため)。
    private static let timestampBulletRegex = try! NSRegularExpression(
        pattern: #"^\s*\d{1,2}:\d{2}(?::\d{2})?(\s*[〜~\-]\s*\d{1,2}:\d{2}(?::\d{2})?)?(?=\s|$)"#)

    /// 箇条書き 1 行の中身が行頭タイムスタンプで始まる場合、チップにする部分(chip)と
    /// 残りの本文(rest)に分けて返す。始まらない場合は nil(呼び出し側は従来どおりの
    /// 1本のテキストとして扱う)。
    private static func timestampBulletComponents(_ content: String) -> (chip: String, rest: String)? {
        let range = NSRange(content.startIndex..., in: content)
        guard let match = timestampBulletRegex.firstMatch(in: content, options: [], range: range),
            let matchRange = Range(match.range, in: content)
        else { return nil }
        let chip = content[matchRange].trimmingCharacters(in: .whitespaces)
        guard !chip.isEmpty else { return nil }
        let rest = String(content[matchRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (chip, rest)
    }

    /// タイムスタンプ行専用のレイアウト。時刻部分をチップとして描画し、残りは従来どおり
    /// インライン Markdown・パスのリンク化を効かせた本文として描画する。
    private func timestampBulletRow(chip: String, rest: String) -> some View {
        bulletRow(body: rest) {
            Text(chip)
                .font(HCFont.monospaced(size: 10.5))
                .foregroundStyle(HCColor.cinnamon)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    HCRadius.shape(HCRadius.chip)
                        .fill(HCColor.mistDarkSurface))
        }
    }

    /// inlineMarkdownText(SummaryView.swift 側の共通実装)に加えて、本文中の
    /// ファイルパスらしきトークンを実在確認のうえクリック可能なリンクにする。
    /// 実在しないトークンは見た目を変えない(誤リンクで存在しない場所を開いてしまうことを避けるため)。
    private func linkedInlineMarkdown(_ text: String) -> AttributedString {
        let tokens = Self.pathTokens(in: text, referenceFolder: model.codeImpactActiveReferenceFolder)
        guard !tokens.isEmpty else { return inlineMarkdownText(text) }

        var result = AttributedString()
        var cursor = text.startIndex
        for token in tokens {
            if cursor < token.range.lowerBound {
                result += inlineMarkdownText(String(text[cursor..<token.range.lowerBound]))
            }
            var linkRun = AttributedString(String(text[token.range]))
            linkRun.link = token.url
            linkRun.foregroundColor = HCColor.cinnamon
            linkRun.underlineStyle = Text.LineStyle.single
            result += linkRun
            cursor = token.range.upperBound
        }
        if cursor < text.endIndex {
            result += inlineMarkdownText(String(text[cursor...]))
        }
        return result
    }

    /// パスらしきトークン1件分(元テキスト中の範囲と、実在確認が取れた file URL)。
    private struct PathToken {
        let range: Range<String.Index>
        let url: URL
    }

    /// パスらしきトークンの候補文字だけを拾う正規表現。日本語の文中に混ざる想定のため、
    /// 許可する文字を ASCII のパス構成要素(英数字・`_@.-/`)に絞る。マッチが `/` を含まず
    /// 拡張子(`.拡張子`)でも終わらない場合は候補から外す(isPathCandidate)。
    private static let pathTokenRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9_@.\-/]+"#)
    /// トークンの末尾が「. + 英数字」で終わっているか(拡張子らしさの判定)。
    private static let extensionSuffixRegex = try! NSRegularExpression(pattern: #"\.[A-Za-z0-9]+$"#)

    private static func isPathCandidate(_ token: String) -> Bool {
        if token.contains("/") { return true }
        let range = NSRange(token.startIndex..., in: token)
        return extensionSuffixRegex.firstMatch(in: token, range: range) != nil
    }

    /// text 中からパス候補トークンを拾い、実在確認が取れたものだけを返す
    /// (実在しないものはリンク化せず、今までどおりの文字列表示にするため)。
    private static func pathTokens(in text: String, referenceFolder: String?) -> [PathToken] {
        guard !text.isEmpty else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)
        var tokens: [PathToken] = []
        pathTokenRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            let token = String(text[range])
            guard isPathCandidate(token),
                let url = ResolvedPathCache.shared.resolvedURL(for: token, referenceFolder: referenceFolder)
            else { return }
            tokens.append(PathToken(range: range, url: url))
        }
        return tokens
    }
}

/// 確定ターンのパース結果(CodeImpactResultView.Section)のキャッシュ。ストリーミング中
/// (120ms ごと)の再描画では、進行中のターン以外は結果文字列が変わらないため、
/// 過去ターンぶんの CodeImpactResultView.init → parseSections を毎回やり直す必要はない。
/// turn.id(UUID)をキーに持つだけの単純な Dictionary(要素数は高々数十件なので、
/// ResolvedPathCache のように NSCache に任せるほどの規模ではない)。
@MainActor
private final class CodeImpactSectionsCache {
    static let shared = CodeImpactSectionsCache()

    private var storage: [UUID: [CodeImpactResultView.Section]] = [:]

    /// 既にパース済みならそれを返し、無ければ parse() の結果を格納してから返す。
    func sections(
        for turnID: UUID, parse: () -> [CodeImpactResultView.Section]
    ) -> [CodeImpactResultView.Section] {
        if let cached = storage[turnID] { return cached }
        let parsed = parse()
        storage[turnID] = parsed
        return parsed
    }

    /// 会議切替で codeImpactTurns がリセットされると、古いターンの id はもう描画に
    /// 現れなくなる。AppModel 側からこのキャッシュへ直接触れないため、いま生きている
    /// ターンの id 集合と突き合わせて古いエントリを間引く形でクリアする。
    func prune(keeping liveIDs: Set<UUID>) {
        storage = storage.filter { liveIDs.contains($0.key) }
    }
}

/// 「トークン文字列(+ 資料フォルダ) → 実在する file URL」のキャッシュ。
/// 行の描画は再レンダリングのたびに走るため、同じトークンで毎回 FileManager.fileExists を
/// 呼び直さずに済ませる。結果テキストは高々数十行なので、NSCache 任せの簡素な実装でよい。
@MainActor
private final class ResolvedPathCache {
    static let shared = ResolvedPathCache()

    /// NSCache は値に nil を持てないため、「実在しない」という結果自体も
    /// このボックスに包んで持たせる(存在確認そのものを再実行しないため)。
    private final class Box {
        let url: URL?
        init(url: URL?) { self.url = url }
    }

    private let cache = NSCache<NSString, Box>()

    func resolvedURL(for token: String, referenceFolder: String?) -> URL? {
        let key = "\(referenceFolder ?? "")\u{0}\(token)" as NSString
        if let box = cache.object(forKey: key) {
            return box.url
        }
        let url = Self.resolve(token: token, referenceFolder: referenceFolder)
        cache.setObject(Box(url: url), forKey: key)
        return url
    }

    /// 絶対パスはそのまま、相対パスは referenceFolder を基準に解決する。末尾の「/」は
    /// (「Sources/HearCatApp/*」や「Sources/HearCatApp/…」のようなグロブの手前までを
    /// 正規表現が拾った結果として付くことがあるため)取り除いてから存在確認する。
    private static func resolve(token: String, referenceFolder: String?) -> URL? {
        var path = token
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return nil }
        let fileManager = FileManager.default
        guard let referenceFolder else { return nil }
        if path.hasPrefix("/") {
            // 文字起こし(外部音声由来)が混ざった出力を扱うため、資料フォルダの外を指す
            // 絶対パスはリンク化しない。フォルダ外のファイルを開かせる導線を作らないこと
            // を、開く便利さより優先する。
            guard path == referenceFolder || path.hasPrefix(referenceFolder + "/") else { return nil }
            return fileManager.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let resolved = (referenceFolder as NSString).appendingPathComponent(path)
        return fileManager.fileExists(atPath: resolved) ? URL(fileURLWithPath: resolved) : nil
    }
}

/// フェンスをそのまま表示するときの共通の見た目。コードセグメントと、mermaid の
/// 描画失敗時のフォールバック(MermaidBlockView)の両方から使う。フェンス記号(```)自体は
/// 呼び出し側で既に取り除かれているので、ここでは中身だけを描画する。
private func fenceCodeView(_ code: String) -> some View {
    Text(code)
        .font(HCFont.monospaced(size: 11))
        .foregroundStyle(HCColor.mistBody)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            HCRadius.shape(HCRadius.control)
                .fill(HCColor.mistDarkSurface))
}

/// mermaid セグメント 1 つ分の描画。MermaidDiagramView(WKWebView)に描画を任せ、
/// 構文エラー等で失敗したら fenceCodeView と同じ見た目の raw コード表示に落とす。
/// 高さは初期値のまま描画開始し、`document.body.scrollHeight` が届き次第ぴったりに合わせる。
private struct MermaidBlockView: View {
    let code: String
    @State private var height: CGFloat = 160
    @State private var failed = false

    var body: some View {
        if failed {
            fenceCodeView(code)
        } else {
            MermaidDiagramView(code: code, height: $height, failed: $failed)
                .frame(height: height)
        }
    }
}
