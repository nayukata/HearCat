import HearCatKit
import SwiftUI

/// 質問応答パネルの ```deadlines フェンス(期限の暦)の描画。横一本の線の上に、会議の日
/// (と、過去の会議なら今日)を起点として、期限・予定を日付の位置に印で示す。
///
/// 回数・合計時間を測る TopicWeights と違い、こちらは日付の並びそのものが見せ場のため、
/// 横軸(DeadlineAxis)・ラベルの上下交互配置(DeadlineCalendarLayout)は HearCatKit 側の
/// 純粋関数に切り出し、この View は「どこに何を描くか」の組み立てだけを持つ。
struct DeadlineCalendarView: View {
    let calendar: DeadlineCalendar
    /// 対象セッションの開始日時。横軸の起点(会議の日)と、項目をタップした際に
    /// revealTranscript へ渡す壁時計文字列への変換(item.at を足し戻す)の両方に使う。
    let sessionStartDate: Date
    let model: AppModel

    private static let canvasHeight: CGFloat = 130
    private static let horizontalPadding: CGFloat = 40
    private static let diamondSize: CGFloat = 16
    private static let circleDiameter: CGFloat = 10
    /// 印から名前・日付までの基本距離。stackIndex 分だけこれの倍数(stackStep)を足す。
    private static let labelGap: CGFloat = 20
    private static let stackStep: CGFloat = 14
    /// 端揃え(leading/trailing)のラベルに与える固定幅。実測はせず、この用途のラベル
    /// (14文字以内の名詞句 + 「自分」「相手」の2行、または M/d の日付)が確実に収まる
    /// 余裕のある値を使う。位置(anchoredPosition 参照)は、この幅のフレームに
    /// alignment を効かせて、フレームの中心ではなく端を基準点に固定する形で決める。
    /// DeadlineCalendarLayout.labelAnchor へ渡す halfLabelWidth はこの半分。
    private static let anchoredLabelWidth: CGFloat = 180

    private var axis: DeadlineAxis {
        DeadlineAxis(sessionDay: sessionStartDate, today: Date(), items: calendar.items)
    }

    private var placements: [DeadlineCalendarLayout.Placement] {
        DeadlineCalendarLayout.placements(for: calendar.items)
    }

    private var sessionDay: Date { Calendar.current.startOfDay(for: sessionStartDate) }
    private var today: Date { Calendar.current.startOfDay(for: Date()) }
    private var isMeetingToday: Bool { sessionDay == today }
    private var isPastMeeting: Bool { sessionDay < today }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(calendar.title ?? "期限の早い順")
                .font(HCFont.callout)
                .foregroundStyle(HCColor.textDim)
            GeometryReader { geo in
                let lineY = Self.canvasHeight / 2
                ZStack(alignment: .topLeading) {
                    axisLine(width: geo.size.width, lineY: lineY)
                    startMarker(width: geo.size.width, lineY: lineY)
                    if isPastMeeting {
                        todayMarker(width: geo.size.width, lineY: lineY)
                    }
                    ForEach(Array(zip(calendar.items, placements).enumerated()), id: \.offset) { _, pair in
                        itemMarker(item: pair.0, placement: pair.1, width: geo.size.width, lineY: lineY)
                    }
                }
                .frame(width: geo.size.width, height: Self.canvasHeight)
            }
            .frame(height: Self.canvasHeight)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HCRadius.shape(HCRadius.card).fill(HCColor.surface))
    }

    // MARK: - 横軸

    /// date の実際の描画座標(absoluteX)と、そこに置くラベルの水平アンカーの両方を返す。
    /// アンカー判定(DeadlineCalendarLayout.labelAnchor)は、左右の余白(horizontalPadding)を
    /// 除いた横軸の実効幅の中での位置(0...usable)を基準にする。左右の余白そのものは
    /// 印がそこまでしか動かない不可侵領域であり、「端に近いかどうか」は実際に印が動く
    /// 範囲を基準に判定するのが自然なため。
    private func axisPosition(for date: Date, width: CGFloat) -> (absoluteX: CGFloat, anchor: DeadlineCalendarLayout.Anchor) {
        let usable = max(width - Self.horizontalPadding * 2, 0)
        let rawX = CGFloat(axis.fraction(of: date)) * usable
        let anchor = DeadlineCalendarLayout.labelAnchor(
            x: Double(rawX), width: Double(usable), halfLabelWidth: Double(Self.anchoredLabelWidth / 2))
        return (Self.horizontalPadding + rawX, anchor)
    }

    private func axisLine(width: CGFloat, lineY: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: Self.horizontalPadding, y: lineY))
            path.addLine(to: CGPoint(x: width - Self.horizontalPadding, y: lineY))
        }
        .stroke(HCColor.textBody.opacity(0.35), lineWidth: 1)
    }

    /// 中央揃えのまま `.position(x:y:)` で置くと、絵の端(左右の余白 40pt)に近いラベルが
    /// 絵の外へはみ出す(実機で確認)。DeadlineCalendarLayout.labelAnchor が返す anchor に
    /// 応じて、x をラベルの中心ではなく外側の辺として使う。実測はせず、十分に余裕のある
    /// 固定幅(anchoredLabelWidth)のフレームへ alignment を効かせることで実現する
    /// (この用途のラベルは短い1〜2行の文字列のみなので、実測コストを払う必要はない)。
    private func anchoredPosition<V: View>(
        _ content: V, x: CGFloat, y: CGFloat, anchor: DeadlineCalendarLayout.Anchor
    ) -> some View {
        let alignment: Alignment
        let centerX: CGFloat
        switch anchor {
        case .leading:
            alignment = .leading
            centerX = x + Self.anchoredLabelWidth / 2
        case .center:
            alignment = .center
            centerX = x
        case .trailing:
            alignment = .trailing
            centerX = x - Self.anchoredLabelWidth / 2
        }
        return content
            .frame(width: Self.anchoredLabelWidth, alignment: alignment)
            .position(x: centerX, y: y)
    }

    // MARK: - 始点(会議の日)・今日の点

    private func startMarker(width: CGFloat, lineY: CGFloat) -> some View {
        let (x, anchor) = axisPosition(for: sessionDay, width: width)
        let label = HCDate.axis.string(from: sessionDay) + (isMeetingToday ? " 今日" : "")
        return dayMarker(x: x, lineY: lineY, label: label, anchor: anchor)
    }

    /// 会議の日が今日より前(過去の会議)のときだけ、今日の位置に別の点を置く。
    /// 過ぎた期限は自然に今日より左に来るため、色は変えず同じ見た目にする。
    private func todayMarker(width: CGFloat, lineY: CGFloat) -> some View {
        let (x, anchor) = axisPosition(for: today, width: width)
        return dayMarker(x: x, lineY: lineY, label: "今日", anchor: anchor)
    }

    private func dayMarker(
        x: CGFloat, lineY: CGFloat, label: String, anchor: DeadlineCalendarLayout.Anchor
    ) -> some View {
        ZStack {
            Circle()
                .fill(HCColor.textBody)
                .frame(width: Self.circleDiameter, height: Self.circleDiameter)
                .position(x: x, y: lineY)
            anchoredPosition(
                Text(label)
                    .font(HCFont.monospacedDigit(.subheadline))
                    .foregroundStyle(HCColor.textDim)
                    .fixedSize(),
                x: x, y: lineY + Self.labelGap, anchor: anchor)
        }
    }

    // MARK: - 各項目

    /// 期限(due)はひし形、予定(event)は白抜きの丸。担当者による色分けはひし形のみに効く
    /// (白抜きの丸は誰の予定かに関わらず同じ見た目にする)。名前の色は担当者に関わらず、
    /// 項目の種類を問わず適用する。
    /// マーカーと名前は個別にタップできる必要がある(印か名前を押すと revealTranscript)。
    /// `.position(x:y:)` を使う子は親いっぱいに広がる(SwiftUI の既知の挙動)ため、
    /// `.contentShape`/`.onTapGesture`/`.pointingHandOnHover()` を外側の ZStack にまとめて
    /// 付けると、複数の項目が重なった ZStack 全体の最前面(最後の項目)だけがタップを
    /// 受け取ってしまう(実機で確認: どこを押しても最後の項目にしか飛ばなかった)。
    /// これを避けるため、各要素が `.position()` で広がる前(まだ自分の自然な大きさの段階)で
    /// contentShape・タップ・ホバーを付け、ZStack 自体には付けない。
    /// 期限が会議の日(または過去の会議なら今日)と同じ日の項目は、その項目自身の日付
    /// ラベルを出さない。始点(または今日)の点が既にその日付を示しており、同じ位置に
    /// もう1つ日付が重なって描かれてしまうため。印がその点に重なるのはそのままでよい
    /// (位置が一致していることがむしろ伝わる)。
    private func suppressesOwnDateLabel(for item: DeadlineItem) -> Bool {
        item.due == sessionDay || (isPastMeeting && item.due == today)
    }

    private func itemMarker(
        item: DeadlineItem, placement: DeadlineCalendarLayout.Placement, width: CGFloat, lineY: CGFloat
    ) -> some View {
        let (x, anchor) = axisPosition(for: item.due, width: width)
        let stackOffset = CGFloat(placement.stackIndex) * Self.stackStep
        let isMe = item.owner == .me
        let nameColor: Color = isMe ? HCColor.accentText : HCColor.textPrimary
        // above(上)なら名前は線より上、日付は反対側(下)。below(下)ならその逆。
        let sign: CGFloat = placement.side == .above ? -1 : 1
        let nameY = lineY + sign * (Self.labelGap + stackOffset)
        let dateY = lineY - sign * (Self.labelGap + stackOffset)
        let wallClock = wallClockString(for: item)
        let jump = { model.revealTranscript(atTime: wallClock) }

        return ZStack {
            marker(for: item)
                .contentShape(Rectangle())
                .onTapGesture(perform: jump)
                .pointingHandOnHover()
                .position(x: x, y: lineY)

            anchoredPosition(
                VStack(spacing: 2) {
                    if placement.side == .above, let owner = item.owner {
                        whoLabel(owner)
                    }
                    Text(item.label)
                        .font(HCFont.style(.callout, weight: .semibold))
                        .foregroundStyle(nameColor)
                        .lineLimit(1)
                    if placement.side == .below, let owner = item.owner {
                        whoLabel(owner)
                    }
                }
                .fixedSize()
                .contentShape(Rectangle())
                .onTapGesture(perform: jump)
                .pointingHandOnHover(),
                x: x, y: nameY, anchor: anchor)

            if !suppressesOwnDateLabel(for: item) {
                anchoredPosition(
                    Text(HCDate.axis.string(from: item.due))
                        .font(HCFont.monospacedDigit(.subheadline))
                        .foregroundStyle(HCColor.textDim)
                        .fixedSize(),
                    x: x, y: dateY, anchor: anchor)
            }
        }
    }

    @ViewBuilder
    private func marker(for item: DeadlineItem) -> some View {
        switch item.kind {
        case .due:
            let isMe = item.owner == .me
            Rectangle()
                .fill(isMe ? HCColor.accent : HCColor.textBody.opacity(0.55))
                .frame(width: Self.diamondSize, height: Self.diamondSize)
                .rotationEffect(.degrees(45))
        case .event:
            // 白抜き(=地の色をそのまま見せる)は、パネルの背景(panel)ではなく
            // このカード自身の地(surface)に合わせる。パネル背景色で塗ると、
            // カードの面の上では周りと違う色の板が浮いて見える。
            Circle()
                .fill(HCColor.surface)
                .overlay(Circle().stroke(HCColor.textBody.opacity(0.55), lineWidth: 1.5))
                .frame(width: Self.circleDiameter, height: Self.circleDiameter)
        }
    }

    private func whoLabel(_ owner: DeadlineOwner) -> some View {
        Text(owner == .me ? "自分" : "相手")
            .font(HCFont.style(.subheadline))
            .foregroundStyle(HCColor.textDim)
    }

    /// item.at(セッション開始からの経過秒)を、文字起こしの時刻表記(TranscriptWriter が
    /// 書く書式)に戻して revealTranscript(atTime:) へ渡す。
    private func wallClockString(for item: DeadlineItem) -> String {
        TranscriptWriter.timeString(from: sessionStartDate.addingTimeInterval(item.at))
    }
}
