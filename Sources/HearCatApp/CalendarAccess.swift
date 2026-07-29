import EventKit
import Foundation

/// カレンダー読み取りの入り口。許可の確認と要求をここ1箇所にまとめる。
///
/// 予定名の自動命名(CalendarNamer)と会議の自動開始(CalendarMeetings)の両方が
/// 同じ許可を必要とする。判定が2箇所にあると、片方だけ許可の扱いを直したときに
/// もう片方が静かに取り残される。
enum CalendarAccess {
    /// 読み取れる EKEventStore。許可が下りていなければ nil。
    ///
    /// 未確認(.notDetermined)のときだけ許可を求める。store を毎回作り直しているのは、
    /// 実測で 1 回あたり 0.2ms と軽く、使い回すには Sendable でない store を
    /// isolation をまたいで持ち回る必要があって割に合わないため。
    static func authorizedStore() async -> EKEventStore? {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return EKEventStore()
        case .notDetermined:
            let store = EKEventStore()
            return (try? await store.requestFullAccessToEvents()) == true ? store : nil
        default:
            return nil
        }
    }
}
