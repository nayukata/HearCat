import HearCatKit
import SwiftUI

/// 要約の構造化表示。想定の 4 セクション形式(概要 / 話題ごとのまとめ / 決定事項 /
/// TODO・宿題)なら見出し・折りたたみ・担当チップで描画し、形式が想定外なら
/// 原文をそのまま表示する(内容を欠落させないことを優先)。
struct SummaryView: View {
    let markdown: String

    var body: some View {
        Group {
            if let parsed = SummaryParser.parse(markdown) {
                StructuredSummaryView(summary: parsed)
            } else {
                Text(markdown)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // GroupBox 既定の内側余白は薄く、本文が枠線に張り付いて見えるため足す。
        .padding(8)
    }
}

private struct StructuredSummaryView: View {
    let summary: ParsedSummary

    var body: some View {
        // 近接の法則: 見出しは自分の中身とだけ視覚的にまとまるよう、
        // 見出し⇔中身(6pt)よりセクション間(20pt)を大きく離す。
        VStack(alignment: .leading, spacing: 20) {
            if !summary.overview.isEmpty {
                section("概要") {
                    Text(inline(summary.overview))
                        .textSelection(.enabled)
                }
            }

            if !summary.topics.isEmpty {
                section("話題ごとのまとめ") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.topics) { topic in
                            TopicRow(topic: topic)
                        }
                    }
                }
            }

            // 決定事項と TODO は「無い」ことにも意味がある(決定の無い会議だったと
            // 分かる)ため、空でも見出しごと出して「なし」を明示する。
            section("決定事項") {
                itemList(summary.decisions, icon: "checkmark.circle", iconStyle: .tint)
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
                                Text(inline(todo.text))
                                    .textSelection(.enabled)
                                if let assignee = todo.assignee {
                                    AssigneeChip(name: assignee)
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
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func itemList(
        _ items: [String], icon: String, iconStyle: some ShapeStyle
    ) -> some View {
        if items.isEmpty {
            emptyNote
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon)
                            .font(HCFont.caption)
                            .foregroundStyle(iconStyle)
                        Text(inline(item))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var emptyNote: some View {
        Text("(なし)")
            .foregroundStyle(.secondary)
    }
}

/// 話題1つぶん。折りたたみで描画するが、初期状態は開いておく(閉じたままだと
/// 中身を読むのに全話題をクリックする羽目になる。興味のない話題を閉じる操作の
/// ほうが少ない)。見出しの無い話題(### より前の本文)は項目をそのまま並べる。
private struct TopicRow: View {
    let topic: ParsedSummary.Topic
    @State private var isExpanded = true

    var body: some View {
        if topic.title.isEmpty {
            blocks
        } else if topic.blocks.isEmpty {
            Text(inline(topic.title))
                .font(HCFont.style(.body, weight: .medium))
                .textSelection(.enabled)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                blocks
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            } label: {
                // 既定では開閉が矢印クリックにしか反応しないため、
                // タイトル行のどこを押しても開閉できるようにする。
                Text(inline(topic.title))
                    .font(HCFont.style(.body, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { isExpanded.toggle() }
                    }
            }
        }
    }

    /// 話題の本文。段落(自然文)はそのまま、箇条書きは「•」付きで描画する。
    private var blocks: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(topic.blocks) { block in
                if block.isBullet {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(inline(block.text))
                            .textSelection(.enabled)
                    }
                } else {
                    Text(inline(block.text))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// TODO の担当者チップ。セッション一覧のグループ表示と同じ .quaternary のカプセル。
private struct AssigneeChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(HCFont.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .fixedSize()
    }
}

/// 行内の Markdown 装飾(**強調** など)だけを解釈して描画用の文字列にする。
/// 解釈に失敗したら原文のまま表示する。
private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}
