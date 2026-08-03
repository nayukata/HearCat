import EventKit
import Foundation
import HearCatKit

/// 自動で録音を始める対象になった会議1回分。
struct CalendarMeeting: Equatable, Sendable {
    /// 繰り返しの予定は eventIdentifier が全回で共通のため、開始時刻と組にして
    /// 「今日のこの回」を指す ID にする(これを分けないと、週次定例が初回の1度きりで
    /// 処理済みになり、翌週から自動で始まらない)。
    let id: String
    /// 予定そのものの ID(開始時刻を含まない)。
    let eventID: String
    /// 繰り返しをまたいで共通の ID。「この予定は今後録らない」の記録にはこちらを使う。
    ///
    /// eventID(eventIdentifier)は、Google の繰り返しだと回ごとに
    /// `..._R20260617T020000@google.com` のように変わる。それを鍵にすると
    /// 一度外しても次の回にまた予告が出て、押すたびに「録らない予定」が増える。
    /// calendarItemExternalIdentifier は繰り返しの全回で同じ値になるので、こちらを使う。
    let seriesID: String
    let title: String
    let startDate: Date
}

/// カレンダーの予定のうち、どれを「会議」とみなすか。
///
/// 根拠は会議サービスの URL があることだけに限る。参加者の有無は根拠にしない。
/// 参加者が並んでいても、もくもく会や勉強会のように録る必要のない集まりがあり、
/// 人数からは会議かどうかを判別できないため。
enum CalendarMeetings {
    static func isMeeting(_ event: EKEvent) -> Bool {
        guard !event.isAllDay, event.status != .canceled else { return false }
        // 自分が辞退した予定は録らない(出ない会議の音は録りようがない)。
        // 参加者を見るのはここだけで、会議かどうかの判定には使わない。
        if let me = event.attendees?.first(where: \.isCurrentUser),
            me.participantStatus == .declined {
            return false
        }
        // 判定そのものは HearCatKit の MeetingRule に置く。EventKit を持ち込まずに
        // テストできるようにするため(この条件の緩さが自動録音の誤発火の原因だった)。
        return MeetingRule.mentionsMeetingHost([
            event.url?.absoluteString, event.location, event.notes,
        ])
    }

    /// 今から horizon 秒後までに始まる直近の会議。grace 秒前までに始まったものも拾う
    /// (会議の開始直後に Mac を開いた場合にも間に合わせるため)。
    static func upcoming(
        within horizon: TimeInterval, grace: TimeInterval,
        excludedIDs: Set<String> = [], keywords: [String] = []
    ) async -> CalendarMeeting? {
        guard let store = await CalendarAccess.authorizedStore() else { return nil }
        let now = Date()
        let windowStart = now.addingTimeInterval(-grace)
        let windowEnd = now.addingTimeInterval(horizon)
        // predicateForEvents は「期間に重なる予定」を返すため、既に始まって長く続いている
        // 予定も混ざる。開始時刻そのものが窓に入っているものだけに絞る。
        let predicate = store.predicateForEvents(
            withStart: windowStart, end: windowEnd, calendars: nil)
        let candidates = store.events(matching: predicate)
            .filter { isMeeting($0) && $0.startDate >= windowStart && $0.startDate <= windowEnd }
            // 本人が「録らない」と決めたものはここで落とす。予告も出さない。
            .filter { event in
                !MeetingRule.isExcluded(
                    eventIDs: exclusionIDs(of: event), title: event.title ?? "",
                    excludedIDs: excludedIDs, keywords: keywords)
            }
        guard let next = candidates.min(by: { $0.startDate < $1.startDate }) else { return nil }
        return meeting(from: next)
    }

    /// これから horizon 秒のあいだに始まる、会議とみなされる予定。
    /// 設定画面で「録らない予定」を選ばせるための一覧に使う。
    ///
    /// 繰り返しの予定は最初の回だけを返す。除外は予定そのものに対して効くため、
    /// 同じ予定が日付違いで並んでも選ぶ意味がないため。
    static func upcomingMeetings(within horizon: TimeInterval) async -> [CalendarMeeting] {
        guard let store = await CalendarAccess.authorizedStore() else { return [] }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(horizon), calendars: nil)
        var seen = Set<String>()
        return store.events(matching: predicate)
            .filter { isMeeting($0) && $0.startDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .compactMap { event in
                let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
                guard seen.insert(identifier).inserted else { return nil }
                return meeting(from: event)
            }
    }

    private static func meeting(from event: EKEvent) -> CalendarMeeting {
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        return CalendarMeeting(
            id: "\(identifier)@\(Int(event.startDate.timeIntervalSince1970))",
            eventID: identifier,
            seriesID: seriesID(of: event),
            title: event.title ?? "",
            startDate: event.startDate)
    }

    /// 繰り返しをまたいで共通の ID。取れなければ eventIdentifier に落ちる。
    private static func seriesID(of event: EKEvent) -> String {
        event.calendarItemExternalIdentifier
            ?? event.eventIdentifier
            ?? event.calendarItemIdentifier
    }

    /// 除外の判定に使う ID。新しく保存する分は seriesID だが、以前のバージョンが
    /// eventIdentifier で保存した分も外れたままになるよう両方を渡す。
    private static func exclusionIDs(of event: EKEvent) -> [String] {
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let series = seriesID(of: event)
        return series == identifier ? [identifier] : [series, identifier]
    }
}

/// 会議の開始時刻に合わせて、録音の開始を知らせる見張り役。
///
/// 開始そのものはここで行わない。予告を出してから始めるか、やめるかの判断は
/// アプリ側(AppModel)に任せる。
@MainActor
final class MeetingAutoStartScheduler {
    /// 予定の開始時刻より、この秒数だけ前に予告を出す。
    static let leadTime: TimeInterval = 30
    /// 開始済みの会議を拾う猶予。これを超えて始まっている会議には割り込まない
    /// (2時間続いている会議の途中で急に録音が始まったら驚くため)。
    private static let grace: TimeInterval = 60
    /// 予定を見に行く間隔。leadTime より短くないと予告のタイミングを跨いでしまう。
    private static let pollInterval: TimeInterval = 15

    /// 予告を出すべき会議が来た。同じ会議で二度は呼ばれない。
    var onDue: ((CalendarMeeting) -> Void)?
    /// 自動録音の対象から外す指定を読む。設定はいつでも変わるため、値ではなく
    /// 読み口を持って毎回引く(除外した直後の予定にも効かせるため)。
    var exclusions: (() -> (ids: Set<String>, keywords: [String]))?

    private var timer: Timer?
    private var enabled = false
    /// 予告済みの会議。アプリを再起動しても同じ会議で二度予告しないよう永続化する。
    private var handledIDs: [String]
    private static let handledKey = "handledMeetingAutoStartIDs"
    private static let handledLimit = 50

    init() {
        handledIDs = UserDefaults.standard.stringArray(forKey: Self.handledKey) ?? []
    }

    func setEnabled(_ on: Bool) {
        guard enabled != on else { return }
        enabled = on
        timer?.invalidate()
        timer = nil
        guard on else { return }
        // 有効にした直後にも一度見る(次の tick まで最大15秒待たせない)。
        Task { await tick() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
    }

    private func tick() async {
        guard enabled else { return }
        let excluded = exclusions?() ?? (ids: [], keywords: [])
        guard let meeting = await CalendarMeetings.upcoming(
            within: Self.leadTime, grace: Self.grace,
            excludedIDs: excluded.ids, keywords: excluded.keywords)
        else { return }
        guard !handledIDs.contains(meeting.id) else { return }
        markHandled(meeting.id)
        onDue?(meeting)
    }

    private func markHandled(_ id: String) {
        handledIDs.append(id)
        if handledIDs.count > Self.handledLimit {
            handledIDs.removeFirst(handledIDs.count - Self.handledLimit)
        }
        UserDefaults.standard.set(handledIDs, forKey: Self.handledKey)
    }
}
