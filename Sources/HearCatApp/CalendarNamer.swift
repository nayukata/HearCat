import EventKit
import Foundation

/// セッション開始時に「今の予定」を引く。セッション名の自動提案と、保存先グループの
/// 推測に使う。macOS のカレンダーに追加したアカウント(Google 等)の予定も
/// EventKit 経由でそのまま読める。
enum CalendarNamer {
    /// 会議の少し前に録音を始めることが多いため、これから始まる予定もこの秒数まで先読みする。
    private static let lookahead: TimeInterval = 5 * 60

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
        // 進行中の予定を優先し、重なっていたら一番あとに始まったもの(=今の会議の可能性が高い)。
        // 進行中が無ければ、まもなく始まる直近の予定。
        let current = events.filter { $0.startDate <= now }.max { $0.startDate < $1.startDate }
        let upcoming = events.filter { $0.startDate > now }.min { $0.startDate < $1.startDate }
        guard let event = current ?? upcoming,
              let title = event.title, !title.isEmpty
        else { return nil }
        return Event(title: title, startDate: event.startDate)
    }
}
