import Foundation

/// Drive 上の 1 ファイル。更新の応答が trashed を含むのは、ごみ箱へ入れられた
/// ファイルへの更新が成功扱いで通ってしまうため(新規作成へ切り替える判断に使う)。
struct DriveFileRef: Equatable, Sendable {
    let id: String
    let trashed: Bool
    /// 親の付け替えを権限で断られ、元の親のままになった。
    var moveFailed = false
}

enum DriveError: LocalizedError, Equatable {
    case notSignedIn
    case notFound
    case rateLimited(String)
    case http(status: Int, message: String)
    /// 403 のうち、利用制限ではないもの(権限・容量超過など)。reason は Google の返した理由。
    case forbidden(reasons: [String], message: String)
    case network(String)
    case localFile(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Google Drive にログインし直してください"
        case .notFound: "Google Drive にファイルが見つかりません"
        case .rateLimited(let detail): "Google Drive の利用回数の上限に達しました。しばらくしてから書き出し直してください (\(detail))"
        case .http(let status, let message): "Google Drive でエラーが起きました (\(status)): \(message)"
        case .forbidden(_, let message): "Google Drive でエラーが起きました (403): \(message)"
        case .network(let detail): "Google Drive に接続できませんでした: \(detail)"
        case .localFile(let detail): "書き出すファイルを開けませんでした: \(detail)"
        }
    }

    /// 何度やっても直らない認証の失敗。残りの中身を試さずに止める。
    var isFatal: Bool { self == .notSignedIn }

    /// 待てば通る可能性がある失敗(通信断・利用制限・5xx)。
    var isTransient: Bool {
        switch self {
        case .network, .rateLimited: true
        case .http(let status, _): status >= 500
        case .notSignedIn, .notFound, .localFile, .forbidden: false
        }
    }
}

/// アップロードする中身。文書は Google ドキュメントへ変換して置き、録音はそのまま置く。
struct DriveUpload: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// markdown を Google ドキュメントへ変換して置く。
        case document
        /// 変換せずそのまま置く。
        case raw(mimeType: String)
    }

    let name: String
    let fileURL: URL
    let kind: Kind
}

/// Drive の呼び出し境界。実体は GoogleDriveAPI、テストでは偽物に差し替える。
protocol DriveAPI: Sendable {
    /// 自分のメールアドレス(ログイン表示用)。
    func accountEmail() async throws -> String
    /// ごみ箱に入っていないフォルダの検索。見つからなければ nil。
    func findFolder(name: String, parentID: String?) async throws -> String?
    func createFolder(name: String, parentID: String?) async throws -> String
    /// 親フォルダ内の同名ファイル(フォルダ以外、ごみ箱を除く)の検索。見つからなければ nil。
    func findFile(name: String, parentID: String) async throws -> String?
    func create(_ upload: DriveUpload, parentID: String) async throws -> DriveFileRef
    /// 既存ファイルの親が parentID でなければ parentID へ移し、contentChanged なら中身も差し替える。
    /// 中身が変わっていなければ本文は送らず、移動だけをメタデータで行う。
    /// ID が存在しなければ DriveError.notFound。ごみ箱の中なら何も触らず trashed で返す。
    func update(
        fileID: String, with upload: DriveUpload, parentID: String, contentChanged: Bool
    ) async throws -> DriveFileRef
    /// ごみ箱へ移す。もう無ければ何もしない。
    func trash(fileID: String) async throws
}

/// 再開可能アップロードのセッション URI が失効した(404/410)、または再開の前提が崩れた
/// (ファイルの大きさが変わった)。アップロードを最初からやり直す合図で、
/// ファイル自体の消失(DriveError.notFound)とは区別する。
private struct UploadSessionExpired: Error {}

/// リダイレクトを追わない。再開可能アップロードの 308 は「続きを送れ」の意味で、移動先は無い。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

/// Drive API v3 の実装。
struct GoogleDriveAPI: DriveAPI {
    let tokens: GoogleAccessTokenProvider
    let session: URLSession

    static let apiBase = "https://www.googleapis.com/drive/v3"
    static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    static let folderMime = "application/vnd.google-apps.folder"
    static let documentMime = "application/vnd.google-apps.document"
    static let markdownMime = "text/markdown"

    init(tokens: GoogleAccessTokenProvider, session: URLSession? = nil) {
        self.tokens = tokens
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            // 数十 MB の録音をアップロードしている間も打ち切られないようにする。
            config.timeoutIntervalForResource = 60 * 60
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - クエリの組み立て

    /// クエリ文字列をパーセントエンコードする。URLQueryItem 任せにすると `+` が
    /// そのまま残り、サーバー側で空白と解釈されて `C++` が `C  ` になる。
    static func encodedQuery(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return items.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    /// files.list の q。name は '\\' と '\'' をエスケープする。
    static func searchQuery(name: String, parentID: String?, folder: Bool) -> String {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let kind = folder ? "mimeType = '\(folderMime)'" : "mimeType != '\(folderMime)'"
        return "name = '\(escaped)' and \(kind) and '\(parentID ?? "root")' in parents and trashed = false"
    }

    static func searchURL(name: String, parentID: String?, folder: Bool) -> URL {
        let query = encodedQuery([
            ("q", searchQuery(name: name, parentID: parentID, folder: folder)),
            ("fields", "files(id)"),
            ("pageSize", "1"),
            ("orderBy", "createdTime"),
        ])
        return URL(string: apiBase + "/files?" + query)!
    }

    // MARK: - API

    func accountEmail() async throws -> String {
        let data = try await send(path: "/about?fields=user(emailAddress)")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let user = json?["user"] as? [String: Any]
        return user?["emailAddress"] as? String ?? ""
    }

    func findFolder(name: String, parentID: String?) async throws -> String? {
        try await firstID(of: Self.searchURL(name: name, parentID: parentID, folder: true))
    }

    func findFile(name: String, parentID: String) async throws -> String? {
        try await firstID(of: Self.searchURL(name: name, parentID: parentID, folder: false))
    }

    private func firstID(of url: URL) async throws -> String? {
        let data = try await send(url: url)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["files"] as? [[String: Any]])?.first?["id"] as? String
    }

    func createFolder(name: String, parentID: String?) async throws -> String {
        var metadata: [String: Any] = ["name": name, "mimeType": Self.folderMime]
        if let parentID { metadata["parents"] = [parentID] }
        let data = try await send(
            path: "/files?fields=id", method: "POST",
            body: try JSONSerialization.data(withJSONObject: metadata),
            contentType: "application/json")
        return try Self.fileRef(from: data).id
    }

    func create(_ upload: DriveUpload, parentID: String) async throws -> DriveFileRef {
        var metadata: [String: Any] = ["name": upload.name, "parents": [parentID]]
        if upload.kind == .document { metadata["mimeType"] = Self.documentMime }
        return try await transfer(upload, metadata: metadata, fileID: nil, extraQuery: "")
    }

    func trash(fileID: String) async throws {
        do {
            _ = try await send(
                path: "/files/\(fileID)?fields=id", method: "PATCH",
                body: Data(#"{"trashed":true}"#.utf8), contentType: "application/json")
        } catch DriveError.notFound {}
    }

    func update(
        fileID: String, with upload: DriveUpload, parentID: String, contentChanged: Bool
    ) async throws -> DriveFileRef {
        let data = try await send(path: "/files/\(fileID)?fields=id,parents,trashed")
        let current = try Self.fileRef(from: data)
        if current.trashed { return current }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let parents = json?["parents"] as? [String] ?? []
        var extra = ""
        if !parents.contains(parentID) { extra += "&addParents=\(parentID)" }
        let stale = parents.filter { $0 != parentID }
        if !stale.isEmpty { extra += "&removeParents=\(stale.joined(separator: ","))" }
        if !contentChanged {
            guard !extra.isEmpty else { return current }
            do {
                let moved = try await send(
                    path: "/files/\(fileID)?fields=id,trashed" + extra, method: "PATCH",
                    body: Data("{}".utf8), contentType: "application/json")
                return try Self.fileRef(from: moved)
            } catch DriveError.forbidden(let reasons, _) where Self.isPermissionFailure(reasons) {
                var unmoved = current
                unmoved.moveFailed = true
                return unmoved
            }
        }
        do {
            return try await transfer(upload, metadata: [:], fileID: fileID, extraQuery: extra)
        } catch DriveError.forbidden(let reasons, _) where !extra.isEmpty && Self.isPermissionFailure(reasons) {
            // 親の付け替えだけ権限が無いことがある。移さずに本文だけは最新にする。
            var unmoved = try await transfer(upload, metadata: [:], fileID: fileID, extraQuery: "")
            unmoved.moveFailed = true
            return unmoved
        }
    }

    /// 親の付け替えだけを諦めて本文を更新し直してよい 403 の reason(明示した一覧)。
    /// これ以外の 403(容量超過など)は、諦めても直らないので失敗として扱う。
    static let permissionReasons: Set<String> = [
        "insufficientFilePermissions", "insufficientParentPermissions", "insufficientPermissions",
        "cannotAddParent", "cannotModifyViewersCanCopyContent", "appNotAuthorizedToFile",
    ]

    /// 理由のどれかが権限系か(先頭だけでなく全部見る)。
    static func isPermissionFailure(_ reasons: [String]) -> Bool {
        reasons.contains(where: permissionReasons.contains)
    }

    // MARK: - 転送

    /// 小さな文書は multipart で 1 回、録音は resumable で送る。
    private func transfer(
        _ upload: DriveUpload, metadata: [String: Any], fileID: String?, extraQuery: String
    ) async throws -> DriveFileRef {
        let mime: String
        switch upload.kind {
        case .document: mime = Self.markdownMime
        case .raw(let type): mime = type
        }
        let metadataBody = try JSONSerialization.data(withJSONObject: metadata)
        let target = fileID.map { "/files/\($0)" } ?? "/files"
        let method = fileID == nil ? "POST" : "PATCH"
        let fields = "id,trashed"
        switch upload.kind {
        case .document:
            let content: Data
            do { content = try Data(contentsOf: upload.fileURL) } catch {
                throw DriveError.localFile(error.localizedDescription)
            }
            let boundary = "hearcat-\(UUID().uuidString)"
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
            body.append(metadataBody)
            body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n--\(boundary)--".utf8))
            let data = try await send(
                url: URL(string: Self.uploadBase + target + "?uploadType=multipart&fields=\(fields)\(extraQuery)")!,
                method: method, body: body,
                contentType: "multipart/related; boundary=\(boundary)")
            return try Self.fileRef(from: data)
        case .raw:
            // 開始の呼び出しでセッション URI をもらい、そこへ本体をファイルから流す。
            // 開始の時点ではまだファイルができていないので、通信断でやり直しても二重にならない。
            // セッション URI が失効したら、開始からやり直す。
            var restarts = 0
            while true {
                let (_, headers) = try await sendRaw(
                    url: URL(string: Self.uploadBase + target + "?uploadType=resumable&fields=\(fields)\(extraQuery)")!,
                    method: method, body: metadataBody,
                    contentType: "application/json; charset=UTF-8",
                    extraHeaders: ["X-Upload-Content-Type": mime], retryOnNetworkError: true)
                guard let location = headers["Location"] ?? headers["location"],
                    let sessionURL = URL(string: location)
                else { throw DriveError.http(status: 0, message: "Google Drive から送り先を受け取れませんでした") }
                do {
                    let data = try await uploadFile(upload.fileURL, to: sessionURL, mime: mime)
                    return try Self.fileRef(from: data)
                } catch is UploadSessionExpired {
                    // 失効の前に完了していた可能性がある。作成なら同名を探し、あればそれを使う。
                    if fileID == nil, let parent = (metadata["parents"] as? [String])?.first,
                        let found = try await findFile(name: upload.name, parentID: parent)
                    {
                        return DriveFileRef(id: found, trashed: false)
                    }
                    restarts += 1
                    if restarts > 2 { throw DriveError.network("録音を送れませんでした。もう一度書き出してください") }
                }
            }
        }
    }

    /// 1 回の PUT の結果。
    private enum PutResult {
        case complete(Data)
        /// 受理済みの位置(次に送るバイトの位置)。
        case incomplete(next: Int)
    }

    /// 本体を送る。通信断・5xx・利用制限のときは、受理済みの位置を照会して続きから再開する。
    private func uploadFile(_ file: URL, to url: URL, mime: String) async throws -> Data {
        let total: Int
        do {
            total = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        } catch {
            throw DriveError.localFile(error.localizedDescription)
        }
        // nil は「まず受理済みの位置を照会する」。
        var offset: Int? = 0
        var attempt = 0
        // 受理済みの位置の最大値。通信断の回数(attempt)は位置が進むたびに戻し、
        // 照会しても進まない回数は別に数えて、無進捗のまま続けないようにする。
        var furthest = -1
        var stalls = 0
        while true {
            do {
                switch try await put(file, to: url, mime: mime, from: offset, total: total) {
                case .complete(let data):
                    return data
                case .incomplete(let next):
                    guard next < total else {
                        // 全部届いたのに完了と返らない。照会し直す。
                        stalls += 1
                        if stalls > 3 { throw DriveError.network("録音を最後まで送れませんでした") }
                        offset = nil
                        continue
                    }
                    if next > furthest {
                        furthest = next
                        attempt = 0
                    } else {
                        stalls += 1
                        if stalls > 3 { throw DriveError.network("録音の送信が先へ進みません") }
                        try await Task.sleep(for: .seconds(Double(stalls) * 2))
                    }
                    offset = next
                }
            } catch is UploadSessionExpired {
                throw UploadSessionExpired()
            } catch let error as GoogleOAuthError {
                throw Self.map(error)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DriveError {
                guard error.isTransient, attempt < 3 else { throw error }
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
                offset = nil
            } catch {
                // URLSession の通信断・タイムアウト。
                guard attempt < 3 else { throw DriveError.network(error.localizedDescription) }
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
                offset = nil
            }
        }
    }

    /// from が nil なら状態の照会(受理済みの位置を返す)、数値ならその位置から送る。
    private func put(_ file: URL, to url: URL, mime: String, from offset: Int?, total: Int) async throws
        -> PutResult
    {
        var refreshed = false
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue(
                "Bearer \(try await tokens.accessToken(forceRefresh: refreshed))",
                forHTTPHeaderField: "Authorization")
            let data: Data
            let response: URLResponse
            if let offset {
                request.setValue(mime, forHTTPHeaderField: "Content-Type")
                if offset == 0 {
                    (data, response) = try await session.upload(for: request, fromFile: file)
                } else {
                    request.setValue(
                        "bytes \(offset)-\(total - 1)/\(total)", forHTTPHeaderField: "Content-Range")
                    let whole: Data
                    do { whole = try Data(contentsOf: file, options: .alwaysMapped) } catch {
                        throw DriveError.localFile(error.localizedDescription)
                    }
                    // 送っている間にファイルが変わっていたら、続きは送れない。最初からやり直す。
                    guard whole.count == total, offset > 0, offset < total else {
                        throw UploadSessionExpired()
                    }
                    (data, response) = try await session.upload(
                        for: request, from: whole.subdata(in: offset..<total))
                }
            } else {
                request.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
                request.setValue("0", forHTTPHeaderField: "Content-Length")
                (data, response) = try await session.data(for: request, delegate: NoRedirectDelegate())
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) { return .complete(data) }
            if status == 308 {
                // Range: bytes=0-N は N まで受理済み。ヘッダーが無ければ何も届いていない。
                let range = http?.value(forHTTPHeaderField: "Range")
                let last = range?.split(separator: "-").last.flatMap { Int($0) }
                return .incomplete(next: last.map { $0 + 1 } ?? 0)
            }
            if status == 404 || status == 410 { throw UploadSessionExpired() }
            if status == 401 {
                if refreshed {
                    await tokens.invalidate()
                    throw DriveError.notSignedIn
                }
                refreshed = true
                continue
            }
            throw Self.error(status: status, data: data)
        }
    }

    // MARK: - 共通の送信

    private func send(
        path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil
    ) async throws -> Data {
        try await send(
            url: URL(string: Self.apiBase + path)!, method: method, body: body, contentType: contentType)
    }

    private func send(
        url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil
    ) async throws -> Data {
        try await sendRaw(url: url, method: method, body: body, contentType: contentType).data
    }

    /// 認証つきで送る。401 は更新したトークンで 1 回だけやり直し(それでも 401 なら鍵を捨てる)、
    /// 利用制限・5xx は少し待って 2 回まで再試行する。
    /// 通信断は、重複して作られる恐れのない呼び出し(作成の POST 以外)だけ 1 回やり直す。
    private func sendRaw(
        url: URL, method: String, body: Data?, contentType: String?,
        extraHeaders: [String: String] = [:], retryOnNetworkError: Bool? = nil
    ) async throws -> (data: Data, headers: [String: String]) {
        var refreshed = false
        var retries = 0
        let retryNetwork = retryOnNetworkError ?? (method != "POST")
        while true {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.httpBody = body
                if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
                for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
                request.setValue(
                    "Bearer \(try await tokens.accessToken(forceRefresh: refreshed))",
                    forHTTPHeaderField: "Authorization")
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if (200..<300).contains(status) {
                    var headers: [String: String] = [:]
                    for (key, value) in http?.allHeaderFields ?? [:] {
                        if let key = key as? String, let value = value as? String { headers[key] = value }
                    }
                    return (data, headers)
                }
                if status == 401 {
                    if refreshed {
                        await tokens.invalidate()
                        throw DriveError.notSignedIn
                    }
                    refreshed = true
                    continue
                }
                let failure = Self.error(status: status, data: data)
                if failure.isTransient, retries < 2 {
                    retries += 1
                    try await Task.sleep(for: .seconds(Double(retries) * 2))
                    continue
                }
                throw failure
            } catch let error as GoogleOAuthError {
                throw Self.map(error)
            } catch let error as DriveError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if retries < 1, retryNetwork {
                    retries += 1
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                throw DriveError.network(error.localizedDescription)
            }
        }
    }

    static func map(_ error: GoogleOAuthError) -> DriveError {
        switch error {
        case .reloginRequired, .notConfigured: .notSignedIn
        default: .network(error.localizedDescription)
        }
    }

    /// 利用制限を表す 403 の reason。
    static let rateLimitReasons: Set<String> = ["userRateLimitExceeded", "rateLimitExceeded"]

    static func error(status: Int, data: Data) -> DriveError {
        if status == 404 { return .notFound }
        if status == 401 { return .notSignedIn }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let body = json?["error"] as? [String: Any]
        let message = body?["message"] as? String ?? "HTTP \(status)"
        if status == 429 { return .rateLimited(message) }
        if status == 403 {
            let reasons = (body?["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
            if reasons.contains(where: rateLimitReasons.contains) { return .rateLimited(message) }
        }
        if status == 403 {
            let reasons = (body?["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
            return .forbidden(reasons: reasons, message: message)
        }
        return .http(status: status, message: message)
    }

    static func fileRef(from data: Data) throws -> DriveFileRef {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let id = json?["id"] as? String else {
            throw DriveError.http(status: 0, message: "Google Drive からの応答が正しくありません")
        }
        return DriveFileRef(id: id, trashed: json?["trashed"] as? Bool ?? false)
    }
}
