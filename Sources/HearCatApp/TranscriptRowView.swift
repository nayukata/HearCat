import HearCatKit
import SwiftUI

/// 文字起こしの 1 行(経過時間・話者チップ・本文)。ライブ画面(LiveSessionView)と
/// 質問パネルの「文字起こし」タブが同じ見た目になるよう共有する。
/// 認識中(volatile)の行は時刻の代わりに「認識中」を出し、本文を暫定テキストとして追いかけ表示する。
struct TranscriptRowView: View {
    /// 行頭の経過時間。nil は認識中の行。
    let timeLabel: String?
    /// nil は話者の付かない行(ヘッダなど)。チップを出さない。
    let speaker: String?
    var speakerName: String?
    let text: String
    var volatile = false
    var isRevealed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // 表示は経過時間(分:秒)に統一する(履歴詳細・質問応答パネルの根拠チップと同じ物差し)。
            Text(timeLabel ?? "認識中")
                .font(HCFont.timecode)
                .foregroundStyle(HCColor.lift(0.34))
                // 幅 66 は元々 "[HH:mm:ss]"(10 文字)を収める値だった。経過時間の最長想定
                // "999:59" 程度(6 文字、"認識中" と同程度)はそれより短いため、そのまま流用できる。
                .frame(width: 66, alignment: timeLabel == nil ? .center : .leading)
            if let speaker {
                SpeakerChip(speaker: speaker, name: speakerName)
            }
            if volatile {
                StreamingText(target: text)
                    .foregroundStyle(HCColor.lift(0.5))
                    .font(HCFont.body)
            } else {
                Text(text)
                    .foregroundStyle(HCColor.lift(0.88))
                    .font(HCFont.body)
                    .textSelection(.enabled)
            }
        }
        // 質問応答パネルからのジャンプ先を、一時的な背景色でフェードイン→フェードアウトさせる
        // (SessionDetailView と共有する RevealHighlight)。
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .modifier(RevealHighlight(isRevealed: isRevealed))
    }
}

/// 暫定テキストを1文字ずつ追いかけて表示する(AI チャットのストリーム出力風)。
/// 認識器の暫定結果は文節単位の塊で丸ごと置き換わるため、そのまま出すと
/// 数語ずつ飛んで見える。表示側だけで目標テキストへ少しずつ追いつかせ、
/// 内容は変えずに見え方を滑らかにする。
struct StreamingText: View {
    let target: String
    @State private var displayed = ""
    @State private var caretOn = true
    @Environment(\.colorScheme) private var colorScheme

    /// キャレットの画像。LP の .u.partial .b::after と同じ 2×14px の棒 + 左に 3px の間隔。
    /// Text 内には図形ビューを置けないため画像として補間する(ビューを横に並べると、
    /// テキストが折り返した時に最終文字の隣でなく段落全体の右側に出てしまう)。
    /// 点滅で本文の折り返しが変わらないよう、消えている間も同じ寸法の透明画像で場所を確保する。
    /// NSImage は SwiftUI の外観切替に自動追従しないため、adaptive な HCColor.accent には
    /// 頼らず、ダーク/ライトそれぞれの実色で画像を分けて生成する。
    private static func makeCaret(visible: Bool, dark: Bool) -> NSImage {
        NSImage(size: NSSize(width: 5, height: 14), flipped: false) { _ in
            if visible {
                NSColor(dark ? HCColor.cinnamon : HCColor.spruce).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: 3, y: 0, width: 2, height: 14), xRadius: 1, yRadius: 1
                ).fill()
            }
            return true
        }
    }
    private static let caretShownDark = makeCaret(visible: true, dark: true)
    private static let caretShownLight = makeCaret(visible: true, dark: false)
    private static let caretHidden = makeCaret(visible: false, dark: true)

    private var caretShown: NSImage {
        colorScheme == .dark ? Self.caretShownDark : Self.caretShownLight
    }

    var body: some View {
        Text("\(displayed)\(Image(nsImage: caretOn ? caretShown : Self.caretHidden))")
            .task(id: target) {
                // 仮説が途中から書き換わった場合は、一致している先頭部分まで戻してから追う。
                let common = displayed.commonPrefix(with: target)
                if common.count < displayed.count { displayed = common }
                while displayed.count < target.count {
                    // 離れているほど速く追いつく(長文の一括置き換えでも1秒以内に追いつき、
                    // 末尾に近づくほど1文字ずつの見え方になる)。
                    let backlog = target.count - displayed.count
                    let step = max(1, backlog / 8)
                    displayed = String(target.prefix(displayed.count + step))
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                }
            }
            .task {
                // 追いついて待っている間だけ点滅させる(流れている間は実線)。
                // 点滅で幅が変わらないよう、消えている間も透明で場所は確保する。
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { return }
                    caretOn = displayed == target ? !caretOn : true
                }
            }
    }
}
