import HearCatKit
import SwiftUI

/// 決定の変遷(history)を、新しい順に並べた肉球の足あとで描くタイムライン本体。
/// GroupDetailView の議題展開(TopicRow.historySection)と、質問応答パネルの経緯回答カード
/// (DecisionHistoryCardsView)の両方から使う共有部品。
///
/// 開いた瞬間に現在地が分かることを優先し、history(recordedAt 昇順)を反転して最新を
/// 先頭(index 0)に置く。足あと・破線レール・強調(最新=cinnamon+光彩+「いまここ」ラベル、
/// 過去=cinnamonDim)の描き方は共通だが、本文の文字色は呼び出し元ごとに違う:
/// GroupDetailView はシステム配色に追従する Color.primary/.secondary、質問応答パネルは
/// 常時ダーク面の HCColor.mistWhite 系(CodeImpactOverlay.swift の他の要素と同じ理由で、
/// パネルは colorScheme を問わず常にダーク面として描く)。そのため文字色は呼び出し元から渡す。
/// メタ行(セッション名・日付・時刻チップ等)の内容も呼び出し元ごとに違う(一覧は縦を揃える
/// MM/dd、パネルは「7月27日」+ 理由の引用風ブロック)ため、@ViewBuilder で委ねる。
struct DecisionTimelineView<Meta: View>: View {
    let history: [DecisionEntry]
    let currentTextColor: Color
    let pastTextColor: Color
    @ViewBuilder let meta: (DecisionEntry) -> Meta

    var body: some View {
        let reversed = Array(history.reversed())
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(reversed.enumerated()), id: \.offset) { index, entry in
                row(entry, isCurrent: index == 0, isLast: index == reversed.count - 1)
            }
        }
    }

    private func row(_ entry: DecisionEntry, isCurrent: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            pawPrint(isCurrent: isCurrent, isLast: isLast, isManual: entry.isManual)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.text)
                        .font(HCFont.callout)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent ? currentTextColor : pastTextColor)
                    if isCurrent {
                        Text("いまここ")
                            .font(HCFont.style(.caption1, weight: .bold))
                            .kerning(0.5)
                            .foregroundStyle(HCColor.cinnamon)
                    }
                }
                meta(entry)
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
    }

    /// `isManual`(`entry.origin == .manual`、会話の外での手動記録)の足あとは塗りつぶさず
    /// 輪郭線だけで描く。「塗り = 会話から抽出、輪郭線だけ = 会話の外」を色を増やさずに
    /// 描き分けるための表現(色は現在地/過去の区別と同じものをそのまま使う)。
    private func pawPrint(isCurrent: Bool, isLast: Bool, isManual: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
                if isManual {
                    PawPrintShape()
                        .stroke(
                            isCurrent ? HCColor.cinnamon : HCColor.cinnamonDim,
                            lineWidth: 1.2)
                } else {
                    PawPrintShape()
                        .fill(isCurrent ? HCColor.cinnamon : HCColor.cinnamonDim)
                }
            }
            .frame(width: 13, height: 13)
            .shadow(color: isCurrent ? HCColor.cinnamon.opacity(0.6) : .clear, radius: 3)
            if !isLast {
                VerticalDashedRailShape()
                    .stroke(
                        HCColor.cinnamon.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 4])
                    )
                    .frame(width: 13)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 13)
        .padding(.top, 4)
    }
}

/// 足あとの間を繋ぐ破線レール。マーカー列の中央(x = rect.midX)に、割り当てられた高さいっぱいの
/// 縦線を引く。実線ではなく破線にして、足あとが霧の中に点々と続く印象を出す。
struct VerticalDashedRailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// 肉球マーク。単位矩形(0〜1)に対して、下半分の楕円パッドと上の指3つの円を描く。
/// 足あとが霧の中に点々と続く印象をレールの破線と合わせて出すための形なので、
/// 指の位置・パッドの大きさは仕様上の固定値であり、サイズによって配置を変えない。
struct PawPrintShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: ellipseRect(center: CGPoint(x: 0.5, y: 0.69), rx: 0.29, ry: 0.24, in: rect))
        for center in [
            CGPoint(x: 0.21, y: 0.33), CGPoint(x: 0.5, y: 0.23), CGPoint(x: 0.79, y: 0.33),
        ] {
            path.addEllipse(in: ellipseRect(center: center, rx: 0.12, ry: 0.12, in: rect))
        }
        return path
    }

    private func ellipseRect(center: CGPoint, rx: CGFloat, ry: CGFloat, in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + (center.x - rx) * rect.width,
            y: rect.minY + (center.y - ry) * rect.height,
            width: rx * 2 * rect.width,
            height: ry * 2 * rect.height
        )
    }
}

/// 質問応答パネルの経緯回答が描く、議題ごとのタイムラインカード群。
/// ```decision-history フェンス(DecisionHistoryFence)から受け取った topicIds を、
/// 対象セッションが属するグループの decisions.json と突き合わせて描く。AI の文章に頼らず
/// 記録をそのまま描画することで、日付の生表記・理由の捏造・死にリンクを防ぐ(経緯)。
///
/// 対象セッションがグループに属さない・decisions.json が読めない・topicId が記録に無い場合は
/// 静かにスキップする(見せられる分だけ見せる。エラー表示は主旨に対して重すぎる)。
/// アーカイブ済み議題の id が来た場合も、記録自体はあるのでそのまま描く。
struct DecisionHistoryCardsView: View {
    let topicIds: [String]
    let model: AppModel

    /// decisions.json の読み込み結果。ストリーミング中は body が高頻度(約 120ms ごと)に
    /// 再評価されるため、読み込みそのものは .task(id:) 側でだけ行い、body では参照するだけにする。
    @State private var log: DecisionLog?

    /// .task(id:) の再読み込みトリガー。議題一覧か、質問パネルの対象セッションが属する
    /// グループが変わったときだけ読み直す。
    private struct LoadKey: Equatable {
        let topicIds: [String]
        let folder: String?
    }

    var body: some View {
        // model.codeImpactTargetSessionFolder は body 評価ごとに1回だけ読む
        // (以前は if 節と .task の両方で読んでいて二重に呼んでいた)。
        let folder = model.codeImpactTargetSessionFolder
        VStack(alignment: .leading, spacing: 0) {
            // 読み込み前(log == nil)は下の条件分岐が何も描かず、全体が EmptyView に
            // 畳まれると .task が発火しない(MenuPanel のブリーフカードでも起きた
            // 「初期状態が空 → task 不発 → 永久に空」の自己ロック)。それを避けるため、
            // 大きさ0の実体を常に1つ置いて task の足場にする。
            Color.clear.frame(width: 0, height: 0)
            if let folder, let log {
                let topics = topicIds.compactMap { id in log.topics.first(where: { $0.id == id }) }
                if !topics.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(topics, id: \.id) { topic in
                            DecisionHistoryCard(
                                topic: topic,
                                onJump: { entry in model.revealDecisionEntry(entry, folder: folder) })
                        }
                    }
                }
            }
        }
        .task(id: LoadKey(topicIds: topicIds, folder: folder)) {
            log = folder.map(DecisionLogStore.loadOrEmpty(folder:))
        }
    }
}

/// 経緯回答カード1件(議題1件ぶん)。見出し(議題名+現在の状態チップ)+ タイムライン。
private struct DecisionHistoryCard: View {
    let topic: DecisionTopic
    let onJump: (DecisionEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(topic.title)
                    .font(HCFont.style(.callout, weight: .semibold))
                    .foregroundStyle(HCColor.mistWhite)
                if let status = topic.current?.status {
                    DecisionStatusChip(status: status)
                }
                Spacer(minLength: 0)
            }
            DecisionTimelineView(
                history: topic.history,
                currentTextColor: HCColor.mistWhite, pastTextColor: HCColor.mistWhiteDim
            ) { entry in
                meta(entry)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HCRadius.shape(HCRadius.control).fill(HCColor.mistDarkSurface))
    }

    /// 内容の下に添える部分: 理由(あれば)の引用ブロック + メタ行(entry.sourceLabel・日付・
    /// 時刻チップ)。「言い出し」は表示しない(記録データの by 自体は残すが、画面には出さない判断)。
    /// 手動記録は reason が「どこで決まったか」であって変更理由ではないため、引用ブロックには出さず
    /// entry.sourceLabel 側に委ねる(理由の二重表示を避ける)。
    private func meta(_ entry: DecisionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.isManual, let reason = entry.reason, !reason.isEmpty {
                reasonBlock(reason)
            }
            metaRow(entry)
        }
    }

    /// 理由を引用風に見せるブロック。左の縦線1本で「本文に対する注釈」だと伝える。
    private func reasonBlock(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(HCColor.cinnamonDim)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("理由")
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.mistWhiteDim)
                // 理由は本文と同じ大きさで読ませる(小さくするのはラベルとメタ行だけ)。
                Text(reason)
                    .font(HCFont.callout)
                    .foregroundStyle(HCColor.mistWhiteBright)
            }
            .padding(.leading, 8)
        }
    }

    /// entry.sourceLabel・日付・時刻チップ(あれば)を並べる行。ラベル文言の規則は
    /// entry.sourceLabel(DecisionTimelineView.swift 末尾の拡張)側を参照。
    private func metaRow(_ entry: DecisionEntry) -> some View {
        HStack(spacing: 4) {
            Text(entry.sourceLabel)
            Text(HCDate.body.string(from: entry.recordedAt))
            if let timeSeconds = entry.timeSeconds {
                Button(formatPlaybackTime(TimeInterval(timeSeconds))) { onJump(entry) }
                    .buttonStyle(.plain)
                    .font(HCFont.timecode)
                    .foregroundStyle(HCColor.cinnamon)
                    .pointingHandOnHover()
                    .help("この位置から文字起こしへ移動")
            }
        }
        .font(HCFont.caption)
        .foregroundStyle(HCColor.mistWhiteDim)
    }
}

extension DecisionEntry {
    /// メタ行に出す「どこから来た記録か」。会話由来はセッション名(空文字なら
    /// SessionRow.untitledPlaceholder)、手動記録は「手動で記録」(過去データで
    /// reason が残っていればその文言をそのまま出す)。SessionRow(View 準拠で
    /// MainActor 分離)の文言を参照するため、この計算プロパティ自体も @MainActor にする。
    @MainActor
    var sourceLabel: String {
        if isManual {
            guard let reason, !reason.isEmpty else { return "手動で記録" }
            return reason
        }
        return sessionName.isEmpty ? SessionRow.untitledPlaceholder : sessionName
    }
}
