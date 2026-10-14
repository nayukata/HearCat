import AppKit
import CryptoKit
import Foundation
import Network

/// Google OAuth のクライアント資格情報。ビルド時に Info.plist へ注入される
/// (Makefile の app ターゲット。値はリポジトリに入れない)。
struct GoogleOAuthConfig: Equatable, Sendable {
    let clientID: String
    let clientSecret: String

    /// 注入されていないビルドでは nil。連携そのものを無効にする判断に使う。
    static func fromBundle(_ bundle: Bundle = .main) -> GoogleOAuthConfig? {
        let id = (bundle.object(forInfoDictionaryKey: "HearCatGoogleClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = (bundle.object(forInfoDictionaryKey: "HearCatGoogleClientSecret") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return GoogleOAuthConfig(clientID: id, clientSecret: secret)
    }
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

/// ブラウザからループバックへ戻ってきたリダイレクトの読み取り。
enum GoogleOAuthRedirect: Equatable {
    case code(String)
    /// ユーザーが同意を拒んだ、などでブラウザ側から返ってきた理由。
    case denied(String)
    /// 認可コードも error も無い、または state が合わない。別物のリクエストとして無視する。
    case invalid

    /// HTTP リクエスト行のターゲット("/?code=...&state=...")を読む。
    static func parse(requestTarget: String, expectedState: String) -> GoogleOAuthRedirect {
        guard let components = URLComponents(string: "http://127.0.0.1" + requestTarget) else {
            return .invalid
        }
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

    /// 生の HTTP リクエスト("GET /path HTTP/1.1\r\n...")から、リクエストターゲットを取り出す。
    static func requestTarget(fromHTTPRequest text: String) -> String? {
        guard let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first
        else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }
}

enum GoogleOAuthError: LocalizedError {
    case notConfigured
    case cancelled
    case denied(String)
    case timedOut
    case listenerFailed(String)
    case tokenExchangeFailed(String)
    /// リフレッシュトークンが取り消された・期限切れ。ログインし直しが必要。
    case reloginRequired
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "このビルドでは Google Drive 連携が使えません"
        case .cancelled: "ログインを取りやめました"
        case .denied(let reason): "Google 側でログインが許可されませんでした (\(reason))"
        case .timedOut: "ログインの完了を待っている間に時間切れになりました。もう一度お試しください"
        case .listenerFailed(let detail): "ログインの準備ができませんでした: \(detail)"
        case .tokenExchangeFailed(let detail): "ログインを完了できませんでした: \(detail)"
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
    let config: GoogleOAuthConfig
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
        var fields = fields
        fields["client_id"] = config.clientID
        fields["client_secret"] = config.clientSecret
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

/// ループバックで認可コードを 1 回だけ受け取る小さな HTTP サーバー。
final class GoogleLoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.nayukata.hearcat.oauth-loopback")
    private let state: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GoogleOAuthRedirect, Error>?
    private var finished = false
    private(set) var port: UInt16 = 0

    init(state: String) throws {
        self.state = state
        // 空きポートを OS に選ばせる。127.0.0.1 のみで待つので、同じネットワークの他機器からは届かない。
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    /// 待ち受けを始め、割り当てられたポートを返す。
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    if let port = self.listener.port?.rawValue, resumed.take() {
                        self.port = port
                        cont.resume(returning: port)
                    }
                case .failed(let error):
                    if resumed.take() {
                        cont.resume(throwing: GoogleOAuthError.listenerFailed(error.localizedDescription))
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// リダイレクトが来るまで待つ。timeout 秒で諦める。キャンセルにも応じる。
    func waitForRedirect(timeout: TimeInterval) async throws -> GoogleOAuthRedirect {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if finished {
                    lock.unlock()
                    cont.resume(throwing: GoogleOAuthError.cancelled)
                    return
                }
                continuation = cont
                lock.unlock()
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(GoogleOAuthError.timedOut))
                }
            }
        } onCancel: {
            self.finish(.failure(GoogleOAuthError.cancelled))
        }
    }

    func stop() {
        finish(.failure(GoogleOAuthError.cancelled))
    }

    private func finish(_ result: Result<GoogleOAuthRedirect, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        listener.cancel()
        guard !alreadyFinished, let cont else { return }
        cont.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8),
                let target = GoogleOAuthRedirect.requestTarget(fromHTTPRequest: text)
            else {
                connection.cancel()
                return
            }
            let redirect = GoogleOAuthRedirect.parse(requestTarget: target, expectedState: self.state)
            // favicon など、認可と無関係なリクエストは無視して待ち続ける。
            guard redirect != .invalid else {
                Self.respond(connection, body: "このページは閉じて構いません。")
                return
            }
            let body: String
            if case .code = redirect {
                body = "HearCat のログインが完了しました。このタブは閉じて構いません。"
            } else {
                body = "ログインは完了しませんでした。HearCat に戻ってください。"
            }
            Self.respond(connection, body: body) { self.finish(.success(redirect)) }
        }
    }

    private static func respond(_ connection: NWConnection, body: String, then: (@Sendable () -> Void)? = nil) {
        let html = "<!doctype html><meta charset=\"utf-8\"><title>HearCat</title><p style=\"font:16px -apple-system;margin:3em\">\(body)</p>"
        let payload = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
            then?()
        })
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// ブラウザを開いて認可コードを受け取り、トークンへ交換するまでの一連。
struct GoogleLoginFlow {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!

    let config: GoogleOAuthConfig
    let endpoint: GoogleTokenEndpoint
    var openBrowser: @Sendable (URL) -> Void = { url in
        Task { @MainActor in NSWorkspace.shared.open(url) }
    }

    static func authorizationURL(
        config: GoogleOAuthConfig, redirectURI: String, state: String, challenge: String
    ) -> URL {
        var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
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
        let receiver = try GoogleLoopbackReceiver(state: state)
        defer { receiver.stop() }
        let port = try await receiver.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        openBrowser(
            Self.authorizationURL(
                config: config, redirectURI: redirectURI, state: state, challenge: pkce.challenge))
        switch try await receiver.waitForRedirect(timeout: 300) {
        case .code(let code):
            let response = try await endpoint.exchange(
                code: code, verifier: pkce.verifier, redirectURI: redirectURI)
            guard response.refreshToken != nil else {
                throw GoogleOAuthError.tokenExchangeFailed("リフレッシュトークンが返りませんでした")
            }
            return response
        case .denied(let reason):
            throw GoogleOAuthError.denied(reason)
        case .invalid:
            throw GoogleOAuthError.tokenExchangeFailed("不正なリダイレクトです")
        }
    }
}
