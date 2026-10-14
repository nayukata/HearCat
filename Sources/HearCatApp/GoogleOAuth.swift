import AppKit
import CryptoKit
import Foundation

/// Google OAuth のクライアント設定。iOS 用のクライアントで、シークレットを持たない(PKCE のみ)。
/// クライアント ID は公開してよい値なので、ソースに置く。
enum GoogleOAuthConfig {
    static let clientID = "752021658685-3run7ia49ch7q24vhnmu6p64tppj9kmv.apps.googleusercontent.com"
    /// ブラウザから戻るときの URL スキームは、クライアント ID を逆順にしたもの(Info.plist の
    /// CFBundleURLTypes と一致させる)。
    static let redirectScheme = "com.googleusercontent.apps.752021658685-3run7ia49ch7q24vhnmu6p64tppj9kmv"
    static let redirectURI = "\(redirectScheme):/oauth2redirect"
}

/// PKCE(RFC 7636)の組。verifier は 43〜128 文字の unreserved 文字、challenge はその SHA-256 の base64url。
struct PKCEPair: Equatable, Sendable {
    let verifier: String
    let challenge: String

    static func generate() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        let verifier = base64URL(Data(bytes))
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// ブラウザから戻ってきたリダイレクトの読み取り。
enum GoogleOAuthRedirect: Equatable {
    case code(String)
    /// ユーザーが同意を拒んだ、などでブラウザ側から返ってきた理由。
    case denied(String)
    /// 認可コードも error も無い、state が合わない、別の URL。ログインとは無関係なものとして無視する。
    case invalid

    /// ブラウザから戻ってきた URL を読む。スキームとパスが違う URL、state が合わない URL は .invalid。
    static func parse(url: URL, expectedState: String) -> GoogleOAuthRedirect {
        guard url.scheme?.lowercased() == GoogleOAuthConfig.redirectScheme,
            url.path == "/oauth2redirect",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .invalid }
        let items = Dictionary(
            (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            },
            uniquingKeysWith: { first, _ in first })
        guard items["state"] == expectedState else { return .invalid }
        if let error = items["error"] { return .denied(error) }
        if let code = items["code"], !code.isEmpty { return .code(code) }
        return .invalid
    }
}

enum GoogleOAuthError: LocalizedError {
    case notConfigured
    case cancelled
    case denied(String)
    case timedOut
    case tokenExchangeFailed(String)
    /// リフレッシュトークンが取り消された・期限切れ。ログインし直しが必要。
    case reloginRequired
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "このバージョンの HearCat では、Google Drive への書き出しを使えません。"
        case .cancelled: "ログインをやめました"
        case .denied(let reason): "Google でログインが許可されませんでした (\(reason))"
        case .timedOut: "ログインが時間内に終わりませんでした。もう一度ログインしてください"
        case .tokenExchangeFailed(let detail): "ログインできませんでした: \(detail)"
        case .reloginRequired: "Google Drive にログインし直してください"
        case .network(let detail): "Google に接続できませんでした: \(detail)"
        }
    }
}

/// アクセストークンの供給元。Drive の呼び出しはこれ越しにトークンを得る。
protocol GoogleAccessTokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
    /// 更新したトークンでも拒否されたときに、保存済みの鍵を捨ててログアウト状態にする。
    func invalidate() async
}

/// トークンの交換・更新・取り消しを行う HTTP 呼び出しの境界。
protocol GoogleTokenEndpoint: Sendable {
    func exchange(code: String, verifier: String, redirectURI: String) async throws -> GoogleTokenResponse
    func refresh(refreshToken: String) async throws -> GoogleTokenResponse
    func revoke(token: String) async
}

struct GoogleTokenResponse: Equatable, Sendable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?
}

struct GoogleURLSessionTokenEndpoint: GoogleTokenEndpoint {
    let clientID: String
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!

    func exchange(code: String, verifier: String, redirectURI: String) async throws -> GoogleTokenResponse {
        try await post([
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ])
    }

    func refresh(refreshToken: String) async throws -> GoogleTokenResponse {
        try await post(["grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    func revoke(token: String) async {
        var request = URLRequest(url: Self.revokeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["token": token])
        _ = try? await URLSession.shared.data(for: request)
    }

    private func post(_ fields: [String: String]) async throws -> GoogleTokenResponse {
        let fields = Self.requestFields(fields, clientID: clientID)
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GoogleOAuthError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let access = json?["access_token"] as? String else {
            let reason = json?["error"] as? String ?? "HTTP \(status)"
            // 取り消し・期限切れ。再ログインしか直す手が無い。
            if reason == "invalid_grant" { throw GoogleOAuthError.reloginRequired }
            // 5xx は一時的な障害。再ログインを促さず、通信エラーとして扱う。
            if status >= 500 || status == 429 { throw GoogleOAuthError.network("HTTP \(status)") }
            throw GoogleOAuthError.tokenExchangeFailed(reason)
        }
        return GoogleTokenResponse(
            accessToken: access,
            expiresIn: (json?["expires_in"] as? Double) ?? 3600,
            refreshToken: json?["refresh_token"] as? String)
    }

    /// トークン要求の項目。iOS 用のクライアントはシークレットを持たず、PKCE の verifier だけで本人確認する。
    static func requestFields(_ base: [String: String], clientID: String) -> [String: String] {
        var fields = base
        fields["client_id"] = clientID
        return fields
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let text = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(text.utf8)
    }
}

/// アクセストークンをメモリに持ち、期限が近づいたらリフレッシュトークンで更新する。
/// 更新が同時に重なっても 1 本にまとめる。
actor GoogleAuthSession: GoogleAccessTokenProvider {
    private let endpoint: GoogleTokenEndpoint
    private let store: GoogleTokenStore
    private let now: @Sendable () -> Date
    private var cached: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?

    init(
        endpoint: GoogleTokenEndpoint, store: GoogleTokenStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.store = store
        self.now = now
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached, cached.expires > now().addingTimeInterval(60) {
            return cached.token
        }
        if let refreshing { return try await refreshing.value }
        guard let refreshToken = store.loadRefreshToken() else {
            throw GoogleOAuthError.reloginRequired
        }
        let task = Task<String, Error> {
            do {
                let response = try await endpoint.refresh(refreshToken: refreshToken)
                cached = (response.accessToken, now().addingTimeInterval(response.expiresIn))
                return response.accessToken
            } catch GoogleOAuthError.reloginRequired {
                // 取り消された鍵を残すと、毎回同じ失敗を繰り返す。
                cached = nil
                store.deleteRefreshToken()
                throw GoogleOAuthError.reloginRequired
            }
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    func invalidate() {
        cached = nil
        store.deleteRefreshToken()
    }

    /// ログイン直後に、交換で得たトークンを受け取る。
    func adopt(_ response: GoogleTokenResponse) throws {
        if let refresh = response.refreshToken { try store.saveRefreshToken(refresh) }
        cached = (response.accessToken, now().addingTimeInterval(response.expiresIn))
    }

    func signOut() async {
        let token = store.loadRefreshToken()
        cached = nil
        store.deleteRefreshToken()
        if let token { await endpoint.revoke(token: token) }
    }
}
/// ブラウザからアプリ専用の URL スキームで戻ってきた URL を、ログイン中の待ち手へ渡す窓口。
/// URL は AppDelegate が受け取ってここへ流す。ログイン中でないときに届いた URL は捨てる。
final class GoogleLoginRedirectCenter: @unchecked Sendable {
    static let shared = GoogleLoginRedirectCenter()

    private let lock = NSLock()
    private var waiting: (state: String, continuation: CheckedContinuation<GoogleOAuthRedirect, Error>)?

    /// 戻りの URL を受け取るのを待つ。timeout 秒で諦め、Task のキャンセルにも応じる。
    func wait(state: String, timeout: TimeInterval) async throws -> GoogleOAuthRedirect {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                // 前のログインが残っていれば取りやめにして、新しい方を待つ。
                let previous = waiting
                waiting = (state, cont)
                lock.unlock()
                previous?.continuation.resume(throwing: GoogleOAuthError.cancelled)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    self?.finish(state: state, with: .failure(GoogleOAuthError.timedOut))
                }
            }
        } onCancel: {
            self.finish(state: state, with: .failure(GoogleOAuthError.cancelled))
        }
    }

    /// AppDelegate から届いた URL を渡す。受け付けたら true。
    /// 待っていないとき、別のスキームのとき、state が合わないときは無視する。
    @discardableResult
    func deliver(_ url: URL) -> Bool {
        lock.lock()
        let current = waiting
        lock.unlock()
        guard let current else { return false }
        let redirect = GoogleOAuthRedirect.parse(url: url, expectedState: current.state)
        guard redirect != .invalid else { return false }
        return finish(state: current.state, with: .success(redirect))
    }

    @discardableResult
    private func finish(state: String, with result: Result<GoogleOAuthRedirect, Error>) -> Bool {
        lock.lock()
        guard let current = waiting, current.state == state else {
            lock.unlock()
            return false
        }
        waiting = nil
        lock.unlock()
        current.continuation.resume(with: result)
        return true
    }
}

/// ブラウザを開いて認可コードを受け取り、トークンへ交換するまでの一連。
struct GoogleLoginFlow {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!

    let endpoint: GoogleTokenEndpoint
    var center: GoogleLoginRedirectCenter = .shared
    var openBrowser: @Sendable (URL) -> Void = { url in
        Task { @MainActor in NSWorkspace.shared.open(url) }
    }

    static func authorizationURL(state: String, challenge: String) -> URL {
        var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleOAuthConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleOAuthConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // リフレッシュトークンを確実に得るため、毎回同意画面を経由する。
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    func run() async throws -> GoogleTokenResponse {
        let pkce = PKCEPair.generate()
        let state = PKCEPair.generate().verifier
        // 戻りの URL を先に待ち始めてからブラウザを開く(開いた直後に戻っても取りこぼさない)。
        async let redirect = center.wait(state: state, timeout: 300)
        openBrowser(Self.authorizationURL(state: state, challenge: pkce.challenge))
        switch try await redirect {
        case .code(let code):
            let response = try await endpoint.exchange(
                code: code, verifier: pkce.verifier, redirectURI: GoogleOAuthConfig.redirectURI)
            guard response.refreshToken != nil else {
                throw GoogleOAuthError.tokenExchangeFailed("Google からログインの情報を受け取れませんでした")
            }
            return response
        case .denied(let reason):
            throw GoogleOAuthError.denied(reason)
        case .invalid:
            throw GoogleOAuthError.tokenExchangeFailed("Google からの応答が正しくありません")
        }
    }
}
