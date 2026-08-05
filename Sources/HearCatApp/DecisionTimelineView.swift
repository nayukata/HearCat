import HearCatKit
import SwiftUI

/// 決定の変遷(history)を縦のレール+点で描くタイムライン本体。GroupDetailView の議題展開
/// (TopicRow.historySection)と、質問応答パネルの経緯回答カード(DecisionHistoryCardsView)の
/// 両方から使う共有部品。
///
/// 点・レール・強調(最新=cinnamon+光彩+太字、過去=薄色)の描き方は共通だが、色調は
/// 呼び出し元ごとに違う: GroupDetailView はシステム配色に追従する Color.primary/.secondary、
/// 質問応答パネルは常時ダーク面の HCColor.mistWhite 系(CodeImpactOverlay.swift の他の要素と
/// 同じ理由で、パネルは colorScheme を問わず常にダーク面として描く)。そのため色は呼び出し元
/// から渡す。メタ行(セッション名・日付・時刻チップ等)の内容も呼び出し元ごとに違う
/// (一覧は縦を揃える MM/dd、パネルは「7月27日」+ 理由の引用風ブロック)ため、@ViewBuilder で委ねる。
struct DecisionTimelineView<Meta: View>: View {
    let history: [DecisionEntry]
    let currentTextColor: Color
    let pastTextColor: Color
    /// 点(過去版)とレールの塗りに使う地色。過去版の点は0.22、レールは0.14の不透明度で
    /// 使う(GroupDetailView の元の値を維持)。
    let mutedColor: Color
    @ViewBuilder let meta: (DecisionEntry) -> Meta

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(history.enumerated()), id: \.offset) { index, entry in
                row(entry, isCurrent: index == history.count - 1, isLast: index == history.count - 1)
            }
        }
    }

    private func row(_ entry: DecisionEntry, isCurrent: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            dot(isCurrent: isCurrent, isLast: isLast)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(HCFont.callout)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? currentTextColor : pastTextColor)
                meta(entry)
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
    }

    private func dot(isCurrent: Bool, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(isCurrent ? HCColor.cinnamon : mutedColor.opacity(0.22))
                .frame(width: 8, height: 8)
                .shadow(color: isCurrent ? HCColor.cinnamon.opacity(0.6) : .clear, radius: 3)
            if !isLast {
                Rectangle()
                    .fill(mutedColor.opacity(0.14))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 8)
        .padding(.top, 4)
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

    /// パネルの本文に馴染む「7月27日」形式。GroupDetailView の一覧(MM/dd、縦揃え優先)とは
    /// 用途が違うため、ここだけ別のフォーマッタを持つ。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()

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
        Group {
            if let folder, let log {
                let topics = topicIds.compactMap { id in log.topics.first(where: { $0.id == id }) }
                if !topics.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(topics, id: \.id) { topic in
                            DecisionHistoryCard(
                                topic: topic, dateFormatter: Self.dateFormatter,
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
    let dateFormatter: DateFormatter
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
                currentTextColor: HCColor.mistWhite, pastTextColor: HCColor.mistWhiteDim,
                mutedColor: HCColor.mistWhite
            ) { entry in
                meta(entry)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HCRadius.shape(HCRadius.control).fill(HCColor.mistDarkSurface))
    }

    /// 内容の下に添える部分: 理由(あれば)の引用ブロック + セッション名・日付・時刻チップのメタ行。
    /// 「言い出し」は表示しない(記録データの by 自体は残すが、画面には出さない判断)。
    private func meta(_ entry: DecisionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = entry.reason, !reason.isEmpty {
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

    /// セッション名・日付・時刻チップ(あれば)を並べる行。
    private func metaRow(_ entry: DecisionEntry) -> some View {
        HStack(spacing: 4) {
            Text(entry.sessionName.isEmpty ? SessionRow.untitledPlaceholder : entry.sessionName)
            Text(dateFormatter.string(from: entry.recordedAt))
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
