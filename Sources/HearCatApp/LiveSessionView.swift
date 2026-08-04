import HearCatKit
import SwiftUI

/// 進行中セッションのライブ表示。LP のヒーローにある「HearCat — ライブ」ウィンドウと同じ見た目。
/// 確定した発話に加えて、喋っている途中の暫定テキストを薄い色で出す(ファイルには確定分しか書かれない)。
struct LiveSessionView: View {
    let model: AppModel

    /// 質問応答パネルからのジャンプで、今フェード中にハイライトしている行(LiveTimeline.Row.id)。
    /// 収束スクロール・点灯・フェード消灯の一連の演出は RevealCoordinator
    /// (SessionDetailView と共有)に委ねる。
    @State private var revealCoordinator = RevealCoordinator<String>()

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            transcriptList
        }
        .background(HCColor.mistDark)
        // ライブ画面はシステムの外観設定に関わらずネイビー基調(LP と同じ)。
        .environment(\.colorScheme, .dark)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            HCLogoShape()
                .fill(.white.opacity(0.6), style: FillStyle(eoFill: true))
                .frame(width: 15, height: 15)
            Text("HearCat — ライブ")
                .font(HCFont.callout)
                .foregroundStyle(HCColor.mistWhiteDim)
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
            if !AgentCLIDetector.shared.availableCLIs.isEmpty {
                Button {
                    model.openCodeImpactPanel()
                } label: {
                    Image(systemName: "questionmark.bubble")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("AI に質問")
                .disabled(!model.status.transcribing)
            }
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
        .tint(HCColor.cinnamon)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transcriptList: some View {
        // 行ごとに model.liveSessionStartDate(内部で sessions.first(where:) の線形探索を
        // 伴う)を呼び直さないよう、行の描画に入る前に 1 回だけ取得して segmentLine へ渡す。
        let startDate = model.liveSessionStartDate
        return ScrollViewReader { proxy in
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
                            text: row.text, volatile: row.volatile,
                            isRevealed: row.id == revealCoordinator.revealedID,
                            startDate: startDate)
                            .id(row.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 開いた瞬間から最新の発話が見えるよう、初期位置は最下部にする。
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.liveTimeline.rows) {
                proxy.scrollTo("bottom")
            }
            // ライブ画面は選択が切り替わるたびに作り直される(履歴側の SessionDetailView と違い
            // インスタンスを使い回さない)ため、初回表示の時点で既にジャンプ要求が
            // 積まれている場合(履歴が閉じている状態からのジャンプ)は onAppear で拾える。
            .onAppear { revealIfRequested(proxy: proxy) }
            // 既にライブ画面を表示中に続けてジャンプされた場合。
            .onChange(of: model.transcriptRevealRequest) { revealIfRequested(proxy: proxy) }
        }
    }

    /// 質問応答パネルの「根拠と補足」からのジャンプ要求を消費する。ライブ対象
    /// (sessionID == MainWindow.liveID)宛てでなければ何もしない(過去セッション側の
    /// SessionDetailView に委ねる)。
    private func revealIfRequested(proxy: ScrollViewProxy) {
        guard let request = model.transcriptRevealRequest, request.sessionID == MainWindow.liveID
        else { return }
        model.transcriptRevealRequest = nil

        // 認識中(volatile)の行は確定した時刻を持たず、比較の対象にならない。rows の並びは
        // 「席が固定」の都合で必ずしも時刻順ではないため、比較の前に time で安定ソートしておく
        // (SessionDetailView の stamp ソートと同じ理由: 選択が並び順に左右されないようにする)。
        let finalized = model.liveTimeline.rows.filter { !$0.volatile }.sorted { $0.time < $1.time }
        guard
            let target = finalized.first(where: {
                TranscriptWriter.timeString(from: $0.time) >= request.time
            }) ?? finalized.last
        else { return }

        revealCoordinator.reveal(target.id, proxy: proxy)
    }

    private func segmentLine(
        time: Date?, speaker: String, text: String, volatile: Bool, isRevealed: Bool,
        startDate: Date?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // 表示は経過時間(分:秒)に統一する(履歴詳細・質問応答パネルの根拠チップと同じ物差し)。
            // 以前はここも壁時計(HH:mm:ss)を出していたが、履歴詳細だけ経過時間のままだったため
            // 面によって単位が食い違い、「ジャンプ先がズレて見える」混乱を招いた。
            Text(elapsedLabel(for: time, startDate: startDate))
                .font(HCFont.timecode)
                .foregroundStyle(.white.opacity(0.34))
                // 幅 66 は元々 "[HH:mm:ss]"(10 文字)を収める値だった。経過時間の最長想定
                // "999:59" 程度(6 文字、"認識中" と同程度)はそれより短いため、そのまま流用できる。
                .frame(width: 66, alignment: time == nil ? .center : .leading)
            SpeakerChip(speaker: speaker)
            if volatile {
                StreamingText(target: text)
                    .foregroundStyle(.white.opacity(0.5))
                    .font(HCFont.body)
            } else {
                Text(text)
                    .foregroundStyle(.white.opacity(0.88))
                    .font(HCFont.body)
                    .textSelection(.enabled)
            }
        }
        // 質問応答パネルからのジャンプ先を、一時的な背景色でフェードイン→フェードアウトさせる
        // (SessionDetailView と共有する RevealHighlight。RevealCoordinator.swift のコメント
        // どおり、opacity は SessionDetailView 側の 0.22 に統一済み)。
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .modifier(RevealHighlight(isRevealed: isRevealed))
    }

    /// 行頭に出す経過時間のラベル。time が nil(認識中の行)ならそのまま「認識中」。
    /// formatPlaybackTime は SessionDetailView.swift 側の共有関数(同じ書式にするため)。
    /// startDate は呼び出し元(transcriptList)が model.liveSessionStartDate を行の描画前に
    /// 1 回だけ取得して渡す(内部で sessions.first(where:) の線形探索を伴うため)。
    /// 開始時刻が引けない(セッション開始直後の一瞬、sessions のキャッシュがまだ追いついて
    /// いない場合など)は、壁時計へフォールバックせず "--:--" にする
    /// (単位が面によって混在すると、今回の「ズレて見える」不具合と同種の混乱を再発するため)。
    private func elapsedLabel(for time: Date?, startDate: Date?) -> String {
        guard let time else { return "認識中" }
        guard let startDate else { return "--:--" }
        let elapsed = max(0, time.timeIntervalSince(startDate))
        return formatPlaybackTime(elapsed)
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
                NSColor(HCColor.cinnamon).setFill()
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
