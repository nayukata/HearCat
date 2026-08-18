import AppKit
import HearCatKit
import SwiftUI
import os

/// 「クリックしても反応しない」報告の切り分け用。セクション開閉など、パネル内の
/// クリックが実際に届いているかをログで確定させるためだけに使う。
private let codeImpactOverlayLogger = Logger(
    subsystem: SessionStore.bundleIdentifier, category: "code-impact-overlay")

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
            size: NSSize(width: 600, height: 720),
            title: "会話について質問",
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
            panel.makeKey()
            return
        }
        let target = panel.frame.origin
        restingOrigin = target
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - Self.entryOffsetY))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // orderFrontRegardless は前面に出すだけでキーウィンドウにしない。開いた瞬間から
        // 入力欄に打てるよう明示的にキーにする(.nonactivatingPanel なので、キーにしても
        // 会議アプリからアプリごとフォーカスを奪うことはない)。
        panel.makeKey()
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
        guard let visibleFrame = NSScreen.hcScreenWithMouse?.visibleFrame else { return false }
        return visibleFrame.intersects(panel.frame)
    }

    /// このパネルはユーザーがホットキーで自分から呼ぶため、マウスのある画面に出す
    /// (呼んだ瞬間の注意はカーソルの近くにある)。
    private func positionNearTopRight() {
        guard let screen = NSScreen.hcScreenWithMouse else { return }
        panel.setFrameOrigin(
            FloatingPanel.topRightOrigin(of: panel, in: screen, margin: 24))
    }
}

/// パネル本体のビュー。チャット風の 3 段構成(ヘッダー / 結果(ターン履歴) / 入力欄+キーヒント)。
/// 入力欄を最下部に置くことで、送信操作と会話の続きが同じ位置関係(下に打つ→下に積まれる)
/// になるようにしている。キーヒント行(↩ 送信 / Esc 閉じる)は独立した段にせず入力欄と同じ段に
/// 収め、間隔を詰めて「入力欄の説明」に見えるようにしている(keyHintRow 参照)。
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
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Rectangle().fill(HCColor.divider).frame(height: 1)
            // 左右の余白は content 側に一括で付けない。turnsScrollView(ScrollView)を
            // 通る内容はスクロールバーがパネルの右端に付くよう ScrollView 自体を幅いっぱいに
            // 広げ、余白は内側の LazyVStack に持たせる。ScrollView を通らない状態ビュー
            // (idle / requiresConsent / failed)と turnsScrollView 内の資料フォルダ導線は、
            // ここで外した分をそれぞれの側で付け直している(macOS の慣習でスクロールバーは
            // ウィンドウ端に付き、余白はスクロール内容側に持たせるのが正しいため)。
            content
                .padding(.top, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(HCColor.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                inputField
                keyHintRow
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 460, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HCColor.panel)
        .overlay(
            HCRadius.shape(HCRadius.panel)
                .stroke(HCColor.strokeLine, lineWidth: 1))
        .clipShape(HCRadius.shape(HCRadius.panel))
        .onExitCommand { model.dismissCodeImpactOverlay() }
        .onAppear { inputFocused = true }
    }

    // MARK: - ヘッダー

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(HCColor.surface)
                    .frame(width: 18, height: 18)
                Circle()
                    .stroke(HCColor.accentStroke, lineWidth: 1)
                    .frame(width: 18, height: 18)
                Text("?")
                    .font(HCFont.style(.caption1, weight: .semibold))
                    .foregroundStyle(HCColor.accentText)
            }
            HStack(spacing: 6) {
                Text("会話について質問")
                    .font(HCFont.style(.subheadline, weight: .semibold))
                    .foregroundStyle(HCColor.textPrimary)
                // 過去セッションが対象のときだけ名前を添える。ライブとの取り違えを防ぐため。
                if let targetName = model.codeImpactTargetSessionName {
                    Text("· \(targetName)")
                        .font(HCFont.style(.caption1, weight: .semibold))
                        .foregroundStyle(HCColor.accentText)
                        .lineLimit(1)
                }
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
            .pointingHandOnHover()
            .help("閉じる (Esc)")
        }
    }

    // MARK: - 入力欄

    private var inputField: some View {
        HStack(spacing: 10) {
            Text("›")
                .font(HCFont.body)
                .foregroundStyle(HCColor.placeholderText)
            // SwiftUI の TextField(axis: .vertical) + onKeyPress(.return) で組んだ初版は、
            // 日本語 IME の変換中に Return を押すと変換確定より先に onKeyPress が発火し、
            // 入力欄が空扱いのまま送信されてしまう実害があった。onKeyPress に「変換中かどうか」
            // (marked text の有無)を判定する API が無く、SwiftUI 側では原理的に直せないため、
            // NSTextView ベースの MultilineInputField に置き換えている(詳細はその定義を参照)。
            MultilineInputField(
                text: $input, placeholder: inputPlaceholder, isEnabled: canAcceptInput,
                isFocused: $inputFocused, onSubmit: submit
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(canAcceptInput ? 1 : 0.35)
            Spacer()
            keyCap("↩")
                .opacity(canAcceptInput ? 1 : 0.35)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            HCRadius.shape(HCRadius.control)
                .fill(HCColor.surface))
        .overlay(
            HCRadius.shape(HCRadius.control)
                .stroke(inputFocused ? HCColor.accentStroke : HCColor.strokeLine,
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
        // 入力欄が空でも、選択肢(ChoicesView)を選択済みならその回答を送る。ChoicesView 側の
        // 「送信」ボタンと同じ送信先(requestFollowUpCodeImpact)を経由するため、二重送信は
        // 向こうと同じく .completed ガードで防がれる。この分岐は元の switch より前に置き、
        // 選択が無い(pending が nil)場合は switch 側の従来どおりの分岐に委ねる。
        if case .completed = model.codeImpactAnalysisState, trimmed.isEmpty,
            let pending = model.codeImpactPendingChoiceAnswer
        {
            model.requestFollowUpCodeImpact(question: pending)
            return
        }
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
        case .analyzing(let cli), .completed(let cli):
            // analyzing と completed を1つのケースにまとめ、同じ turnsScrollView(cli:)を
            // 呼ぶ。以前は state ごとに turnsScrollView(streaming:) / completedView を
            // 別々の switch ケースとして呼び分けていたが、ViewBuilder の switch は case が
            // 切り替わるたびに配下のビュー階層を作り直す(= ScrollView も含めて作り直され、
            // スクロール位置を失う)ため、ストリーミング完了の瞬間に表示が最新ターンの
            // 先頭へ飛び、選択肢が画面外に隠れる不具合があった。1 ケースにまとめることで
            // ScrollView 自身の識別が analyzing ⇄ completed の遷移をまたいで保たれ、
            // 位置が飛ばなくなる。streaming かどうか・資料フォルダ導線を出すかは
            // turnsScrollView 内部の値レベルの分岐に落とす。
            turnsScrollView(cli: cli)
        case .failed(let error):
            failedView(error: error)
        }
    }

    // idlePlaceholder / consentView / failedView は turnsScrollView(ScrollView)を通らないため、
    // content から外した左右余白(24pt)をここで付け直す。

    private var idlePlaceholder: some View {
        messageBlock(
            icon: "sparkle.magnifyingglass",
            title: "会話の内容について AI に質問できます",
            detail: "下の欄に聞きたいことを打つか、空のまま ↩ で直近の会話を調査します。")
            .padding(.horizontal, 24)
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
        .padding(.horizontal, 24)
    }

    /// 進行中ターンの本文位置に出す進捗行(3 点ドットのアニメーション + 状況テキスト + 中止ボタン)。
    /// claude・codex とも同じ partialText を経由してストリーミングで本文が届くため、
    /// 届くまでの間はこの行が本文の代わりになり、届き始めてからはこの行を残したまま
    /// 下に本文を続ける(turnView 参照)。codex は claude の文字単位のデルタと違い、
    /// codex CLI 自体は 1 メッセージをまとめて返すが、AgentCodexImpactStream 内の
    /// TypewriterEmitter がそれを一定のペースに分け直して partialText へ流し込むため、
    /// 見た目の届き方(少しずつ本文が伸びていく感じ)は claude と揃っている。
    /// model.codeImpactActivity(ツール利用の進捗、例「Read: AppModel.swift」「実行: ...」)が
    /// 届いている間はドットの右に小さく添える。届いていない間はドットだけを出す(固定文言は出さない)。
    private func progressRow(thinking: Bool) -> some View {
        // 行頭は質問バブルの内側パディング(12)と同じだけ下げる。ドットが左端に
        // 張り付くと吹き出しや本文の字面と揃わず浮いて見えるため。
        HStack(spacing: 8) {
            if thinking {
                ThinkingDots()
            }
            if let activity = model.codeImpactActivity {
                Text(activity)
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.textDim)
                    .lineLimit(1)
            }
            Spacer()
            cancelButton()
        }
        .padding(.leading, 12)
    }

    /// 「キャンセル」ボタン。progressRow(調査中の進捗行)から使う共通の見た目。
    /// 枠を持たないプレーンテキストの控えめな見た目にする(進捗行の主役は左のドットと
    /// 状況テキストで、これはあくまで補助操作のため)。押せることはホバーの指カーソル
    /// (pointingHandOnHover)で伝える。
    private func cancelButton() -> some View {
        Button("キャンセル") { model.cancelCodeImpactAnalysis() }
            .buttonStyle(.plain)
            .font(HCFont.caption)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .foregroundStyle(HCColor.textDim)
            .pointingHandOnHover()
    }

    /// analyzing(進行中)と completed(完了)が共通で使う、ターン履歴込みのスクロール領域。
    /// content 領域の全体がこのビューになる(以前は completed 側だけ資料フォルダ導線を
    /// 足す completedView を別に挟んでいたが、下記のとおり 1 つのビューに統合した)。
    /// state が .analyzing の間は、確定済みターン列(すべて過去扱い)の下に、進行中の質問と
    /// model.codeImpactPartialText を1ターンぶん追加で描く(turnView がその中に進捗行を
    /// 差し込む)。cli はステータス行の表示名に使う。
    /// 最後のターン以外は .opacity(0.75) + ターン間の区切り線を入れて「過去」と分かるようにする。
    ///
    /// このビューは content の switch 側で `.analyzing(let cli), .completed(let cli):` と
    /// 1 ケースにまとめて呼ばれる(content 参照)。analyzing ⇄ completed の遷移では
    /// ScrollView 自身が作り直されない(同じ switch ケースのため SwiftUI が同一の
    /// ビュー階層とみなす)ので、ストリーミング完了の瞬間にスクロール位置が飛ばない。
    /// streaming かどうか・資料フォルダ導線を出すかは、ここで model.codeImpactAnalysisState を
    /// 読み直して値レベルで分岐する。
    private func turnsScrollView(cli: AgentCLI) -> some View {
        // 会議切替で codeImpactTurns がリセットされた分の古いパース結果を捨てる
        // (AppModel 側からキャッシュへ直接触れないため、生きている id 集合との
        // 突き合わせでここから間引く)。
        CodeImpactSectionsCache.shared.prune(keeping: Set(model.codeImpactTurns.map(\.id)))

        let streaming: Bool = {
            if case .analyzing = model.codeImpactAnalysisState { return true }
            return false
        }()
        // 資料フォルダ未紐付けのまま文字起こしだけで答えた回にだけ、そのまま資料と照合
        // したい場合の導線を出す。completed(結果が出揃った状態)のときだけで、
        // analyzing 中や資料フォルダ紐付け済みでは出さない。
        let showReferenceFolderLink: Bool = {
            guard case .completed = model.codeImpactAnalysisState else { return false }
            return model.codeImpactActiveReferenceFolder == nil
        }()

        return VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    // 左右の余白はここ(スクロール内容側)に持たせる。ScrollView 自体は
                    // パネル幅いっぱいに広げ、スクロールバーがパネルの右端に付くようにする。
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.codeImpactTurns.enumerated()), id: \.element.id) { index, turn in
                            if index > 0 {
                                Rectangle().fill(HCColor.divider).frame(height: 1)
                                    .padding(.vertical, 12)
                            }
                            let isLatest = !streaming && index == model.codeImpactTurns.count - 1
                            // 過去ターンの表示は、現在選択中のエンジンではなく、そのターンを
                            // 実際に処理したエンジン(turn.cli)に従う
                            // (エンジン切り替え後に過去回答の表示が変わってしまわないように)。
                            turnView(
                                turnIndex: index, turnID: turn.id, question: turn.question,
                                result: turn.result, isLatest: isLatest, cli: turn.cli)
                                .opacity(isLatest ? 1 : 0.75)
                                .id(turn.id)
                        }
                        if streaming {
                            if !model.codeImpactTurns.isEmpty {
                                Rectangle().fill(HCColor.divider).frame(height: 1)
                                    .padding(.vertical, 12)
                            }
                            turnView(
                                turnIndex: model.codeImpactTurns.count, turnID: nil,
                                question: model.codeImpactQuestion, result: model.codeImpactPartialText,
                                isLatest: true, cli: cli)
                                .id(Self.streamingTurnAnchorID)
                        }
                        // 進行中のターンが失敗したとき、失敗した質問のバブルとエラーを
                        // 会話の続きとして描く(失敗のたびに履歴ごと全画面表示へ
                        // 切り替わらないように。履歴が無い初回失敗だけ failedView が出る)。
                        if let turnError = model.codeImpactTurnError {
                            if !model.codeImpactTurns.isEmpty {
                                Rectangle().fill(HCColor.divider).frame(height: 1)
                                    .padding(.vertical, 12)
                            }
                            questionBubble(for: model.codeImpactQuestion)
                            turnErrorRow(turnError)
                        }
                        // 新しい質問の送信直後に下端へ寄せるための着地点(高さ 1 の透明ビュー)。
                        // ストリーミング中の追従自体は defaultScrollAnchor(.bottom) が担う。
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 24)
                }
                // 下端張り付きは OS 標準の機構に任せる: 下端にいる間は内容が伸びても
                // 自動で追従し、ユーザーが上へスクロールしたら追従せず、下端へ戻すと再開する。
                // 初期位置も下端(チャット標準)になる。自前のフラグ + scrollTo の追従機構は
                // 「本文が伸びた瞬間を操作と誤認して追従が切れる」等の競合を 2 度直しても
                // 塞ぎきれなかったため撤去した。
                .defaultScrollAnchor(.bottom)
                // ウィンドウのリサイズで表示領域の高さが変わると、一瞬「下端ではない」
                // 状態になって defaultScrollAnchor(.bottom) の張り付きが外れる。
                // ストリーミング中に限り、リサイズを検知したら下端へ張り付け直す
                // (常時監視の自前追従を復活させるわけではなく、リサイズ時の再ピンだけ)。
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.containerSize.height
                } action: { oldHeight, newHeight in
                    guard streaming, oldHeight != newHeight else { return }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: streaming) { _, isStreaming in
                    if isStreaming {
                        // 新しい質問が始まった瞬間(completed/idle 等 → analyzing)は、直前の
                        // スクロール位置に関わらず下端へ戻す(送信した自分の質問と直後の
                        // 進捗行がすぐ見えるように。チャットで送信すると最新へスクロール
                        // する挙動と同じ)。1 回きりだと遅延リストの推定で下端に届かず、
                        // defaultScrollAnchor(.bottom) の張り付きが再係合しないことがある
                        // (リサイズ後の送信で実害)ため、こちらも数回寄せて収束させる。
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        Task {
                            for delay in [150, 300] {
                                try? await Task.sleep(for: .milliseconds(delay))
                                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                            }
                        }
                    } else {
                        // 完了の瞬間はスピナー→選択肢 UI の置き換えと資料フォルダ導線の
                        // 出現(スクロール領域が縮む)でレイアウトが組み直り、下端からズレて
                        // 送信ボタンが欠けたり位置が戻って見えたりする。確定を待ちながら
                        // 数回下端へ寄せ、最終結果とアクションを必ず見せる。
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        Task {
                            for delay in [150, 300] {
                                try? await Task.sleep(for: .milliseconds(delay))
                                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            if showReferenceFolderLink {
                // turnsScrollView(ScrollView)は既に内側の LazyVStack で左右余白を持つため、
                // ここで VStack 全体に付けると二重になる。この行だけ個別に付け直す。
                // 行内では trailing(右下寄せ)にする。直前のターン履歴が左寄せの本文なので、
                // この導線を右へ寄せて「本文の続きではない、別枠の案内」だと分かるようにする。
                HStack {
                    Spacer()
                    Button {
                        model.linkReferenceFolderForCodeImpact()
                    } label: {
                        Text("資料フォルダを紐付けると、コードや資料とも照合できます")
                            .font(HCFont.caption)
                            .foregroundStyle(HCColor.accentText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
                .padding(.top, 2)
                .padding(.horizontal, 24)
            }
        }
    }

    /// ストリーミングの部分テキストを、書きかけの最終行の閉じていない Markdown 記号
    /// (「**」「`」)だけ仮で閉じて返す。閉じが届く前から太字などの装飾が効いた状態で
    /// 文字単位に流れる(生の記号がほぼ見えない)。行確定まで描画を待つ方式は、行単位で
    /// 塊ごと現れてストリーミングがカクつくため不採用にした。
    /// 最終行が ``` フェンスの開始行の場合は segments(from:) 側が未完フェンスとして
    /// 扱う(choices は場所取りスピナー)ため、ここでは触らない。
    private static func optimisticStreamingText(_ partial: String) -> String {
        let tailStart = partial.lastIndex(of: "\n").map { partial.index(after: $0) }
            ?? partial.startIndex
        let tail = partial[tailStart...]
        guard !tail.isEmpty, !tail.hasPrefix("```") else { return partial }
        var completed = partial
        if (tail.components(separatedBy: "**").count - 1) % 2 == 1 {
            completed += "**"
        }
        if tail.filter({ $0 == "`" }).count % 2 == 1 {
            completed += "`"
        }
        return completed
    }

    /// 進行中のターン(まだ codeImpactTurns に積まれていない)を指すスクロール先の id。
    private static let streamingTurnAnchorID = "code-impact-streaming-turn"
    /// ストリーミング追従の着地点(LazyVStack 末尾の透明アンカー)を指す id。
    private static let bottomAnchorID = "code-impact-bottom-anchor"
    /// この距離(pt)以内なら「下端にいる」とみなし、自動追従を続ける/再開する。

    /// ターン 1 件分の共通レイアウト。質問バブルの下に、確定ターンならステータス行 +
    /// コピーボタン + 結果本文を、進行中ターン(turnID が nil)なら進捗行 +
    /// (届いていれば)結果本文を続ける。turnID が非 nil の確定ターンは、
    /// CodeImpactSectionsCache 経由でパース済み sections を使い回す(結果文字列は
    /// 確定後に変わらないため)。turnID が nil の進行中ターン(ストリーミングの断片)は
    /// 毎回パースし直す。
    private func turnView(
        turnIndex: Int, turnID: UUID?, question: String?, result: String, isLatest: Bool,
        cli: AgentCLI
    ) -> some View {
        // spacing はステータス行 ⇄ 本文の間にも効くため、8 では本文がステータス行に
        // 張り付いて見える。ブロックの切れ目をブロック内の行間より広く取るため 12 にする。
        VStack(alignment: .leading, spacing: 12) {
            questionBubble(for: question)
            if let turnID {
                statusBadgeRow(cli: cli, hasQuestion: !(question ?? "").isEmpty, result: result)
                resultView(turnIndex: turnIndex, turnID: turnID, result: result, isLatest: isLatest)
                    .textSelection(.enabled)
            } else {
                // 進行中ターン: バッジ・コピーは出さない。本文は文字単位で流しつつ、
                // 書きかけの最終行だけ閉じていない Markdown 記号を仮で閉じて描く
                // (optimisticStreamingText)。部分テキストが空の間はドットの進捗行が
                // 本文の代わりになり、届き始めたらドットは消す(もう「考え中」ではないため)。
                progressRow(thinking: result.isEmpty)
                if !result.isEmpty {
                    resultView(
                        turnIndex: turnIndex, turnID: nil,
                        result: Self.optimisticStreamingText(result), isLatest: isLatest)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// ```choices(AI 側からの選択肢確認)を操作できるかの判定。確定ターン(turnID != nil)・
    /// 最新ターン・調査が完了済みの三拍子が揃ったときだけ true。過去ターンや調査中のターンは
    /// 選ばせても送信先が定まらない(調査中の追加送信は 2 重リクエストになる)ため false。
    private func isChoicesInteractive(turnID: UUID?, isLatest: Bool) -> Bool {
        guard case .completed = model.codeImpactAnalysisState else { return false }
        return turnID != nil && isLatest
    }

    @ViewBuilder
    private func resultView(
        turnIndex: Int, turnID: UUID?, result: String, isLatest: Bool
    ) -> some View {
        let isInteractive = isChoicesInteractive(turnID: turnID, isLatest: isLatest)
        if let turnID {
            let parsed = CodeImpactSectionsCache.shared.parsed(for: turnID) {
                // ```decision-history フェンスの抽出は parseSections より前に行う。フェンスを
                // 取り除いた本文だけを渡すことで、フェンスの生 JSON が通常のセクション本文に
                // 紛れ込まないようにする(choices は逆にセクション解析後に抜き出しているが、
                // decision-history はプロンプト側で単独フェンス・単一箇所出力を約束しているため
                // 前処理のほうが単純で、かつ HearCatKit 側でテストできる)。
                let extraction = DecisionHistoryFence.extractFirst(from: result)
                return CodeImpactSectionsCache.Parsed(
                    sections: CodeImpactResultView.parseSections(from: extraction.body),
                    decisionHistoryPrompt: extraction.prompt)
            }
            CodeImpactResultView(
                sections: parsed.sections, decisionHistoryPrompt: parsed.decisionHistoryPrompt,
                model: model, turnIndex: turnIndex, isInteractive: isInteractive)
        } else {
            CodeImpactResultView(
                result: result, model: model, turnIndex: turnIndex,
                isInteractive: isInteractive)
        }
    }

    /// 質問行をバブルにして描画する。バブルの見た目自体がユーザー発話であることを示すため、
    /// 旧来の「Q. 」プレフィックスは付けない。質問なし(ダイジェスト調査)のターンには、
    /// 質問文の代わりにこのラベルをそのままバブル内へ出す。
    /// チャットの慣習どおりバブルは右寄せにする(回答本文・ステータス行は turnView 側の
    /// VStack(alignment: .leading) のまま左寄せ)。実体は QuestionBubbleRow(下記)に持たせる。
    private func questionBubble(for question: String?) -> some View {
        let text = (question?.isEmpty == false) ? question! : "直近の会話を調査"
        return QuestionBubbleRow(text: text)
    }

    /// 確定ターンの結果本文の直上に出す情報行(AI 種別・回答種別 + コピーボタン)。
    /// 文言は、質問の有無と資料フォルダの有無で決まる:
    /// - 質問なし(ダイジェスト): 資料の有無に関わらず「直近の文字起こしを調査」
    /// - 質問あり + 資料フォルダあり: 「質問への回答」
    /// - 質問あり + 資料フォルダなし: 「文字起こしから回答」(コード・資料は見ていないと伝える)
    /// 情報表示であって押せる要素ではないため、色はニュートラル(textDim)にする。
    /// 過去ターンにも同じ構成を出し(情報粒度を揃える)、コピーボタンも各ターンの result を渡す。
    private func statusBadgeRow(
        cli: AgentCLI, hasQuestion: Bool, result: String
    ) -> some View {
        let hasReferenceFolder = model.codeImpactActiveReferenceFolder != nil
        let statusText: String
        if !hasQuestion {
            statusText = "\(cli.displayName) · 直近の文字起こしを調査"
        } else if hasReferenceFolder {
            statusText = "\(cli.displayName) · 質問への回答"
        } else {
            statusText = "\(cli.displayName) · 文字起こしから回答"
        }
        return HStack(spacing: 8) {
            Circle().fill(HCColor.textDim).frame(width: 6, height: 6)
            Text(statusText)
                .font(HCFont.style(.caption1, weight: .semibold))
                .foregroundStyle(HCColor.textDim)
            Spacer()
            CopyButton { result }
        }
    }

    /// 進行中のターンが失敗したときに、会話の流れの中(失敗した質問バブルの直下)へ出す
    /// エラー行。履歴ごと消える全画面の failedView は履歴が無い初回失敗専用で、
    /// 履歴があるときはこの行でエラーと再試行だけを示す。
    private func turnErrorRow(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(HCFont.style(.caption1, weight: .semibold))
                .foregroundStyle(HCColor.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("調査できませんでした")
                    .font(HCFont.style(.caption1, weight: .semibold))
                    .foregroundStyle(HCColor.textPrimary)
                Text(error)
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("再試行") { retryFailedTurn() }
                .buttonStyle(.plain)
                .font(HCFont.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(HCColor.accentText)
                .overlay(
                    HCRadius.shape(HCRadius.chip)
                        .stroke(HCColor.accentStroke, lineWidth: 1))
                .pointingHandOnHover()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            HCRadius.shape(HCRadius.control)
                .fill(HCColor.surface))
        .padding(.top, 8)
    }

    /// 会話内エラーからの再試行。失敗したのが追加質問なら follow-up(直前の結果を踏まえる)
    /// として投げ直し、質問なしのダイジェスト再調査ならそのまま投げ直す。
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
        .padding(.horizontal, 24)
    }

    /// 塗り無しのプレーンなボタン。consentView の閉じるで使う。
    private func quietButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(HCColor.textBody)
    }

    private func messageBlock(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(HCFont.title3)
                .foregroundStyle(HCColor.accentText)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(HCFont.style(.subheadline, weight: .semibold))
                    .foregroundStyle(HCColor.textPrimary)
                Text(detail)
                    .font(HCFont.callout)
                    .foregroundStyle(HCColor.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - キーヒント(入力欄の直下、入力欄と同じ段)

    /// macOS のダイアログ作法(キャンセル系を左、主アクションを右端)に合わせ、
    /// 「Esc 閉じる」を先に、主アクションの「↩ 送信」を最後に置く。
    /// 右端には現在のエンジン・モデルを常時表示する(以前は回答ごとに statusBadgeRow で
    /// 出していたが、「毎回表示されるのは邪魔」「質問前にどの AI で答えるか分からない」
    /// という指摘で、送信前から見えるこの行へ集約した)。
    private var keyHintRow: some View {
        HStack(spacing: 6) {
            keyCap("Esc")
            Text("閉じる")
                .font(HCFont.caption)
                .foregroundStyle(HCColor.textDim)
                .padding(.trailing, 10)
            keyCap("↩")
            Text("送信")
                .font(HCFont.caption)
                .foregroundStyle(HCColor.textDim)
            Spacer(minLength: 10)
            Text(currentEngineLabel)
                .font(HCFont.caption)
                .foregroundStyle(HCColor.accentText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// 「エンジン名 (モデル名)」の形式(エンジン名と半角括弧の間に半角スペース 1 つ)。
    /// モデル名は、ストリーミングで実際に届いた値(codeImpactStreamedModel)を優先し、
    /// 届く前(まだ質問していない・応答の先頭が届く前)は設定値にフォールバックする。
    /// どちらも無ければエンジン名だけを出す。
    private var currentEngineLabel: String {
        let cli = model.selectedCodeImpactAgent
        guard
            let modelName = model.codeImpactStreamedModel ?? model.settings.codeImpactAgentModel(for: cli),
            !modelName.isEmpty
        else {
            return cli.displayName
        }
        return "\(cli.displayName) (\(modelName))"
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(HCFont.monospaced(size: 11))
            .foregroundStyle(HCColor.keyText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                HCRadius.shape(HCRadius.keycap)
                    .fill(HCColor.keyCap))
    }
}

/// inputField(質問入力欄)の実体。NSTextView をラップした薄い NSViewRepresentable。
///
/// なぜ SwiftUI 標準の TextField ではなく NSTextView なのか: TextField(axis: .vertical) +
/// onKeyPress(.return) で組んだ初版は、日本語 IME の変換中に Return を押すと変換確定より
/// 先に onKeyPress が発火し、入力欄が空扱いのまま送信されてしまう実害があった。SwiftUI の
/// onKeyPress には「marked text(変換中の未確定文字列)があるか」を判定する API が無く、
/// SwiftUI 側では原理的に直せない。一方 NSTextView は、変換中の Return を IME 自身が
/// 変換確定に使ってしまうため、そもそも NSTextViewDelegate.doCommandBy: まで届かない
/// (doCommandBy 側で追加の判定が要らない理由もこれ)。この性質を使うために NSTextView
/// ベースへ置き換えている。
///
/// 高さは 1〜4 行ぶんに収まるよう sizeThatFits(_:nsView:context:) で都度計算し、
/// それを超える入力は NSScrollView(スクロールバー非表示)が内部でスクロールを引き受ける。
/// プレースホルダは NSTextField(labelWithString:) を NSTextView の下に敷き、
/// NSTextView 側を drawsBackground = false にすることで、本文が空の間だけ透けて見える
/// (本文の描画順が上のため、クリックは常に NSTextView が受けてフォーカスに入れる)。
private struct MultilineInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    /// 呼び出し側の @FocusState の投影値をそのまま受け取り、Coordinator が双方向に同期する
    /// (パネル表示時の自動フォーカス、パネル側 makeKey との連携、枠色の切り替えは
    /// この inputFocused を見ている既存コードのままで機能し続ける)。
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    /// 1〜4 行ぶんの高さの目安。sizeThatFits で使う。
    private static let maxVisibleLines = 4

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        let textView = coordinator.textView
        textView.delegate = coordinator
        textView.isRichText = false
        textView.isFieldEditor = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.font = HCFont.nsFont(forTextStyle: .callout)
        textView.textColor = NSColor(HCColor.textBody)
        textView.insertionPointColor = NSColor(HCColor.textBody)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let placeholderLabel = coordinator.placeholderLabel
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = NSColor(HCColor.placeholderText)
        placeholderLabel.maximumNumberOfLines = 1
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        // z順: プレースホルダを先に(下に)、NSScrollView を後に(上に)追加する。
        // NSScrollView を drawsBackground = false にしていても、クリックは常にこの
        // 最前面のビューが受けるため、プレースホルダが見えている間もクリックで
        // 迷わず NSTextView にフォーカスできる。
        let container = NSView()
        container.addSubview(placeholderLabel)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: container.topAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        let textView = context.coordinator.textView
        // text バインディングと textView.string が既に一致している時は書き戻さない。
        // 無条件に代入すると IME 変換中の marked text を巻き戻してしまう恐れがあるため
        // (textDidChange 経由で text 側は既に textView.string と同じ値になっているはずで、
        // ここに来るのは主に外部要因(送信後の input = "" クリア等)で text が変わった時)。
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled

        context.coordinator.placeholderLabel.stringValue = placeholder
        context.coordinator.placeholderLabel.isHidden = !textView.string.isEmpty

        if isFocused.wrappedValue, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let textView = context.coordinator.textView
        guard let textContainer = textView.textContainer, let layoutManager = textView.layoutManager
        else { return nil }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? HCFont.nsFont(forTextStyle: .callout))
        let minHeight = lineHeight
        let maxHeight = lineHeight * CGFloat(Self.maxVisibleLines)
        let height = min(max(usedHeight, minHeight), maxHeight)
        return CGSize(width: width, height: height.rounded(.up))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineInputField
        let textView = NSTextView()
        let placeholderLabel = NSTextField(labelWithString: "")

        init(parent: MultilineInputField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            parent.text = textView.string
            updatePlaceholderVisibility()
        }

        /// 変換中(未確定)の文字は「文書の変更」ではないため textDidChange が発火しない。
        /// 変換中でも発火する選択位置の変更でプレースホルダを更新し、未確定文字の上に
        /// プレースホルダが重なって見えるデグレを防ぐ。
        func textViewDidChangeSelection(_ notification: Notification) {
            updatePlaceholderVisibility()
        }

        /// プレースホルダは「確定文字も未確定(変換中)文字も無い」時だけ見せる。
        func updatePlaceholderVisibility() {
            placeholderLabel.isHidden = !textView.string.isEmpty || textView.hasMarkedText()
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused.wrappedValue { parent.isFocused.wrappedValue = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused.wrappedValue { parent.isFocused.wrappedValue = false }
        }

        /// Return と Esc をここで横取りする。Cmd+A/C/V/X/Z 等の標準編集操作は
        /// ここで扱っていないセレクタなので NSTextView の既定実装にそのまま渡る。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // 修飾なし Return と Shift+Return は、どちらも insertNewline: として届く
                // (AppKit の標準キーバインドでは Shift は別セレクタに割り当たっていない)。
                // ここで NSApp.currentEvent の修飾キーを見て初めて区別できる。
                //
                // 日本語 IME の変換中に押した Return は、確定操作として IME 自身が
                // 消費するため、そもそもこのメソッドまで届かない。したがって
                // 「変換中かどうか」を追加で判定する必要が無い(このクラスへ
                // 置き換えた理由そのもの。上の MultilineInputField のコメント参照)。
                let hasShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if hasShift {
                    // 既定動作(カーソル位置への改行挿入)に委ねる。Option+Return は
                    // 別セレクタ(insertNewlineIgnoringFieldEditor:)で届き、ここでは
                    // 扱っていないので同様に既定動作(改行)のまま素通しになる。
                    return false
                }
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // ここで消費すると CodeImpactOverlayView.onExitCommand(Esc で閉じる)に
                // 届かなくなる。false を返して素通しし、レスポンダチェーンの先に委ねる。
                return false
            }
            return false
        }
    }
}

/// progressRow が使う「調査中」表示。チャットでおなじみの、3 つの点が位相をずらして
/// 順に明滅するアニメーション(iMessage / ChatGPT の入力中表示のイメージ)。
/// スピナーより主張が弱く、質問応答パネルのチャット的な見た目に馴染むため採用した。
/// StreamingText(LiveSessionView.swift)と同じく `.task` ループで自前に時間を進める
/// (SwiftUI 標準の async/await のみで完結させ、外部依存は足さない)。
private struct ThinkingDots: View {
    /// タイマーで litIndex を切り替える階段駆動(300ms ごとに1つだけ点灯を移す)は、実機で
    /// 「カクカクして体験が悪い」という報告があった。ドットが 1 段ずつ切り替わる瞬間だけ
    /// アニメーションが効く駆動方式のため、opacity と scaleEffect の変化が段差として
    /// 目立っていた。`.animation(_:value:)` + `repeatForever` による連続した往復駆動
    /// (EQBars・RecBadge と同じ方式)に変え、ドットごとに delay をずらして波のように
    /// 順番に脈動させる(iMessage の入力中表示と同じ見た目)。
    @State private var pulsing = false

    private static let dotCount = 3
    private static let dotSize: CGFloat = 6
    /// 隣り合うドットの位相差。3 つで 1 周期(0.45s の往復)の半分弱ずらす。
    private static let dotDelayStep: Double = 0.15

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.dotCount, id: \.self) { index in
                Circle()
                    .fill(HCColor.textDim)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .opacity(pulsing ? 1 : 0.3)
                    // 明滅だけだと変化が乏しいため、点灯側で少しだけ大きくして脈動させる。
                    .scaleEffect(pulsing ? 1.15 : 0.8)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * Self.dotDelayStep),
                        value: pulsing)
            }
        }
        // ThinkingDots は progressRow(thinking:) から `if thinking { ThinkingDots() }` の
        // 形でしか使われず(呼び出し元 progressRow 参照)、進行中ターンの本文が届き始めた
        // 時点(thinking = false)や、ターンが確定して turnView の分岐が切り替わった時点で
        // このビュー自体が階層から外れる。repeatForever は稀にビュー消滅後も残ることが
        // あるとされるが、EQBars(常時表示のロゴ演出)と違い、このビューはそもそも
        // 短命(1ターンの「thinking 中」だけ)で使い回されないため、残留しても実害は無い。
        .onAppear { pulsing = true }
    }
}

/// questionBubble(for:) の実体。バブルを行の右端に寄せ、長文でも横幅いっぱいに
/// 伸びないよう最大幅を行の幅の8割程度に抑えて折り返す。
/// 自分の親からどれだけ幅を貰えるかは実行時にしか分からないため、`.frame(maxWidth: .infinity)`
/// で行いっぱいに広がった状態を GeometryReader を .background として重ねて計測し
/// (LevelMeter と同じ「幅だけ読む」書き方)、その8割を折り返しの上限として
/// バブル側の `.frame(maxWidth:)` に渡す。計測前(初回描画)は上限なしで一旦描画し、
/// 幅が判明した次のフレームで上限が効く。
private struct QuestionBubbleRow: View {
    let text: String
    @State private var rowWidth: CGFloat?

    var body: some View {
        Text(text)
            .font(HCFont.style(.subheadline, weight: .semibold))
            .foregroundStyle(HCColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                HCRadius.shape(HCRadius.control)
                    .fill(HCColor.surface))
            .frame(maxWidth: rowWidth.map { $0 * 0.8 }, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { rowWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, newWidth in rowWidth = newWidth }
                }
            )
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
/// 未操作なら、最新ターン・過去ターンとも折りたたみを初期値にする(結果を一望できるよう
/// 本文を畳んでおき、必要な見出しだけユーザーが開く)。
///
/// タイトルが「回答」のセクションは見出し行(chevron 含む)を出さず、本文だけを常時展開で
/// 表示する。質問バブルの直下に答えがそのまま続く見た目にするための特例。
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
    /// このターンの ```choices(AI 側からの選択肢確認)を操作できるか。確定ターン
    /// (turnID != nil)かつ最新ターンかつ model.codeImpactAnalysisState が .completed の
    /// ときだけ true になる(呼び出し側の resultView(turnIndex:turnID:result:isLatest:)が
    /// 判定して渡す)。false の間は ChoicesView 側で全体を disabled + 半透明にする。
    let isInteractive: Bool
    /// 質問応答パネルの対象セッション開始時刻。elapsedChipDisplay / convertWallClockTokens が
    /// 壁時計→経過時間の変換に使う。model.codeImpactTargetSessionStartDate は内部で
    /// sessions.first(where:) の線形探索を伴うため、トークン・行ごとに呼び直さず、
    /// このビューの生成時に 1 回だけ取得しておく。
    private let sessionStartDate: Date?
    /// init 時に一度だけパースした結果。View の body は result が変わるたびに
    /// (ストリーミングの断片・完了時の確定結果それぞれで)このビュー自体が作り直されるため、
    /// computed property にして body 評価ごとに全文パースし直す必要はない。
    /// 確定ターンは呼び出し側(turnsScrollView)が CodeImpactSectionsCache 経由で
    /// パース済みの sections を渡す(下の sections: init)ため、ここでの再パースは
    /// 進行中のターン(ストリーミングの断片)だけで起きる。
    private let sections: [Section]
    /// ```decision-history フェンス(経緯回答が該当議題を指定するもの)の抽出結果。
    /// 非 nil ならタイムラインカード(DecisionHistoryCardsView)を本文の下に描く。
    /// フェンスの抽出は sections のパースより前に行う(DecisionHistoryFence 参照)ため、
    /// sections にはフェンスの生 JSON は含まれない。
    private let decisionHistoryPrompt: DecisionHistoryFence.Prompt?
    /// ```decision-history フェンスの開始行はあるが閉じていない(ストリーミング途中)。
    /// 確定ターン(sections: init)はこの状態を経由しないため常に false。
    private let isDecisionHistoryPending: Bool

    init(result: String, model: AppModel, turnIndex: Int, isInteractive: Bool) {
        self.model = model
        self.turnIndex = turnIndex
        self.isInteractive = isInteractive
        self.sessionStartDate = model.codeImpactTargetSessionStartDate
        let extraction = DecisionHistoryFence.extractFirst(from: result)
        self.sections = Self.parseSections(from: extraction.body)
        self.decisionHistoryPrompt = extraction.prompt
        self.isDecisionHistoryPending = extraction.isPending
    }

    /// 確定ターン用: 呼び出し側(CodeImpactSectionsCache 経由)で既にパース済みの sections と
    /// decisionHistoryPrompt を受け取り、再パースを省く。
    init(
        sections: [Section], decisionHistoryPrompt: DecisionHistoryFence.Prompt?,
        model: AppModel, turnIndex: Int, isInteractive: Bool
    ) {
        self.model = model
        self.turnIndex = turnIndex
        self.isInteractive = isInteractive
        self.sessionStartDate = model.codeImpactTargetSessionStartDate
        self.sections = sections
        self.decisionHistoryPrompt = decisionHistoryPrompt
        self.isDecisionHistoryPending = false
    }

    fileprivate struct Section {
        let title: String?
        let segments: [Segment]
    }

    /// セクション本文をフェンスブロック単位で切り出したもの。
    /// ```mermaid フェンスと ```choices フェンスだけ特別扱いし、それ以外のフェンスは言語名を
    /// 捨てて一律コード表示にする。フェンスに挟まれていない行は従来どおり行単位で描画する。
    fileprivate enum Segment {
        case text([Substring])
        case code(String)
        case mermaid(String)
        case choices(ChoicePrompt)
        /// ストリーミング途中の書きかけ ```choices フェンス。生 JSON は見せず、
        /// 「選択肢を準備中」の合図(中央スピナー)だけを出すための場所取り。
        case choicesPending
    }

    /// ```choices フェンスの中身(JSON)をパースした結果。AI 側から選択肢を提示して
    /// 確認するための構造(AgentCodeImpactAnalyzer.questionPrompt の choicesParagraph 参照)。
    fileprivate struct ChoicePrompt {
        struct Option {
            let label: String
            let detail: String?
        }
        let question: String
        let options: [Option]
    }

    /// ```choices フェンスの JSON 本文と対応する Decodable。キー名はプロンプト側
    /// (choicesParagraph)と一致させること。
    private struct ChoicesJSON: Decodable {
        struct Option: Decodable {
            let label: String
            let detail: String?
        }
        let question: String
        let options: [Option]
    }

    /// choices フェンスの中身を ChoicePrompt にパースする。JSON として壊れている・
    /// question が空・options が 0 個のいずれかなら nil を返し、呼び出し側(segments(from:))は
    /// 通常のコード表示にフォールバックする(ストリーミング中の未完フェンスもここで弾かれる)。
    private static func parseChoicePrompt(_ json: String) -> ChoicePrompt? {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(ChoicesJSON.self, from: data)
        else { return nil }
        let question = decoded.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return nil }
        let options = decoded.options.compactMap { option -> ChoicePrompt.Option? in
            let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            let detail = option.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChoicePrompt.Option(label: label, detail: (detail?.isEmpty == false) ? detail : nil)
        }
        guard !options.isEmpty else { return nil }
        return ChoicePrompt(question: question, options: options)
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
                if language == "mermaid" {
                    result.append(.mermaid(joined))
                } else if language == "choices" {
                    // パースできた時だけ選択肢 UI として出す。壊れた JSON をコード表示へ
                    // 落とすと AI の内部形式(生 JSON)がそのまま画面に漏れるため、
                    // 失敗時は何も描画しない。
                    if let prompt = parseChoicePrompt(joined) {
                        result.append(.choices(prompt))
                    }
                } else {
                    result.append(.code(joined))
                }
                index = cursor + 1
            } else if language == "choices" {
                // ストリーミング途中の書きかけ choices フェンス。生 JSON を見せず、
                // 中央スピナー(choicesPending)で場所だけ知らせる。フェンスが閉じて
                // パースできた時に選択肢 UI へ置き換わる。
                result.append(.choicesPending)
                index = lines.count
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

    /// AI は ```choices フェンスを回答の末尾に置くため、パース結果ではそのまま最後の
    /// セクション(たとえば「根拠と補足」)の本文に紛れ込む。そのセクションが折りたたまれて
    /// いると選択肢が見えなくなってしまうため、描画側(body)で choices セグメントだけを
    /// 全セクションから抜き出し、セクション本文からは除いたうえでターンの一番下に
    /// 常時表示で出す。パース結果(CodeImpactSectionsCache のキャッシュ)自体はそのまま
    /// 使い回し、この組み替えは毎回の body 評価内で行う。
    private var sectionsWithoutChoices: [Section] {
        sections.compactMap { section in
            let filtered = section.segments.filter { segment in
                switch segment {
                case .choices, .choicesPending: return false
                default: return true
                }
            }
            // choices を抜いた結果すべて空になったセクション(中身が choices だけだった)は、
            // 見出しだけの空アコーディオンを残さない。
            if filtered.isEmpty, !section.segments.isEmpty { return nil }
            return Section(title: section.title, segments: filtered)
        }
    }

    /// 全セクションから抜き出した choices セグメント。プロンプト上は 1 個だけ出す約束
    /// (AgentCodeImpactAnalyzer.questionPrompt の choicesParagraph)だが、複数出力された
    /// 場合に備えて出現順に全部拾う。
    private var trailingChoicePrompts: [ChoicePrompt] {
        sections.flatMap { section in
            section.segments.compactMap { segment -> ChoicePrompt? in
                if case .choices(let prompt) = segment { return prompt }
                return nil
            }
        }
    }

    /// ストリーミング途中の書きかけ choices フェンスがあるか。choices と同じ理由で
    /// セクションの外(ターンの一番下)へ引き上げ、中央スピナーとして描く。
    private var hasPendingChoices: Bool {
        sections.contains { section in
            section.segments.contains { segment in
                if case .choicesPending = segment { return true }
                return false
            }
        }
    }

    var body: some View {
        // セクション同士の切れ目(例: 回答 ⇄ 次の一手、根拠と補足 ⇄ 選択肢)には、
        // セクション内部の行間(segmentBlock の spacing 8 や lineSpacing)より広い余白を
        // 追加で挟み、「ブロックの切れ目 > ブロック内の行間」の階層を作る。各セクション・
        // choices は自前で見出し直後の padding(.top, 10 前後)を持つため、ここでは
        // 先頭以外の要素にだけ追加で 8pt 足す(2 つ合わせて 18pt 前後がセクション区切りの
        // 目安になる)。
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sectionsWithoutChoices.enumerated()), id: \.offset) { index, section in
                sectionView(section: section)
                    .padding(.top, index == 0 ? 0 : 8)
            }
            if let decisionHistoryPrompt {
                // 経緯回答のタイムラインカード。AI の文章ではなく decisions.json の記録を
                // そのまま描く(DecisionHistoryCardsView 参照)。
                DecisionHistoryCardsView(topicIds: decisionHistoryPrompt.topicIds, model: model)
                    .padding(.top, sectionsWithoutChoices.isEmpty ? 0 : 18)
            } else if isDecisionHistoryPending {
                // カードの生成待ち(```decision-history フェンスの生成中)。choices の
                // 生成待ちと同じ、場所取りのスピナーだけを出す。
                HStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 10)
            }
            ForEach(Array(trailingChoicePrompts.enumerated()), id: \.offset) { index, prompt in
                ChoicesView(prompt: prompt, model: model, isInteractive: isInteractive)
                    .padding(.top, index == 0 ? 18 : 8)
            }
            if hasPendingChoices {
                // 選択肢の生成待ち。本文の下・中央で小さく回して「ここに何か出る」と伝える。
                HStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 本文中のファイルパスをクリックで開けるようにする(下の linkedInlineMarkdown が
        // .link にセットした file:// URL だけを対象にする)。http 等が AI 出力に混ざっても
        // 会議中に勝手にブラウザを開かないよう、file URL 以外は discarded にする。
        // タイムスタンプのジャンプ(model.revealTranscript(atTime:))は、以前はここを
        // 経由するリンク(hearcat-reveal スキーム)だったが、チップを Button 化した
        // ことで直接 model を呼べるようになり、このハンドラを経由しなくなった
        // (timestampBulletRow 参照)。
        .environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    /// 「(なし)」相当として実質空とみなす文字列。半角括弧・全角括弧・括弧無しの「なし」単体を
    /// すべて許容する(モデルの出力揺れを吸収するため)。
    private static let emptyNextStepPlaceholders: Set<String> = ["(なし)", "\u{FF08}なし\u{FF09}", "なし"]

    /// 「次の一手」セクションが実質空かどうか。.text セグメントの中身をすべて結合して
    /// trim した結果が、空文字か emptyNextStepPlaceholders のいずれかに一致する場合だけ
    /// true を返す。.code / .mermaid / .choices が 1 つでも含まれる場合は、実体のある
    /// コンテンツとみなして false(空扱いしない)。
    private static func isEffectivelyEmptyNextStep(_ segments: [Segment]) -> Bool {
        var combinedText = ""
        for segment in segments {
            switch segment {
            case .text(let lines):
                combinedText += lines.joined(separator: "\n")
            case .code, .mermaid, .choices, .choicesPending:
                return false
            }
        }
        let trimmed = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || Self.emptyNextStepPlaceholders.contains(trimmed)
    }

    @ViewBuilder
    private func sectionView(section: Section) -> some View {
        if let title = section.title {
            if title == AgentCodeImpactAnalyzer.answerSectionTitle {
                segmentBlock(section.segments)
            } else if title == AgentCodeImpactAnalyzer.nextStepSectionTitle {
                // プロンプト側(AgentCodeImpactAnalyzer.questionPrompt)は「次に確認・作業
                // すべきことが無ければ見出しごと出力しない」と指示済みだが、モデルが指示を
                // 誤って見出しだけ残し、本文に「(なし)」とだけ書いてくることが実機で
                // 発生した。プロンプト指示だけでは再発するため、表示側でも実質空なら
                // actionBlock(面を持つ強調ブロック)を描画しない保険を入れる。
                if !Self.isEffectivelyEmptyNextStep(section.segments) {
                    actionBlock(section.segments)
                }
            } else {
                // 見出しと本文の間(spacing)は詰めすぎない。ラベル直下に本文が張り付くと
                // 「根拠と補足」のような複数行リストが窮屈に見える。
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { toggle(title: title) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(HCFont.style(.caption1, weight: .semibold))
                                .foregroundStyle(HCColor.textDim)
                                .rotationEffect(.degrees(isExpanded(title: title) ? 90 : 0))
                            Text(title)
                                .font(HCFont.style(.callout, weight: .semibold))
                                .foregroundStyle(HCColor.textPrimary)
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

    /// 開閉判定。ユーザーが未操作なら、最新・過去ターンとも折りたたみを初期値にする
    /// (根拠と補足のような補足情報は、読みたい人だけが開けばよい)。
    private func isExpanded(title: String) -> Bool {
        model.codeImpactSectionOverrides[overrideKey(title: title)] ?? false
    }

    private func toggle(title: String) {
        model.codeImpactSectionOverrides[overrideKey(title: title)] = !isExpanded(title: title)
        codeImpactOverlayLogger.info(
            "セクション開閉: key=\(overrideKey(title: title), privacy: .public) 新値=\(isExpanded(title: title), privacy: .public)"
        )
    }

    /// 「次の一手」セクション専用の見た目。他のセクションの見出し行(`.padding(.top, 10)`)と
    /// 上マージンを揃えつつ、面を持つブロックとして本文を囲む。
    private func actionBlock(_ segments: [Segment]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // 唯一の強調ブロック。本文と同じ白系だとラベルが埋もれて読み分けづらいため、
            // ここのラベルと矢印だけアクセント色にする(押せる要素ではないが、パネルで
            // 一番見せたい行としての例外)。
            Image(systemName: "arrow.right")
                .font(HCFont.style(.callout, weight: .semibold))
                .foregroundStyle(HCColor.accentText)
            VStack(alignment: .leading, spacing: 4) {
                Text("次の一手")
                    .font(HCFont.style(.caption1, weight: .semibold))
                    .foregroundStyle(HCColor.accentText)
                segmentBlock(segments)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            HCRadius.shape(HCRadius.control)
                .fill(HCColor.surface))
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
        case .choices(let prompt):
            ChoicesView(prompt: prompt, model: model, isInteractive: isInteractive)
        case .choicesPending:
            // body 側でターンの一番下へ引き上げて中央スピナーとして描くため、
            // セクション内では何も出さない(sectionsWithoutChoices で除外済みのはずだが網羅用)。
            EmptyView()
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
                .foregroundStyle(HCColor.textPrimary)
                .padding(.top, 4)
        } else if raw.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer().frame(height: 2)
        } else {
            Text(linkedInlineMarkdown(raw))
                .font(HCFont.body)
                .foregroundStyle(HCColor.textBody)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 箇条書き 1 行の共通の骨組み(• + 先頭の特別要素(あれば)+ 本文)。デフォルトの
    /// 箇条書き(leading が EmptyView)と timestampBulletRow(leading にチップボタン)の
    /// 2 箇所がここを使う。pathBulletRow だけは、行頭要素(パス)と本文を別列に分けると
    /// 長い行で折り返しが崩れる問題があったため、1 本の AttributedString に流し込む
    /// 専用実装に切り替えており、ここは経由しない(パスは長くなりがちだが、タイムスタンプは
    /// elapsedChipDisplay の経過時間表記で最長 11 文字程度に収まるため、2 列構造でも崩れない)。
    private func bulletRow<Leading: View>(
        body: String, @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
                .font(HCFont.body)
                .foregroundStyle(HCColor.placeholderText)
            leading()
            Text(linkedInlineMarkdown(body))
                .font(HCFont.body)
                .foregroundStyle(HCColor.textBody)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 「- 相対パス — 説明」形式の箇条書き行専用のレイアウト。
    /// パス部分をボタン化した旧実装は、パスと説明をそれぞれ別列(2 列)として個別に
    /// 折り返していたため、パスが長いとリンクが千切れて説明文が右の狭い列に押し込まれる
    /// レイアウト崩れが起きていた。「パス — 説明」を 1 本の AttributedString にまとめ、
    /// bulletRow と同じ 1 本のテキストとして流し込み、通常の文章と同じ自然な折り返しに
    /// する(2 列構造をやめたので、この行専用に bulletRow は使わず直接組む)。
    /// パスのクリックは Button ではなく AttributedString の .link に任せる。開く処理は
    /// CodeImpactResultView.body の .environment(\.openURL, ...) が file URL を検知して
    /// NSWorkspace で開く。
    /// トレードオフ: Button をやめたため、パス部分にホバーしても指カーソルではなく I ビームに
    /// なる(以前は「.link のままだと I ビームになるため Button にした」という理由で
    /// Button 化していたが、長いパスで 2 列レイアウトが崩れる問題のほうを優先し、
    /// カーソル表現よりも折り返しの自然さを取った)。
    private func pathBulletRow(pathToken: String, description: String, url: URL) -> some View {
        var pathRun = AttributedString(pathToken)
        pathRun.font = HCFont.monospaced(size: 12)
        pathRun.foregroundColor = HCColor.accentText
        pathRun.underlineStyle = Text.LineStyle.single
        pathRun.link = url

        var descriptionRun = AttributedString(" — \(description)")
        descriptionRun.font = HCFont.body
        descriptionRun.foregroundColor = HCColor.textBody

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
                .font(HCFont.body)
                .foregroundStyle(HCColor.placeholderText)
            Text(pathRun + descriptionRun)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
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
    /// 検出する正規表現。`^` で行頭に固定し、直後が数字・コロン以外(または文字列終端)の
    /// 場合だけマッチさせる。空白限定にしないのは、`16:31:47「発言…」` のように時刻の直後に
    /// かぎ括弧が続く行もチップにするため。数字とコロンを除外しておけば、`12:345` のような
    /// 数字列の続きや `1:23:456` の部分一致を誤って時刻と見なすことはない。
    private static let timestampBulletRegex = try! NSRegularExpression(
        pattern: #"^\s*\d{1,2}:\d{2}(?::\d{2})?(\s*[〜~\-]\s*\d{1,2}:\d{2}(?::\d{2})?)?(?=[^\d:]|$)"#)

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

    /// タイムスタンプ行専用のレイアウト。
    /// 一時期、チップ(背景付きの別ビュー)をやめて本文と 1 本の AttributedString に
    /// インライン化していた。時刻部分をチップとして本文と別列に分けると、折り返し行が
    /// 本文列の頭に揃ってしまい、範囲表記(例 13:29:41〜13:30:11)のような長い壁時計表記
    /// だと左に太い溝ができて本文が痩せるレイアウト崩れが起きていたため。その後、チップの
    /// 表示を経過時間表記(elapsedChipDisplay、最長 11 文字程度)に変えたことで幅の問題が
    /// 解消したため、視認性の良いチップ表示(bulletRow の leading にチップボタンを渡す
    /// 2 列構成)に戻した。チップは押せる要素で、クリックすると model.revealTranscript(atTime:)
    /// で文字起こしの該当時刻へジャンプする(押せることが分かるよう、文字色はリンクと
    /// 同じ accentText にする)。

    /// チップの開始時刻(範囲表記なら前半)を取り出す。model.revealTranscript(atTime:) は
    /// 文字起こしの stamp(壁時計)と突き合わせて該当行へジャンプするため、経過時間表示
    /// (elapsedChipDisplay)とは別に、元の壁時計表記のまま渡す必要がある。
    private static func startWallClock(forChip chip: String) -> String? {
        guard let start = chip.split(whereSeparator: { "〜~-".contains($0) }).first else { return nil }
        return start.trimmingCharacters(in: .whitespaces)
    }

    /// "HH:MM" または "HH:MM:SS"(AI が引用する壁時計時刻)を、startDate を基準にした
    /// 経過時間(分:秒。SessionDetailView / LiveSessionView と同じ formatPlaybackTime の書式)へ
    /// 変換する薄い層。変換の実体(妥当性検証・秒への変換)は TranscriptParser.offsetSeconds に
    /// 一元化されている。ここでは allowDayCrossing: false を渡し、日をまたぐ場合の 24 時間補正は
    /// しない(TranscriptParser.lines の offset 計算と違い、こちらは transcript の全行を必ず
    /// どれかの offset へ解決する必要はなく、チップ表示のためのベストエフォートな変換のため、
    /// 自信が持てない時は壁時計のまま出す方が安全)。パースできない・範囲外・経過が負の
    /// いずれかに該当すれば nil を返し、呼び出し側は元の壁時計表記のまま出す。
    private static func elapsedTimeString(forWallClock stamp: String, startDate: Date) -> String? {
        guard let offset = TranscriptParser.offsetSeconds(
            forWallClock: stamp, sessionStart: startDate, allowDayCrossing: false)
        else { return nil }
        return formatPlaybackTime(TimeInterval(offset))
    }

    /// チップの表示だけを経過時間へ変換する(ジャンプ先は startWallClock(forChip:) 側で
    /// 元の壁時計時刻のまま持つ。ジャンプの一致判定は transcript の stamp = 壁時計で行うため、
    /// ジャンプ先まで経過時間に変えると比較が壊れる。表示とジャンプ先の基準をあえて分けている)。
    /// 開始時刻が引けない場合は元のチップ表記のまま返す。要素の変換可否の判定自体は
    /// elapsedDisplay(forToken:startDate:) に委ねる(convertWallClockTokens と共通のロジック)。
    /// startDate はビュー生成時に 1 回だけ取得した sessionStartDate をそのまま渡す
    /// (プロパティ宣言のコメント参照)。
    private func elapsedChipDisplay(forChip chip: String) -> String {
        guard let sessionStartDate else { return chip }
        return Self.elapsedDisplay(forToken: chip, startDate: sessionStartDate)
    }

    /// 壁時計トークン 1 件分(単一時刻、または「〜」「~」「-」で繋いだ範囲)を経過時間表記へ
    /// 変換する共通ロジック。elapsedChipDisplay(行頭チップ)と convertWallClockTokens
    /// (本文中のトークン)の双方から呼ばれる。範囲の要素が 1 つでも時刻として解釈できない・
    /// 経過が負になる場合は、トークン全体を元の表記のまま返す(範囲表記の片方だけ変換すると
    /// 余計に紛らわしいため)。
    private static func elapsedDisplay(forToken token: String, startDate: Date) -> String {
        let rawParts = token.split(whereSeparator: { "〜~-".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !rawParts.isEmpty else { return token }
        let converted = rawParts.map { elapsedTimeString(forWallClock: $0, startDate: startDate) }
        guard converted.allSatisfy({ $0 != nil }) else { return token }
        return converted.compactMap { $0 }.joined(separator: "〜")
    }

    /// 本文中に現れる秒付き壁時計トークン(`HH:MM:SS`、範囲 `HH:MM:SS[〜~-]HH:MM:SS` 含む)を
    /// 検出する正規表現。timestampBulletRegex(行頭チップ検出用)と違い `^` で行頭に固定せず、
    /// 文字列中のどこにでもマッチする。境界条件(直前が数字・コロンでない/直後が数字・コロン
    /// でない)は timestampBulletRegex と同じ考え方で、`12:345` のような部分一致を誤って
    /// 時刻と見なさないようにする。
    ///
    /// 秒(2 つ目の `:\d{2}`)を必須にしているのは、`HH:MM`(秒なし)を意図的に変換対象から
    /// 除外するため: 発言の引用(「6 時に集合」「13:30 からの会議」等)をここで書き換えてしまう
    /// 事故を防ぐ。壁時計の「時刻らしさ」だけでは発言中の時刻表現と区別できないが、この
    /// アプリが AI に指示している時刻引用の書式(秒付き `HH:MM:SS`、questionPrompt 参照)は
    /// 発言中の時刻表現とほぼ衝突しないため、秒の有無を安全な境界線として使っている。
    ///
    /// 範囲の後半だけ秒なし(例 `16:56:08-16:56`)の場合、後半はこの正規表現にマッチせず、
    /// 前半の `16:56:08` だけが独立したトークンとして変換対象になる。中途半端に見えるが、
    /// 秒なし側を書き換えないという安全側の挙動として許容する。
    private static let wallClockTokenRegex = try! NSRegularExpression(
        pattern: #"(?<![\d:])\d{1,2}:\d{2}:\d{2}(?:\s*[〜~\-]\s*\d{1,2}:\d{2}:\d{2})?(?![\d:])"#)

    /// 本文テキスト中の秒付き壁時計トークンを、セッション開始からの経過時間表記へ変換する。
    /// 行頭チップ(elapsedChipDisplay/timestampBulletRow)は既に変換済みだが、AI が本文の
    /// 途中にも時刻を書いてしまうことがあり(実機で `- 16:55:38, 16:56:08-16:56:23 削り…`
    /// のように 2 個目以降の時刻が壁時計のまま残る不具合が発生)、その対策として本文側にも
    /// 同じ変換を適用する。呼び出し元(linkedInlineMarkdown)が Markdown パース・パスの
    /// リンク化を行う前に呼ぶことで、パース対象の文字列自体を書き換えてから既存パースに渡す
    /// (文字列変換 → 既存パースの順を守る。パスのリンク化はコロンを含む文字列を候補にしない
    /// ため、時刻トークンの書き換えとは衝突しない)。
    /// 開始時刻が引けない場合は変換せずそのまま返す。startDate はビュー生成時に 1 回だけ
    /// 取得した sessionStartDate をそのまま使う(プロパティ宣言のコメント参照)。
    private func convertWallClockTokens(in text: String) -> String {
        guard let sessionStartDate else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = Self.wallClockTokenRegex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            result += text[cursor..<matchRange.lowerBound]
            let token = String(text[matchRange])
            result += Self.elapsedDisplay(forToken: token, startDate: sessionStartDate)
            cursor = matchRange.upperBound
        }
        result += text[cursor...]
        return result
    }

    private func timestampBulletRow(chip: String, rest: String) -> some View {
        let displayText = elapsedChipDisplay(forChip: chip)
        return bulletRow(body: rest) {
            if let start = Self.startWallClock(forChip: chip) {
                Button {
                    model.revealTranscript(atTime: start)
                } label: {
                    chipLabel(displayText)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            } else {
                // 開始時刻が取り出せない場合(timestampBulletComponents が空でない chip を
                // 保証しているため通常は起きない)は、押せない表示だけのチップにフォールバックする。
                chipLabel(displayText)
            }
        }
    }

    /// タイムスタンプチップの見た目そのもの(押せる/押せないの両方から使う)。
    /// 押せる要素として文字色は accentText にする。角丸面は HCRadius.chip(チップ寸法の面)。
    private func chipLabel(_ text: String) -> some View {
        Text(text)
            .font(HCFont.monospaced(size: 10.5))
            .foregroundStyle(HCColor.accentText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                HCRadius.shape(HCRadius.chip)
                    .fill(HCColor.surface))
    }

    /// inlineMarkdownText(SummaryView.swift 側の共通実装)に加えて、本文中の
    /// ファイルパスらしきトークンを実在確認のうえクリック可能なリンクにする。
    /// 実在しないトークンは見た目を変えない(誤リンクで存在しない場所を開いてしまうことを避けるため)。
    ///
    /// 太字・パスリンクの Markdown パースより先に convertWallClockTokens で秒付き壁時計
    /// トークンを経過時間表記へ書き換える(文字列変換 → 既存パースの順)。この関数は
    /// lineView の本文段落・bulletRow(timestampBulletRow の rest を含む)からしか呼ばれず、
    /// .code / .mermaid / choices の JSON はそもそも別経路(fenceCodeView 等)で描画されるため
    /// この変換を通らない。
    private func linkedInlineMarkdown(_ text: String) -> AttributedString {
        let text = convertWallClockTokens(in: text)
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
            linkRun.foregroundColor = HCColor.accentText
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

/// AI 側が ```choices フェンスで出した選択肢を提示し、ユーザーの回答(選択肢のラベル、
/// または「その他」の自由入力)を追加質問として model.requestFollowUpCodeImpact(question:) に
/// 渡す。Claude Code の AskUserQuestion に近い見た目(質問文 + ラジオ風の選択行 + 送信)を、
/// パネルのトーン(surface の面・accent のアクセント)に合わせて描く。
///
/// isInteractive が false の間(過去ターン・最新でも調査中・未完了)は全体を disabled にし、
/// 既存の過去ターン opacity(0.75)に馴染むよう半透明にする。選択状態はこのビューの @State
/// だけで持ち、送信後に view が作り直されて選択が消えることは許容する(新しいターンが
/// 積まれてこのターンは isLatest でなくなり、自動的に disabled 側の見た目に切り替わるため)。
private struct ChoicesView: View {
    let prompt: CodeImpactResultView.ChoicePrompt
    let model: AppModel
    let isInteractive: Bool

    /// 選択中の通常オプションの label。「その他」を選ぶとこちらは nil に戻す
    /// (通常オプションと「その他」は排他)。
    @State private var selectedLabel: String?
    @State private var isOtherSelected = false
    @State private var otherText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.question)
                .font(HCFont.style(.callout, weight: .semibold))
                .foregroundStyle(HCColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
                    optionRow(
                        label: option.label, detail: option.detail,
                        isSelected: !isOtherSelected && selectedLabel == option.label
                    ) {
                        selectedLabel = option.label
                        isOtherSelected = false
                    }
                }
                otherRow
            }

            HStack {
                Spacer()
                Button("送信", action: submit)
                    .buttonStyle(.hcPrimary)
                    .controlSize(.small)
                    .disabled(!canSubmit)
                    .pointingHandOnHover(disabled: !canSubmit)
                    // 選択肢をクリックすると入力欄からフォーカスが外れ、Return が
                    // どこにも届かずビープ音になる。ウィンドウ単位で効く既定アクションを
                    // 割り当て、フォーカスの位置に関わらず Enter で送信できるようにする
                    // (入力欄がフォーカスされている間は MultilineInputField(NSTextView)側の
                    // doCommandBy: が Return を先に受け取り true を返して処理を終えるため、
                    // 追加質問の送信とは衝突しない)。送信できない間は割り当てない。
                    .keyboardShortcut(canSubmit && isInteractive ? .defaultAction : nil)
            }
        }
        .disabled(!isInteractive)
        .opacity(isInteractive ? 1 : 0.75)
        // 選択状態を model.codeImpactPendingChoiceAnswer へ反映し、入力欄の Enter 送信
        // (CodeImpactOverlayView.submit())からも同じ回答を送れるようにする。isInteractive が
        // false になった(新しいターンが積まれて過去ターン扱いになった等)場合や、このビュー
        // 自体が消える場合は、他ターンの選択を誤って引き継がないよう nil に戻す。
        .onChange(of: selectedLabel) { _, _ in syncPendingAnswer() }
        .onChange(of: isOtherSelected) { _, _ in syncPendingAnswer() }
        .onChange(of: otherText) { _, _ in syncPendingAnswer() }
        .onChange(of: isInteractive) { _, _ in syncPendingAnswer() }
        .onDisappear { model.codeImpactPendingChoiceAnswer = nil }
    }

    private var canSubmit: Bool {
        if isOtherSelected {
            return !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return selectedLabel != nil
    }

    private func submit() {
        let answer: String
        if isOtherSelected {
            answer = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let selectedLabel {
            answer = selectedLabel
        } else {
            return
        }
        guard !answer.isEmpty else { return }
        model.requestFollowUpCodeImpact(question: answer)
    }

    /// canSubmit と同じ判定で pending answer を更新する(未選択・空文字は nil)。
    /// isInteractive が false の間は選択自体できない(disabled)ため、選択状態に関わらず nil。
    private func syncPendingAnswer() {
        guard isInteractive else {
            model.codeImpactPendingChoiceAnswer = nil
            return
        }
        if isOtherSelected {
            let trimmed = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
            model.codeImpactPendingChoiceAnswer = trimmed.isEmpty ? nil : trimmed
        } else {
            model.codeImpactPendingChoiceAnswer = selectedLabel
        }
    }

    /// 通常の選択肢 1 行。ラジオ風の丸 + label + 薄い detail。選択中は枠(accentStroke)+
    /// 丸の塗り(accent)で示す(押せる要素なのでアクセント色ルールに適合)。
    private func optionRow(
        label: String, detail: String?, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // 丸はラベルの文字行ではなく、カード(行全体)の縦中央に置く(Claude Code 本家の
            // AskUserQuestion と同じ配置)。説明付きの行だけ丸が 1 行目に張り付いて
            // 上ズレに見える問題は、文字行への光学合わせでは解決しなかった
            // (求められていたのはカード基準の中央だった)。
            HStack(alignment: .center, spacing: 10) {
                radioMark(isSelected: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(HCFont.style(.callout, weight: .semibold))
                        .foregroundStyle(HCColor.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(HCFont.caption)
                            .foregroundStyle(HCColor.textDim)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                HCRadius.shape(HCRadius.control)
                    .fill(HCColor.surface))
            .overlay(
                HCRadius.shape(HCRadius.control)
                    .stroke(isSelected ? HCColor.accentStroke : Color.clear, lineWidth: 1.2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover(disabled: !isInteractive)
    }

    /// 最後の「その他」行。選ぶとインラインの TextField(自由入力)が下に現れる。
    /// アプリ側が自動で付ける行のため、プロンプト側の options には含めない
    /// (AgentCodeImpactAnalyzer.questionPrompt の choicesParagraph 参照)。
    private var otherRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isOtherSelected = true
                selectedLabel = nil
            } label: {
                HStack(spacing: 10) {
                    radioMark(isSelected: isOtherSelected)
                    Text("その他")
                        .font(HCFont.style(.callout, weight: .semibold))
                        .foregroundStyle(HCColor.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    HCRadius.shape(HCRadius.control)
                        .fill(HCColor.surface))
                .overlay(
                    HCRadius.shape(HCRadius.control)
                        .stroke(isOtherSelected ? HCColor.accentStroke : Color.clear, lineWidth: 1.2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandOnHover(disabled: !isInteractive)

            if isOtherSelected {
                TextField("自由に入力", text: $otherText)
                    .textFieldStyle(.plain)
                    .font(HCFont.callout)
                    .foregroundStyle(HCColor.textBody)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        HCRadius.shape(HCRadius.control)
                            .fill(HCColor.panel))
                    .overlay(
                        HCRadius.shape(HCRadius.control)
                            .stroke(HCColor.strokeLine, lineWidth: 1))
                    .padding(.leading, 26)
                    .onSubmit {
                        if canSubmit { submit() }
                    }
            }
        }
    }

    private func radioMark(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(isSelected ? HCColor.accentStroke : HCColor.strokeLine, lineWidth: 1.2)
                .frame(width: 16, height: 16)
            if isSelected {
                Circle()
                    .fill(HCColor.accent)
                    .frame(width: 8, height: 8)
            }
        }
    }
}

/// 確定ターンのパース結果のキャッシュ。ストリーミング中(120ms ごと)の再描画では、
/// 進行中のターン以外は結果文字列が変わらないため、過去ターンぶんの
/// DecisionHistoryFence.extractFirst → parseSections を毎回やり直す必要はない。
/// turn.id(UUID)をキーに持つだけの単純な Dictionary(要素数は高々数十件なので、
/// ResolvedPathCache のように NSCache に任せるほどの規模ではない)。
@MainActor
private final class CodeImpactSectionsCache {
    static let shared = CodeImpactSectionsCache()

    /// sections(```choices 等を含むセクション本文)と decisionHistoryPrompt
    /// (```decision-history フェンスの抽出結果)は同じ1回のパースで確定するため、セットで持つ。
    struct Parsed {
        let sections: [CodeImpactResultView.Section]
        let decisionHistoryPrompt: DecisionHistoryFence.Prompt?
    }

    private var storage: [UUID: Parsed] = [:]

    /// 既にパース済みならそれを返し、無ければ parse() の結果を格納してから返す。
    func parsed(for turnID: UUID, parse: () -> Parsed) -> Parsed {
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
        .foregroundStyle(HCColor.textBody)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            HCRadius.shape(HCRadius.control)
                .fill(HCColor.surface))
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
