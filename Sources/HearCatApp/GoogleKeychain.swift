import Foundation
import Security

/// Google のリフレッシュトークンの保管庫。UserDefaults やファイルには置かない
/// (平文で残り、バックアップや設定の共有で漏れるため)。
protocol GoogleTokenStore: Sendable {
    func loadRefreshToken() -> String?
    func saveRefreshToken(_ token: String) throws
    func deleteRefreshToken()
}

enum GoogleKeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            "ログインの情報をキーチェーンに保存できませんでした (エラー \(status))"
        }
    }
}

struct GoogleKeychainStore: GoogleTokenStore {
    private let service = "dev.nayukata.hearcat.google-drive"
    private let account = "refresh-token"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func loadRefreshToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveRefreshToken(_ token: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(
            baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw GoogleKeychainError.saveFailed(update) }
        var add = baseQuery
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw GoogleKeychainError.saveFailed(status) }
    }

    func deleteRefreshToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
