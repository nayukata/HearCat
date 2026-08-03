import AppKit
import HearCatKit
import SwiftUI

/// 画像として書き出す要約カードの範囲。
enum SummaryShareScope: CaseIterable {
    /// 概要・決定事項・TODO だけ。会議の用件が一目で伝わる長さに収める。
    case essentials
    /// 話題ごとのまとめまで含めた全部。内容は落ちないが、長い会議では画像が縦に伸びる。
    case full

    var menuTitle: String {
        switch self {
        case .essentials: return "要約を画像でコピー (要点だけ)"
        case .full: return "要約を画像でコピー (全文)"
        }
    }

    var menuSubtitle: String {
        switch self {
        case .essentials: return "概要・決定事項・TODO。Slack やメールに貼りやすい長さ"
        case .full: return "話題ごとのまとめも含める。長い会議では縦に長い画像になる"
        }
    }
}

/// 他の人へ渡すための要約カード。HearCat を使っていない相手が受け取る面なので、
/// 画面表示(SummaryView)と本文の組み立てを共有しつつ、外枠だけを画像用に固定する。
///
/// 画像用に固定するもの(いずれも SummaryBodyStyle と外枠で吸収できる):
/// - 折りたたみと文字選択を無効にする(開閉状態が写り込まないように)
/// - 幅を固定する(ウィンドウの大きさで画像の横幅が変わらないように)
/// - 背景を敷く(ImageRenderer は背景を描かないため、透明のまま貼ると文字が消える)
struct SummaryShareCard: View {
    let session: SessionInfo
    let markdown: String
    let scope: SummaryShareScope

    /// 貼り先で潰れず、かつ横に間延びしない幅。本文の1行が長くなりすぎない値にした。
    static let width: CGFloat = 620

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            SummaryBody(
                markdown: markdown,
                style: .shareCard(includesTopics: scope == .full))
            footer
        }
        .padding(28)
        .frame(width: Self.width, alignment: .leading)
        .background(HCColor.mistDark)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            catMark
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name.isEmpty ? "会議の要約" : session.name)
                    .font(HCFont.style(.title3, weight: .semibold))
                    .foregroundStyle(HCColor.mistWhite)
                Text(session.startDate.formatted(date: .long, time: .shortened))
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.mistWhiteDim)
            }
            Spacer(minLength: 0)
        }
    }

    private var catMark: some View {
        HCLogoShape()
            .fill(HCColor.mistWhite, style: FillStyle(eoFill: true))
            .frame(width: 26, height: 26)
    }

    /// 受け取った人がこれが何なのかを辿れるようにする一行。
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(HCColor.mistDividerStrong)
                .frame(height: 1)
            HStack(spacing: 6) {
                Text("HearCat")
                    .font(HCFont.style(.caption1, weight: .semibold))
                    .foregroundStyle(HCColor.mistWhiteDim)
                Text("会議中にメモを取らなくていい、Mac の文字起こし")
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.mistPlaceholder)
                Spacer(minLength: 0)
            }
        }
    }
}

/// 要約カードを画像にしてクリップボードへ載せる。
enum SummaryShareImage {
    /// Retina で貼っても文字がぼやけない倍率。
    private static let scale: CGFloat = 2

    struct RenderFailed: LocalizedError {
        var errorDescription: String? { "画像を作れませんでした" }
    }

    /// カードを PNG にして、同じ項目にテキスト版も一緒に載せる。
    /// 画像を扱えない貼り先(プレーンテキストの入力欄など)ではテキストが落ちるようにするため、
    /// 2 項目に分けず 1 項目へ両方の型を持たせる。
    @MainActor
    static func copyToPasteboard(
        session: SessionInfo, markdown: String, scope: SummaryShareScope
    ) throws {
        let card = SummaryShareCard(session: session, markdown: markdown, scope: scope)
            .environment(\.font, HCFont.body)
        let renderer = ImageRenderer(content: card)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .png, properties: [:])
        else {
            throw RenderFailed()
        }

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString(markdown, forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
}
