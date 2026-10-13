import HearCatKit
import SwiftUI

/// 質問応答パネルの ```promises フェンス(約束の追跡)の描画。1行1約束で、左に約束の名前、
/// 右に全行共通の日付軸を置き、約束した会議の日から済んだ会議の日まで1本の線を引く。
/// 済んだものは端に ✓ を付けて無彩色に落とし、未完了は約束の日から今日まで伸びる
/// アクセント色の矢印にして目立たせる(話者色は状態の意味に使わない)。
///
/// 日付の位置合わせ(PromiseAxis)は HearCatKit 側の純粋関数。この View は「どこに何を描くか」
/// だけを持つ。
struct PromiseTrackerView: View {
    let tracker: PromiseTracker
    let model: AppModel

    private static let labelColumnWidth: CGFloat = 132
    private static let columnSpacing: CGFloat = 12
    /// 名前が2行 + 担当の1行に収まる高さ。行の高さを全行で揃え、先頭を縦に揃える。
    private static let rowHeight: CGFloat = 58
    private static let headerHeight: CGFloat = 18
    /// 線の両端の印(丸・✓・矢じり)が軸の外へはみ出さないための左右の余白。
    private static let lanePadding: CGFloat = 16
    private static let dotDiameter: CGFloat = 9
    private static let lineThickness: CGFloat = 2
    private static let arrowHeadLength: CGFloat = 9
    private static let minimumArrowLength: CGFloat = 16
    private static let tapTarget: CGFloat = 22
    /// 日付ラベルの固定幅。半分を DeadlineCalendarLayout.labelAnchor の halfLabelWidth に使い、
    /// 端に近いラベルは中心ではなく外側の辺を印の位置に合わせる(絵の外へはみ出さない)。
    private static let tickLabelWidth: CGFloat = 56
    /// これより近い日付ラベルは重なるため間引く。
    private static let tickMinimumGap: CGFloat = 44

    private var axis: PromiseAxis { PromiseAxis(items: tracker.items, today: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tracker.title ?? "約束の進み具合")
                .font(HCFont.callout)
                .foregroundStyle(HCColor.textDim)
            axisHeader
            ForEach(Array(tracker.items.enumerated()), id: \.offset) { _, item in
                row(item)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HCRadius.shape(HCRadius.card).fill(HCColor.surface))
    }

    // MARK: - 日付軸

    /// 横軸の位置(レーンの左右余白を除いた 0...usable)。
    private func rawX(for date: Date, usable: CGFloat) -> CGFloat {
        CGFloat(axis.fraction(of: date)) * usable
    }

    private struct Tick {
        let day: Date
        let text: String
    }

    private var ticks: [Tick] {
        let calendar = Calendar.current
        var days = Set<Date>()
        for item in tracker.items {
            days.insert(calendar.startOfDay(for: item.made.meeting.start))
            if let done = item.done { days.insert(calendar.startOfDay(for: done.meeting.start)) }
        }
        let today = axis.today
        if let today { days.insert(today) }
        return days.sorted().map { day in
            Tick(day: day, text: day == today ? "今日" : HCDate.axis.string(from: day))
        }
    }

    private var axisHeader: some View {
        HStack(alignment: .top, spacing: Self.columnSpacing) {
            Color.clear.frame(width: Self.labelColumnWidth, height: Self.headerHeight)
            GeometryReader { geo in
                let usable = max(geo.size.width - Self.lanePadding * 2, 0)
                ZStack(alignment: .topLeading) {
                    ForEach(visibleTicks(usable: usable), id: \.day) { tick in
                        tickLabel(tick, usable: usable)
                    }
                }
                .frame(width: geo.size.width, height: Self.headerHeight)
            }
            .frame(height: Self.headerHeight)
        }
    }

    /// 左から詰めて、前に残したラベルと近すぎるものを落とす。右端のラベル(最後の日・今日)は
    /// 必ず残す: 軸がどこまで続くかを示すため、直前に残したラベルのほうを落として譲る。
    private func visibleTicks(usable: CGFloat) -> [Tick] {
        var kept: [(tick: Tick, x: CGFloat)] = []
        let all = ticks
        for (index, tick) in all.enumerated() {
            let x = rawX(for: tick.day, usable: usable)
            let isLast = index == all.count - 1
            if let previous = kept.last, x - previous.x < Self.tickMinimumGap {
                if isLast { kept.removeLast() } else { continue }
            }
            kept.append((tick, x))
        }
        return kept.map(\.tick)
    }

    private func tickLabel(_ tick: Tick, usable: CGFloat) -> some View {
        let x = rawX(for: tick.day, usable: usable)
        let anchor = DeadlineCalendarLayout.labelAnchor(
            x: Double(x), width: Double(usable), halfLabelWidth: Double(Self.tickLabelWidth / 2))
        let absoluteX = Self.lanePadding + x
        let horizontal: HorizontalAlignment
        let centerX: CGFloat
        switch anchor {
        case .leading:
            horizontal = .leading
            centerX = absoluteX + Self.tickLabelWidth / 2
        case .center:
            horizontal = .center
            centerX = absoluteX
        case .trailing:
            horizontal = .trailing
            centerX = absoluteX - Self.tickLabelWidth / 2
        }
        return Text(tick.text)
            .font(HCFont.monospacedDigit(.subheadline))
            .foregroundStyle(HCColor.textDim)
            .fixedSize()
            .frame(
                width: Self.tickLabelWidth, height: Self.headerHeight,
                alignment: Alignment(horizontal: horizontal, vertical: .top)
            )
            .position(x: centerX, y: Self.headerHeight / 2)
    }

    // MARK: - 1行

    private func row(_ item: PromiseItem) -> some View {
        let isPending = item.done == nil
        let jumpToMade = { model.revealTranscript(meeting: item.made.meeting, atTime: item.made.time) }
        return HStack(alignment: .center, spacing: Self.columnSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(HCFont.style(.callout, weight: .semibold))
                    .foregroundStyle(isPending ? HCColor.textPrimary : HCColor.textDim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let owner = item.owner {
                    Text(owner == .me ? "自分" : "相手")
                        .font(HCFont.style(.subheadline))
                        .foregroundStyle(HCColor.textDim)
                }
            }
            .frame(width: Self.labelColumnWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: jumpToMade)
            .pointingHandOnHover()

            GeometryReader { geo in
                lane(item, width: geo.size.width, jumpToMade: jumpToMade)
            }
        }
        .frame(height: Self.rowHeight)
    }

    /// 印・線・✓ は、それぞれが `.position(x:y:)` で広がる前(自然な大きさの段階)でタップを
    /// 付ける。ZStack 全体に付けると最前面の要素しか反応しない(DeadlineCalendarView 参照)。
    private func lane(_ item: PromiseItem, width: CGFloat, jumpToMade: @escaping () -> Void) -> some View {
        let usable = max(width - Self.lanePadding * 2, 0)
        let centerY = Self.rowHeight / 2
        let madeX = Self.lanePadding + rawX(for: item.made.meeting.start, usable: usable)
        let isPending = item.done == nil

        let endX: CGFloat
        if let done = item.done {
            // 約束と完了が同じ日だと線の長さが0になり、✓ が丸に重なって片方しか押せない。
            // タップ領域1つ分だけ右へずらして両方を押せるようにする。
            endX = max(
                Self.lanePadding + rawX(for: done.meeting.start, usable: usable),
                madeX + Self.tapTarget)
        } else {
            let todayX = axis.today.map { Self.lanePadding + rawX(for: $0, usable: usable) } ?? madeX
            // 約束が今日の会議でも矢印が見えるよう、最低限の長さを確保する。
            endX = max(todayX, madeX + Self.minimumArrowLength)
        }
        let length = max(endX - madeX, 0)
        let lineColor = isPending ? HCColor.accent : HCColor.textBody.opacity(0.3)
        let dotColor = isPending ? HCColor.accent : HCColor.textBody.opacity(0.45)

        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(lineColor)
                    .frame(width: max(length - (isPending ? Self.arrowHeadLength : 0), 0), height: Self.lineThickness)
                if isPending {
                    PromiseArrowHead()
                        .fill(lineColor)
                        .frame(width: Self.arrowHeadLength, height: Self.arrowHeadLength + 2)
                }
            }
            .frame(width: length, height: Self.tapTarget)
            .contentShape(Rectangle())
            .onTapGesture(perform: jumpToMade)
            .pointingHandOnHover()
            .position(x: madeX + length / 2, y: centerY)

            Circle()
                .fill(dotColor)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                .frame(width: Self.tapTarget, height: Self.tapTarget)
                .contentShape(Rectangle())
                .onTapGesture(perform: jumpToMade)
                .pointingHandOnHover()
                .position(x: madeX, y: centerY)

            if let done = item.done {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HCColor.textDim)
                    .frame(width: Self.tapTarget, height: Self.tapTarget)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.revealTranscript(meeting: done.meeting, atTime: done.time)
                    }
                    .pointingHandOnHover()
                    .position(x: endX, y: centerY)
            }
        }
        .frame(width: width, height: Self.rowHeight)
    }
}

/// 右向きの矢じり(三角形)。
private struct PromiseArrowHead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
