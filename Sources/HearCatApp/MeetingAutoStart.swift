import AppKit
import EventKit
import Foundation
import HearCatKit

/// 録音の確認を出す対象になった会議1回分。
struct CalendarMeeting: Equatable, Sendable {
    /// 繰り返しの予定は eventIdentifier が全回で共通のため、開始時刻と組にして
    /// 「今日のこの回」を指す ID にする(これを分けないと、週次定例が初回の1度きりで
    /// 処理済みになり、翌週から確認が出ない)。
    let id: String
    /// 予定そのものの ID(開始時刻を含まない)。
    let eventID: String
    /// 繰り返しをまたいで共通の ID。「この予定は今後録らない」の記録にはこちらを使う。
    ///
    /// eventID(eventIdentifier)は、Google の繰り返しだと回ごとに
    /// `..._R20260617T020000@google.com` のように変わる。それを鍵にすると
    /// 一度外しても次の回にまた確認が出て、押すたびに「録らない予定」が増える。
    /// calendarItemExternalIdentifier は繰り返しの全回で同じ値になるので、こちらを使う。
    let seriesID: String
    let title: String
    let startDate: Date
    let endDate: Date

    var slot: MeetingSlot { MeetingSlot(id: id, start: startDate, end: endDate) }
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
        // テストできるようにするため(この条件の緩さが、会議でない予定への確認の誤発火の原因だった)。
        return MeetingRule.mentionsMeetingHost([
            event.url?.absoluteString, event.location, event.notes,
        ])
    }

    /// 今から horizon 秒後までに始まる会議と、いま続いている会議を、開始時刻の早い順に並べたもの。
    ///
    /// 終わっていない会議を全部返す。確認を出している間に予定が消えた・動いたかを
    /// 見分けるのに、始まった後の会議も窓に残しておく必要がある。始まってから何秒までなら
    /// 新しく確認を出すかは、呼び出し側(MeetingPrompt.decide)が決める。
    /// 開始時刻が近い会議が続く場合があるため、最も早い1件だけでなく全件を返す。
    static func upcoming(
        within horizon: TimeInterval,
        excludedIDs: Set<String> = [], keywords: [String] = []
    ) async -> [CalendarMeeting] {
        guard let store = await CalendarAccess.authorizedStore() else { return [] }
        let now = Date()
        let windowEnd = now.addingTimeInterval(horizon)
        let predicate = store.predicateForEvents(
            withStart: now, end: windowEnd, calendars: nil)
        let candidates = store.events(matching: predicate)
            .filter { isMeeting($0) && $0.startDate <= windowEnd && $0.endDate > now }
            // 本人が「録らない」と決めたものはここで落とす。確認も出さない。
            .filter { event in
                !MeetingRule.isExcluded(
                    eventIDs: exclusionIDs(of: event), title: event.title ?? "",
                    excludedIDs: excludedIDs, keywords: keywords)
            }
            .sorted { $0.startDate < $1.startDate }
        return candidates.map(meeting(from:))
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
            startDate: event.startDate,
            endDate: event.endDate)
    }

    /// 繰り返しをまたいで共通の ID。取れなければ eventIdentifier に落ちる。
    private static func seriesID(of event: EKEvent) -> String {
        event.calendarItemExternalIdentifier
            ?? event.eventIdentifier
            ?? event.calendarItemIdentifier
    }

    /// 除外の判定に使う ID。新しく保存する分は seriesID だが、以前のバージョンが
    /// eventIdentifier で保存した分も外れたままになるよう両方を渡す。
    static func exclusionIDs(of event: EKEvent) -> [String] {
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let series = seriesID(of: event)
        return series == identifier ? [identifier] : [series, identifier]
    }
}

/// 会議の開始時刻に合わせて、録音するかの確認を出す見張り役。
///
/// 録音の開始そのものはここで行わない。確認を出すか、押されたら始めるかは
/// アプリ側(AppModel)に任せる。
@MainActor
final class MeetingAutoStartScheduler {
    /// 予定の開始時刻より、この秒数だけ前に確認を出す。
    static let leadTime: TimeInterval = 30
    /// 開始済みの会議を拾う猶予。これを超えて始まっている会議には割り込まない
    /// (2時間続いている会議の途中で急に聞かれたら驚くため)。
    private static let grace: TimeInterval = 60
    /// 予定を見に行く間隔。leadTime より短くないと確認のタイミングを跨いでしまう。
    private static let pollInterval: TimeInterval = 15

    /// 確認を出すべき会議が来た。同じ会議で二度は呼ばれない。
    var onDue: ((CalendarMeeting) -> Void)?
    /// 出している確認の会議が、削除・時刻変更・終了のいずれかで無効になった。
    var onInvalidated: ((CalendarMeeting) -> Void)?
    /// 録音の対象から外す指定を読む。設定はいつでも変わるため、値ではなく
    /// 読み口を持って毎回引く(除外した直後の予定にも効かせるため)。
    var exclusions: (() -> (ids: Set<String>, keywords: [String]))?
    /// いま確認を出している会議。AppModel が確認を出した・閉じたときに更新する。
    var shown: CalendarMeeting?

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var enabled = false
    /// 確認済みの会議。アプリを再起動しても同じ会議で二度確認しないよう永続化する。
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
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        guard on else { return }
        // スリープ中は Timer が止まる。復帰後に次の tick を待つと、終わった会議の確認が
        // 最大15秒残るため、復帰の直後に一度見る。
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        // 有効にした直後にも一度見る(次の tick まで最大15秒待たせない)。
        Task { await tick() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
    }

    private func tick() async {
        guard enabled else { return }
        let excluded = exclusions?() ?? (ids: [], keywords: [])
        let meetings = await CalendarMeetings.upcoming(
            within: Self.leadTime,
            excludedIDs: excluded.ids, keywords: excluded.keywords)
        // 待っている間に止められた場合は、古い結果で確認を出さない。
        guard enabled else { return }
        let now = Date()
        let slots = meetings.map(\.slot)
        if let current = shown,
            !MeetingPrompt.isStillValid(shown: current.slot, candidates: slots, now: now) {
            shown = nil
            onInvalidated?(current)
        }
        let decision = MeetingPrompt.decide(
            candidates: slots, handled: Set(handledIDs), shown: shown?.slot,
            now: now, grace: Self.grace)
        decision.handle.forEach(markHandled)
        guard let pick = decision.show,
            let meeting = meetings.first(where: { $0.id == pick.id })
        else { return }
        shown = meeting
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
