import ServiceManagement

/// ログイン時の自動起動(ログイン項目)の登録。状態の真実は SMAppService 側にあり、
/// UserDefaults には持たない(システム設定 > ログイン項目からの変更とずれないように)。
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard enabled != isEnabled else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
