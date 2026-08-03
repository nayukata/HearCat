import Foundation
import UserNotifications

/// 録音・文字起こしがセッション中に無言で止まった時だけ、通知センターにも知らせる。
/// 権限拒否のようにセッション開始直後にパネルで気づける異常は対象にしない
/// (呼び分けは AppModel.handleHealthEvent 側の責務)。
///
/// CLI や `swift test` などアプリバンドル外の文脈で UNUserNotificationCenter に触ると
/// クラッシュするため、bundle identifier の有無で実行環境を判定してから使う。
@MainActor
enum HealthNotifier {
    /// 一度リクエストしたら結果に関わらず再リクエストしない
    /// (拒否されたユーザーに許可ダイアログを繰り返し見せない)。
    private static var authorizationRequested = false

    static func notify(title: String, body: String?) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            if !authorizationRequested {
                authorizationRequested = true
                // .provisional: 許可ダイアログを出さずに静かに通知センターへ届ける。
                // メニューバー表示が主経路で、通知は気づきの補助でしかないため、
                // 「許可するか」を毎回ユーザーに迫らない。
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .provisional])
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let body { content.body = body }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
