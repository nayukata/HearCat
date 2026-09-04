import HearCatKit
import SwiftUI

/// 質問応答パネルの ```weights フェンス(重み)の描画。話題ごとの言及量を横棒で示す。
/// AI が出すのは話題と言及区間の壁時計だけで、回数・合計時間は TopicWeights.parse が
/// 文字起こしの実時刻から測る(HearCatKit 参照)。
///
/// 行は縦 2 段: 上段にラベル(全幅・最大 2 行・省略しない)、下段に棒(残り幅すべて)と数値
/// (固定幅)。ラベル列・棒・数値を横 1 列(Grid)に並べていた旧実装は、ラベルが長いと
/// 「「どこか」アプリの評…」のように省略記号で切れて読めなくなっていた(実機で発覚)。
/// ラベルを独立した行にすることで、切らずに 2 行まで折り返して見せられるようにした。
/// 下段の HStack は全行で同じ左端(padding 直後)から始まるため、棒の左端は自然に揃う。
///
/// 尺度(時間 / 回数)は weights.measure(AI の指定、無ければ時間)を初期値にした @State で
/// 持ち、ヘッダー右の切り替えボタンでその場で入れ替えられる。並び替え・棒の長さ・数値表示は
/// 常にこの @State の値に従う(パース結果自体は測る前の 1 回だけで、並び替えは View 側)。
struct TopicWeightsView: View {
    let weights: TopicWeights
    let model: AppModel

    @State private var measure: TopicMeasure

    init(weights: TopicWeights, model: AppModel) {
        self.weights = weights
        self.model = model
        self._measure = State(initialValue: weights.measure)
    }

    /// 数値列の固定幅。「12 分」「8 回」程度の文字数が収まる幅。
    private static let valueColumnWidth: CGFloat = 48

    /// 現在の尺度で並べ替えた話題。sort 自体はここ(View 側)の責務(パース結果の topics の
    /// 並びは AI 出力時点の measure に基づくため、切り替え後はここで並べ直す)。
    private var sortedTopics: [TopicWeight] {
        switch measure {
        case .time:
            return weights.topics.sorted { $0.seconds > $1.seconds }
        case .count:
            return weights.topics.sorted { lhs, rhs in
                if lhs.mentions != rhs.mentions { return lhs.mentions > rhs.mentions }
                return lhs.seconds > rhs.seconds
            }
        }
    }

    /// 現在の尺度での最大値(棒の長さの基準)。
    private var maxValue: Double {
        switch measure {
        case .time: return weights.topics.map(\.seconds).max() ?? 0
        case .count: return weights.topics.map { Double($0.mentions) }.max() ?? 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = weights.title {
                Text(title)
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.textDim)
            }
            headerRow
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(sortedTopics.enumerated()), id: \.offset) { index, topic in
                    row(topic: topic, isTop: index == 0)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HCRadius.shape(HCRadius.card).fill(HCColor.surface))
    }

    /// 左に並び順の説明、右に尺度の切り替え(時間/回数)。
    private var headerRow: some View {
        HStack {
            Text(measure == .time ? "話した時間の長い順" : "言及回数の多い順")
                .font(HCFont.caption)
                .foregroundStyle(HCColor.textDim)
            Spacer()
            measureToggle
        }
    }

    private var measureToggle: some View {
        HStack(spacing: 4) {
            measureButton(title: "時間", target: .time)
            measureButton(title: "回数", target: .count)
        }
    }

    /// 選択中の尺度は、ボタン自体の色を書き換えるのではなく縁取りで示す(HCSecondaryButtonStyle
    /// が内部で configuration.label に自前の foregroundStyle を掛けているため、外側から色を
    /// 上書きしても反映されない。縁取りは overlay で描くので確実に見える)。
    private func measureButton(title: String, target: TopicMeasure) -> some View {
        Button(title) { measure = target }
            .buttonStyle(HCSecondaryButtonStyle(compact: true))
            .overlay(
                HCRadius.shape(HCRadius.control)
                    .stroke(HCColor.accentStroke, lineWidth: measure == target ? 1.5 : 0)
            )
    }

    private func row(topic: TopicWeight, isTop: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(topic.label)
                .font(HCFont.style(.body))
                .foregroundStyle(HCColor.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                GeometryReader { geo in
                    HCRadius.shape(HCRadius.keycap)
                        .fill(isTop ? HCColor.accent : HCColor.textDim.opacity(0.35))
                        .frame(width: barWidth(for: topic, totalWidth: geo.size.width), height: 8)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, minHeight: 14)
                Text(valueLabel(for: topic))
                    .font(HCFont.monospacedDigit(.caption1))
                    .foregroundStyle(HCColor.textDim)
                    .frame(width: Self.valueColumnWidth, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.revealTranscript(atTime: topic.firstStart) }
        .pointingHandOnHover()
    }

    private func value(for topic: TopicWeight) -> Double {
        switch measure {
        case .time: return topic.seconds
        case .count: return Double(topic.mentions)
        }
    }

    private func barWidth(for topic: TopicWeight, totalWidth: CGFloat) -> CGFloat {
        guard maxValue > 0 else { return 0 }
        return max(totalWidth * CGFloat(value(for: topic) / maxValue), 2)
    }

    /// time なら「12 分」(1 分未満は「30 秒」、1 分以上は四捨五入)、count なら「8 回」。
    /// 両方を並べては出さない(選ばれた尺度の値だけ)。
    private func valueLabel(for topic: TopicWeight) -> String {
        switch measure {
        case .time: return durationLabel(topic.seconds)
        case .count: return "\(topic.mentions) 回"
        }
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds.rounded())) 秒"
        }
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes) 分"
    }
}
