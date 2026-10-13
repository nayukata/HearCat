import Foundation

/// 録音の確認を出すかどうかの判断に使う、会議1回分の時間枠。
public struct MeetingSlot: Equatable, Sendable {
    public let id: String
    public let start: Date
    public let end: Date

    public init(id: String, start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }
}

/// 会議の開始前に出す「録音しますか」の確認を、いつ・どれに出すかの判断。
///
/// EventKit を持ち込まずにテストできるよう、時間枠だけを受け取る純粋な関数にしてある。
public enum MeetingPrompt {
    public struct Decision: Equatable, Sendable {
        /// 新しく確認を出す会議。出さないなら nil。
        public let show: MeetingSlot?
        /// 今回で処理済みにする会議の ID。確認を出さずに済ませるものも含む。
        public let handle: [String]
    }

    /// - Parameters:
    ///   - candidates: 確認の窓に入っている会議。
    ///   - handled: 確認を出した(または出さずに済ませた)会議の ID。
    ///   - shown: いま確認を出している会議。
    ///   - grace: 始まってから、この秒数までは新しく確認を出す。これを超えて続いている
    ///     会議には割り込まない(長い会議の途中で急に聞かれたら驚くため)。
    public static func decide(
        candidates: [MeetingSlot], handled: Set<String>, shown: MeetingSlot?,
        now: Date, grace: TimeInterval
    ) -> Decision {
        let unhandled = candidates
            .filter { $0.end > now && $0.start >= now.addingTimeInterval(-grace) }
            .filter { !handled.contains($0.id) }
            .sorted { $0.start < $1.start }
        // 確認は1枚だけ。出している間は、より遅く始まる会議のときだけ置き換える。
        // 開始時刻が同じ会議で置き換えると、先に見ていた方が15秒ほどで消えて押し損ねる。
        let pick = unhandled.first { shown == nil || $0.start > shown!.start }
        let ceiling = pick?.start ?? shown?.start
        let handle = unhandled.filter { ceiling != nil && $0.start <= ceiling! }.map(\.id)
        return Decision(show: pick, handle: handle)
    }

    /// 出している確認が、まだ有効か。予定の削除・時刻の変更・終了のいずれでも無効になる。
    /// 時刻が変わると ID も変わるため、窓に同じ ID が残っているかで足りる。
    public static func isStillValid(
        shown: MeetingSlot, candidates: [MeetingSlot], now: Date
    ) -> Bool {
        candidates.contains { $0.id == shown.id && $0.end > now }
    }
}
