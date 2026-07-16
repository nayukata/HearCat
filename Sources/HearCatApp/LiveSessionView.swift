import HearCatKit
import SwiftUI

/// 進行中セッションのライブ表示。LP のヒーローにある「HearCat — ライブ」ウィンドウと同じ見た目。
/// 確定した発話に加えて、喋っている途中の暫定テキストを薄い色で出す(ファイルには確定分しか書かれない)。
struct LiveSessionView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            transcriptList
        }
        .background(HCColor.navyBackground)
        // ライブ画面はシステムの外観設定に関わらずネイビー基調(LP と同じ)。
        .environment(\.colorScheme, .dark)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            CatHeadShape()
                .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                .overlay(CatHeadShape.Eyes().fill(.white.opacity(0.6)))
                .frame(width: 15, height: 15)
            Text("HearCat — ライブ")
                .font(HCFont.system(size: 12))
                .foregroundStyle(HCColor.whiteDim)
            EQBars(active: model.status.transcribing)
            if model.status.recording {
                RecBadge()
            }
            Spacer()
            Toggle("録音", isOn: Binding(
                get: { model.status.recording },
                set: { model.setRecording($0) }))
            Toggle("文字起こし", isOn: Binding(
                get: { model.status.transcribing },
                set: { model.setTranscribing($0) }))
            if !model.liveFinals.isEmpty {
                CopyButton {
                    model.liveFinals.map(TranscriptWriter.line(for:)).joined(separator: "\n")
                }
            }
            Button("停止", role: .destructive) {
                Task { await model.stopSession() }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(HCColor.blue)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let error = model.status.systemAudioError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    // 並びは LiveTimeline が管理する(一度出た行はその場から動かさない)。
                    ForEach(model.liveTimeline.rows) { row in
                        segmentLine(
                            time: row.volatile ? nil : row.time, speaker: row.speaker,
                            text: row.text, volatile: row.volatile)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.liveTimeline.rows) {
                proxy.scrollTo("bottom")
            }
        }
    }

    private func segmentLine(time: Date?, speaker: String, text: String, volatile: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time.map { "[" + $0.formatted(date: .omitted, time: .standard) + "]" } ?? "認識中")
                .font(HCFont.monospaced(size: 10.5))
                .foregroundStyle(.white.opacity(0.34))
                .frame(width: 66, alignment: time == nil ? .center : .leading)
            SpeakerChip(speaker: speaker)
            if volatile {
                StreamingText(target: text)
                    .foregroundStyle(.white.opacity(0.5))
                    .font(HCFont.system(size: 13.5))
            } else {
                Text(text)
                    .foregroundStyle(.white.opacity(0.88))
                    .font(HCFont.system(size: 13.5))
                    .textSelection(.enabled)
            }
        }
    }
}

/// 暫定テキストを1文字ずつ追いかけて表示する(AI チャットのストリーム出力風)。
/// 認識器の暫定結果は文節単位の塊で丸ごと置き換わるため、そのまま出すと
/// 数語ずつ飛んで見える。表示側だけで目標テキストへ少しずつ追いつかせ、
/// 内容は変えずに見え方を滑らかにする。
private struct StreamingText: View {
    let target: String
    @State private var displayed = ""
    @State private var caretOn = true

    /// キャレットの画像。LP の .u.partial .b::after と同じ 2×14px の棒 + 左に 3px の間隔。
    /// Text 内には図形ビューを置けないため画像として補間する(ビューを横に並べると、
    /// テキストが折り返した時に最終文字の隣でなく段落全体の右側に出てしまう)。
    /// 点滅で本文の折り返しが変わらないよう、消えている間も同じ寸法の透明画像で場所を確保する。
    private static func makeCaret(visible: Bool) -> NSImage {
        NSImage(size: NSSize(width: 5, height: 14), flipped: false) { _ in
            if visible {
                NSColor(HCColor.blueSoft).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: 3, y: 0, width: 2, height: 14), xRadius: 1, yRadius: 1
                ).fill()
            }
            return true
        }
    }
    private static let caretShown = makeCaret(visible: true)
    private static let caretHidden = makeCaret(visible: false)

    var body: some View {
        Text("\(displayed)\(Image(nsImage: caretOn ? Self.caretShown : Self.caretHidden))")
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
