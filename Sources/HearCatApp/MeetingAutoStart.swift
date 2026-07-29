import EventKit
import Foundation

/// 自動で録音を始める対象になった会議1回分。
struct CalendarMeeting: Equatable, Sendable {
    /// 繰り返しの予定は eventIdentifier が全回で共通のため、開始時刻と組にして
    /// 「今日のこの回」を指す ID にする(これを分けないと、週次定例が初回の1度きりで
    /// 処理済みになり、翌週から自動で始まらない)。
    let id: String
    let title: String
    let startDate: Date
}

/// カレンダーの予定のうち、どれを「会議」とみなすか。
///
/// 対象は「会議 URL を持つ」か「自分以外の参加者がいる」時間指定の予定に限る。
/// 時間指定の予定をすべて対象にすると、作業ブロックや個人の用事でも録音が始まり、
/// 同席者の音声を意図せず録ってしまう。逆に参加者だけを条件にすると、参加者を
/// 入れずに URL だけ貼るオンライン会議を取りこぼす。
enum CalendarMeetings {
    static func isMeeting(_ event: EKEvent) -> Bool {
        guard !event.isAllDay, event.status != .canceled else { return false }
        // 自分が辞退した予定は録らない(出ない会議の音は録りようがない)。
        if let me = event.attendees?.first(where: \.isCurrentUser),
            me.participantStatus == .declined {
            return false
        }
        if hasMeetingURL(event) { return true }
        return event.attendees?.contains { !$0.isCurrentUser } ?? false
    }

    /// 会議 URL を持つか。カレンダーの種類によって URL の入り先が違う
    /// (Google は URL 欄、手貼りは場所や説明欄)ため、3箇所とも見る。
    private static func hasMeetingURL(_ event: EKEvent) -> Bool {
        if let scheme = event.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return true
        }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty else { return false }
        return meetingHosts.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "chime.aws", "bluejeans.com",
        "gather.town", "around.co", "discord.gg", "slack.com",
    ]

    /// 今から horizon 秒後までに始まる直近の会議。grace 秒前までに始まったものも拾う
    /// (会議の開始直後に Mac を開いた場合にも間に合わせるため)。
    static func upcoming(within horizon: TimeInterval, grace: TimeInterval) async -> CalendarMeeting? {
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
        guard let next = candidates.min(by: { $0.startDate < $1.startDate }) else { return nil }
        let identifier = next.eventIdentifier ?? next.calendarItemIdentifier
        return CalendarMeeting(
            id: "\(identifier)@\(Int(next.startDate.timeIntervalSince1970))",
            title: next.title ?? "",
            startDate: next.startDate)
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
        guard let meeting = await CalendarMeetings.upcoming(
            within: Self.leadTime, grace: Self.grace)
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
