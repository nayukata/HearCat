import AppKit
import HearCatKit
import SwiftUI

/// 要約本文の描き方。画面表示(SummaryView)と画像書き出し(SummaryShareCard)で、
/// セクション構成は共有したまま見た目と操作性だけを切り替える。
/// 構成そのものを2つ持つと、要約の形式を変えたときに片方だけ古いまま残り、
/// 画像側の欠落は受け取った相手にしか見えない。
struct SummaryBodyStyle {
    let headingStyle: AnyShapeStyle
    let bodyStyle: AnyShapeStyle
    let font: Font
    /// font と同じ大きさの NSFont.TextStyle。inlineMarkdownText が強調(**太字**)の描画に
    /// カスケード済みの太字フォントを組み直す際、font から段を逆算できないため別途持つ。
    let bodyTextStyle: NSFont.TextStyle
    /// 話題を折りたたみにして、本文を選択可能にするか。画像では固定表示にする。
    let isInteractive: Bool
    /// 「話題ごとのまとめ」を含めるか。画像の要点モードでは落とす。
    let includesTopics: Bool

    /// アプリ内の表示。色は環境に任せる(明暗どちらのテーマでも読める)。
    static let screen = SummaryBodyStyle(
        headingStyle: AnyShapeStyle(.secondary),
        bodyStyle: AnyShapeStyle(.primary),
        font: HCFont.body,
        bodyTextStyle: .body,
        isInteractive: true,
        includesTopics: true)

    /// 他の人へ渡す画像。暗い背景に固定するため、色も明示する。
    static func shareCard(includesTopics: Bool) -> SummaryBodyStyle {
        SummaryBodyStyle(
            headingStyle: AnyShapeStyle(HCColor.cinnamon),
            bodyStyle: AnyShapeStyle(HCColor.mistBody),
            font: HCFont.callout,
            bodyTextStyle: .callout,
            isInteractive: false,
            includesTopics: includesTopics)
    }
}

/// 要約の構造化表示。想定の 4 セクション形式(概要 / 話題ごとのまとめ / 決定事項 /
/// TODO・宿題)なら見出し・折りたたみ・担当チップで描画し、形式が想定外なら
/// 原文をそのまま表示する(内容を欠落させないことを優先)。
struct SummaryView: View {
    let markdown: String

    var body: some View {
        SummaryBody(markdown: markdown, style: .screen)
            // GroupBox 既定の内側余白は薄く、本文が枠線に張り付いて見えるため足す。
            .padding(8)
    }
}

/// 要約本文。形式が想定外なら原文をそのまま出す。
struct SummaryBody: View {
    let markdown: String
    let style: SummaryBodyStyle

    var body: some View {
        if let parsed = SummaryParser.parse(markdown) {
            StructuredSummaryView(summary: parsed, style: style)
        } else {
            Text(markdown)
                .font(style.font)
                .foregroundStyle(style.bodyStyle)
                .selectableText(style.isInteractive)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StructuredSummaryView: View {
    let summary: ParsedSummary
    let style: SummaryBodyStyle

    var body: some View {
        // 近接の法則: 見出しは自分の中身とだけ視覚的にまとまるよう、
        // 見出し⇔中身(6pt)よりセクション間(20pt)を大きく離す。
        VStack(alignment: .leading, spacing: 20) {
            if !summary.overview.isEmpty {
                section("概要") {
                    text(summary.overview)
                }
            }

            if style.includesTopics, !summary.topics.isEmpty {
                section("話題ごとのまとめ") {
                    VStack(alignment: .leading, spacing: style.isInteractive ? 4 : 12) {
                        ForEach(summary.topics) { topic in
                            TopicRow(topic: topic, style: style)
                        }
                    }
                }
            }

            // 決定事項と TODO は「無い」ことにも意味がある(決定の無い会議だったと
            // 分かる)ため、空でも見出しごと出して「なし」を明示する。
            //
            // 決定事項のチェックは「合意されたもの」を示すため、意味に沿って緑で塗る。
            // アイコンサイズも本文と同じ callout まで上げて、リストの中で見つけやすく
            // する(caption だと視線を誘導できないほど小さい)。
            section("決定事項") {
                itemList(
                    summary.decisions,
                    icon: "checkmark.circle.fill",
                    iconStyle: AnyShapeStyle(Color.green),
                    iconFont: HCFont.callout)
            }

            section("TODO・宿題") {
                if summary.todos.isEmpty {
                    emptyNote
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.todos) { todo in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "circle")
                                    .font(HCFont.caption)
                                    .foregroundStyle(.secondary)
                                text(todo.text)
                                if let assignee = todo.assignee {
                                    AssigneeChip(name: assignee, style: style)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// セクション1つぶん(見出し + 中身)。見出しと中身を1つのグループとして描画する。
    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(HCFont.style(.subheadline, weight: .semibold))
                .foregroundStyle(style.headingStyle)
            content()
        }
    }

    @ViewBuilder
    private func itemList(
        _ items: [String], icon: String, iconStyle: AnyShapeStyle,
        iconFont: Font = HCFont.caption
    ) -> some View {
        if items.isEmpty {
            emptyNote
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon)
                            .font(iconFont)
                            .foregroundStyle(iconStyle)
                        text(item)
                    }
                }
            }
        }
    }

    /// 本文1つぶん。行内 Markdown の解釈と、書体・色・選択可否をここに集約する。
    private func text(_ body: String) -> some View {
        Text(inlineMarkdownText(body, boldTextStyle: style.bodyTextStyle))
            .font(style.font)
            .foregroundStyle(style.bodyStyle)
            .selectableText(style.isInteractive)
    }

    private var emptyNote: some View {
        Text("(なし)")
            .font(style.font)
            .foregroundStyle(.secondary)
    }
}

/// 話題1つぶん。画面では折りたたみで描画するが、初期状態は開いておく(閉じたままだと
/// 中身を読むのに全話題をクリックする羽目になる。興味のない話題を閉じる操作の
/// ほうが少ない)。画像では折りたたみ自体を使わず、見出しと中身をそのまま並べる。
/// 見出しの無い話題(### より前の本文)は項目をそのまま並べる。
private struct TopicRow: View {
    let topic: ParsedSummary.Topic
    let style: SummaryBodyStyle
    @State private var isExpanded = true

    var body: some View {
        if topic.title.isEmpty {
            blocks
        } else if topic.blocks.isEmpty {
            title
        } else if style.isInteractive {
            DisclosureGroup(isExpanded: $isExpanded) {
                blocks
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            } label: {
                // 既定では開閉が矢印クリックにしか反応しないため、
                // タイトル行のどこを押しても開閉できるようにする。
                title
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { isExpanded.toggle() }
                    }
                    .pointingHandOnHover()
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                title
                blocks
            }
        }
    }

    private var title: some View {
        Text(inlineMarkdownText(topic.title, boldTextStyle: style.bodyTextStyle))
            .font(HCFont.style(style.isInteractive ? .body : .callout, weight: .medium))
            .selectableText(style.isInteractive)
    }

    /// 話題の本文。段落(自然文)はそのまま、箇条書きは「•」付きで描画する。
    private var blocks: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(topic.blocks) { block in
                if block.isBullet {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        body(block.text)
                    }
                } else {
                    body(block.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func body(_ text: String) -> some View {
        Text(inlineMarkdownText(text, boldTextStyle: style.bodyTextStyle))
            .font(style.font)
            .foregroundStyle(style.bodyStyle)
            .selectableText(style.isInteractive)
    }
}

/// TODO の担当者チップ。セッション一覧のグループ表示と同じ .quaternary のカプセル。
/// 画像では背景が暗色固定になるため、アクセント色で塗る。
private struct AssigneeChip: View {
    let name: String
    let style: SummaryBodyStyle

    var body: some View {
        Text(name)
            .font(HCFont.style(.subheadline, weight: .semibold))
            .foregroundStyle(style.isInteractive ? AnyShapeStyle(.secondary) : AnyShapeStyle(HCColor.cinnamon))
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(
                    style.isInteractive
                        ? AnyShapeStyle(.quaternary) : AnyShapeStyle(HCColor.cinnamon.opacity(0.14))))
            .fixedSize()
    }
}

extension View {
    /// 文字を選択できるようにするか。textSelection(.enabled) と (.disabled) は
    /// 型が違って三項演算子で選べないため、分岐をここに閉じ込める。
    @ViewBuilder
    fileprivate func selectableText(_ enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}

/// 行内の Markdown 装飾(**強調** など)だけを解釈して描画用の文字列にする。
/// 解釈に失敗したら原文のまま表示する。
/// SummaryView と CodeImpactOverlay(調査結果のインライン装飾)の両方から使う共通実装。
///
/// boldTextStyle は呼び出し箇所の本文の大きさ(NSFont.TextStyle)。既定は .body。
/// AttributedString の markdown パースは、強調(**太字**)を「現在の書体に bold トレイトを
/// 乗せる」形で表現するが、HCFont(DesignTokens.swift)は日本語をカスケードリストで
/// 「NotoSansJP-Bold」のような太さ固定の名前付きインスタンスへ流しており、bold トレイトが
/// 日本語グリフには反映されない(英数の SF だけ太くなる)。パース後に強調 run だけを走査し、
/// カスケードが効いた太字フォントを明示的に設定して補う。
func inlineMarkdownText(_ text: String, boldTextStyle: NSFont.TextStyle = .body) -> AttributedString {
    var result =
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)

    // 本文 (Regular) との差が太さだけでは弱く「太字がどこか分からない」ため、
    // 一段強い太さ (ExtraBold 相当) と明るい文字色の両方で持ち上げる。
    let boldFont = HCFont.style(boldTextStyle, weight: .heavy)
    // 範囲を集めてから書き換える (属性の変更で runs の区切りが変わるため)。強調の
    // intent は必ず消す: 残したままフォントを上書きすると、intent 由来の太字合成が
    // 二重にかかり、強調部分だけ字が約 1 割縮んで描画される (実測で確認済み)。
    let emphasizedRanges = result.runs.compactMap { run -> Range<AttributedString.Index>? in
        guard let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) else {
            return nil
        }
        return run.range
    }
    for range in emphasizedRanges {
        result[range].font = boldFont
        result[range].foregroundColor = HCColor.textPrimary
        result[range].inlinePresentationIntent = nil
    }
    return result
}
