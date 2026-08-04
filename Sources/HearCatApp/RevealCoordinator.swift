import SwiftUI

/// ジャンプの収束スクロール・ハイライト演出に使うタイミング定数。LiveSessionView・
/// SessionDetailView の双方(RevealCoordinator 経由)と、その背景を描く RevealHighlight が
/// 共有する。
enum RevealTiming {
    /// 収束スクロールの間隔。
    static let convergeInterval: Duration = .milliseconds(120)
    /// 収束スクロールの試行回数(この後さらに 1 回、アニメーション付きで投げ直す)。
    static let convergeCount = 2
    /// 最終スクロール(収束後、アニメーション付きで寄せる 1 回)の時間。
    static let finalScrollDuration = 0.25
    /// ハイライトを点灯し続ける時間。
    static let litDuration: Duration = .seconds(2.5)
    /// フェード消灯のアニメーション時間。
    static let fadeDuration = 0.4
}

/// 質問応答パネルの「根拠と補足」からのジャンプ先を、「前回タスクをキャンセル→ハイライト
/// 消灯→(RevealTiming.convergeInterval 間隔で RevealTiming.convergeCount 回)scrollTo→
/// アニメーション付き最終 scrollTo→点灯→RevealTiming.litDuration 後にフェード消灯」という
/// 一連の演出でハイライトする。LiveSessionView(ライブ画面)・SessionDetailView(過去
/// セッション詳細)の双方がほぼ同一の実装を持っていたため、この非 View 型に集約した。
/// 呼び出し側は「ジャンプ先の特定」(stamp 比較 / time 比較)だけを個別に持ち、特定後は
/// reveal(_:proxy:) を呼ぶだけでよい。
@MainActor
@Observable
final class RevealCoordinator<ID: Hashable> {
    /// 今フェード中にハイライトしている対象の id。nil ならハイライト無し。
    private(set) var revealedID: ID?

    /// ジャンプ先へのスクロールを収束させるためのタスク。文字起こしはどちらの画面も
    /// LazyVStack なので、未実体化の遠い行への scrollTo は推定高さで着地し、行きすぎたり
    /// 手前止まりになったりする。同じ target へ間隔を空けて複数回投げて収束させる。
    private var scrollTask: Task<Void, Never>?
    /// revealedID を消すためのタスク(点灯からの経過時間で消灯)。連続でジャンプされた時に
    /// 前回分をキャンセルして最初から光らせ直す。
    private var fadeTask: Task<Void, Never>?

    init() {}

    /// target へジャンプする。新しいジャンプが割り込んだ場合、収束が終わるまで
    /// 前回のハイライトを残さない。
    func reveal(_ target: ID, proxy: ScrollViewProxy) {
        scrollTask?.cancel()
        fadeTask?.cancel()
        revealedID = nil

        scrollTask = Task {
            // 未実体化行への scrollTo は推定高さで着地するため、同じ target へ間隔を空けて
            // 複数回投げ直して収束させる。途中はアニメーション無しにして視覚的に暴れないように
            // し、最後の 1 回だけ withAnimation で寄せる。ハイライトの点灯は収束後にする
            // (実体化前に光らせても、着地がずれた位置で光って見えるだけで意味が無いため)。
            for _ in 0..<RevealTiming.convergeCount {
                guard !Task.isCancelled else { return }
                proxy.scrollTo(target, anchor: .center)
                try? await Task.sleep(for: RevealTiming.convergeInterval)
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: RevealTiming.finalScrollDuration)) {
                proxy.scrollTo(target, anchor: .center)
            }
            guard !Task.isCancelled else { return }
            revealedID = target
            fadeTask = Task {
                try? await Task.sleep(for: RevealTiming.litDuration)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: RevealTiming.fadeDuration)) {
                    revealedID = nil
                }
            }
        }
    }
}

/// 質問応答パネルからのジャンプ先を、一時的な背景色でフェードイン→フェードアウトさせる
/// ViewModifier。SessionDetailView(再生位置ハイライトの CurrentLineHighlight と同時に
/// 立ちうる)・LiveSessionView(ダーク基調のライブ画面)の双方が共有する。
/// opacity はもともと SessionDetailView 側が 0.22、LiveSessionView 側が 0.3 と食い違って
/// いたが、この共通化に合わせて 0.22 に揃えた(ダーク基調のライブ画面では見えがわずかに
/// 薄くなるが、統一を優先し許容する)。
struct RevealHighlight: ViewModifier {
    let isRevealed: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if isRevealed {
                    HCRadius.shape(HCRadius.chip)
                        .fill(HCColor.cinnamon.opacity(0.22))
                }
            }
            .animation(.easeInOut(duration: RevealTiming.fadeDuration), value: isRevealed)
    }
}
