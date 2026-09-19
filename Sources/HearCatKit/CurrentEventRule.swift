import Foundation

/// カレンダーの予定の中から「今録っているはずの予定」を選ぶ、EventKit に依存しない部分。
///
/// Google カレンダー等では、全日フラグ無しの終日近い予定(例:「有休」を 5:00〜22:00 の
/// 時間指定予定として同期したもの)が来ることがある。これが「進行中の予定」として個別の
/// 会議より優先されると、大きい枠に入れ子になった短い会議の名前が付かない。長い枠は
/// 「入れ物」であって「今録っている予定」ではないため、他の候補の期間を丸ごと含む予定は
/// 候補から外してから、進行中優先の順位で選ぶ。
public enum CurrentEventRule {
    /// 選択の対象になる予定。EventKit の EKEvent から呼び出し側が変換する。
    public struct Candidate: Equatable, Sendable {
        public let title: String
        public let start: Date
        public let end: Date

        public init(title: String, start: Date, end: Date) {
            self.title = title
            self.start = start
            self.end = end
        }
    }

    /// 候補の中から「今の予定」を選ぶ。
    ///
    /// 0. 終了時刻が開始時刻より前の壊れた予定(end < start)を外す。長さ0(end == start)
    ///    は残す。次の「まだ終わっていない」判定と、含む・含まれるの判定を壊れた
    ///    予定に対して行うと、正常な予定側が誤って外れることがあるため先に除く。
    /// 1. まだ終わっていない(end > now)かつ先読み窓の中で始まる(start <= now + lookahead)
    ///    ものに絞る。呼び出し側の検索窓に依存せず規則側でも絞ることで、窓の外の
    ///    予定を含む判定に混ぜて短い予定を誤って落とさないようにする。
    /// 2. 他の候補の期間を丸ごと含む(厳密に大きい)予定を外す。同一期間どうしは
    ///    互いに含む関係とみなさず、両方残す。
    /// 3. 残った候補のうち、進行中(start <= now)を優先し、複数あれば一番あとに
    ///    始まったもの(=今の会議の可能性が高い)。
    /// 4. 進行中が無ければ、まもなく始まる(start > now)予定のうち一番早く始まるもの。
    public static func pick(_ candidates: [Candidate], now: Date, lookahead: TimeInterval)
        -> Candidate?
    {
        let deadline = now.addingTimeInterval(lookahead)
        let windowed = candidates.filter {
            $0.end >= $0.start && $0.end > now && $0.start <= deadline
        }
        let narrowed = windowed.filter { candidate in
            !windowed.contains { other in
                candidate.start <= other.start && candidate.end >= other.end
                    && (candidate.start, candidate.end) != (other.start, other.end)
            }
        }
        let current = narrowed.filter { $0.start <= now }.max { $0.start < $1.start }
        let upcoming = narrowed.filter { $0.start > now }.min { $0.start < $1.start }
        return current ?? upcoming
    }
}
