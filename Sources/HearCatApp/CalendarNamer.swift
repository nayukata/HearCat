import EventKit
import Foundation
import HearCatKit

/// セッション開始時に「今の予定」を引く。セッション名の自動提案と、保存先グループの
/// 推測に使う。macOS のカレンダーに追加したアカウント(Google 等)の予定も
/// EventKit 経由でそのまま読める。
enum CalendarNamer {
    /// 会議の少し前に録音を始めることが多いため、これから始まる予定もこの秒数まで先読みする。
    /// 「その予定の枠でもう録ったか」を数える側も、同じ秒数だけ予定の開始より前から数える
    /// (先読みで付いた名前のセッションは予定の開始より前に始まっているため)。
    static let lookahead: TimeInterval = 5 * 60

    /// 今の(またはまもなく始まる)予定。開始時刻を一緒に返すのは、「この予定の分は
    /// もう録れているか」を呼び出し側が判断できるようにするため。
    struct Event: Equatable, Sendable {
        let title: String
        let startDate: Date
    }

    /// 今の時刻に重なる(またはまもなく始まる)予定。
    /// 許可が下りない・予定が無い・予定名が空の場合は nil(セッションは日時のみの名前になる)。
    static func currentEvent() async -> Event? {
        guard let store = await CalendarAccess.authorizedStore() else { return nil }

        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(Self.lookahead), calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay }
        // 「有休(全日)」のように全日フラグ無しで長く同期される予定に、入れ子の
        // 個別会議が埋もれないよう、選ぶ規則自体は CurrentEventRule に委ねる。
        // startDate / endDate は EventKit 側で Date! (暗黙アンラップ) のため、
        // 欠けていた場合は候補から静かに外す。
        let candidates = events.compactMap { event -> CurrentEventRule.Candidate? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return CurrentEventRule.Candidate(title: event.title ?? "", start: start, end: end)
        }
        guard let picked = CurrentEventRule.pick(candidates, now: now, lookahead: Self.lookahead),
              !picked.title.isEmpty
        else { return nil }
        return Event(title: picked.title, startDate: picked.start)
    }
}
