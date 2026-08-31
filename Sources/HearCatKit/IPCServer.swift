import Foundation

/// アプリ内で動く Unix ドメインソケットのサーバー。
/// CLI からの短命な接続(1行リクエスト → 1行レスポンス)だけを扱うため、
/// accept は専用キューのブロッキングループで受け、処理は Task に逃がす。
public final class IPCServer: @unchecked Sendable {
    private let socketPath: String
    private let handler: @Sendable (IPCRequest) async -> IPCResponse
    private let queue = DispatchQueue(label: "hearcat.ipc.accept")
    private var serverFD: Int32 = -1

    public init(socketPath: String, handler: @escaping @Sendable (IPCRequest) async -> IPCResponse) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // 前回の異常終了で残ったソケットファイルは bind を失敗させるため先に消す。
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketFailed(errno) }
        IPCSocket.disableSigPipe(on: fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw IPCError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count)))
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw IPCError.bindFailed(errno)
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw IPCError.listenFailed(errno)
        }

        serverFD = fd
        queue.async { [weak self] in self?.acceptLoop(serverFD: fd) }
    }

    public func stop() {
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop(serverFD: Int32) {
        while true {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                let code = errno
                if code == EINTR { continue }
                // stop() で listening fd が閉じられた場合。他スレッドから閉じられるため
                // serverFD プロパティを見るのではなく errno で判定する。
                if code == EBADF || code == EINVAL { return }
                errorLog("IPC の accept に失敗しました (errno: \(code))")
                usleep(100_000)
                continue
            }
            IPCSocket.disableSigPipe(on: clientFD)
            IPCSocket.setTimeouts(on: clientFD, seconds: 5)
            let handler = self.handler
            Task {
                let response: IPCResponse
                if let request = IPCSocket.readMessage(IPCRequest.self, from: clientFD) {
                    response = await handler(request)
                } else {
                    response = IPCResponse(ok: false, error: "リクエストを読み取れませんでした")
                }
                IPCSocket.writeMessage(response, to: clientFD)
                close(clientFD)
            }
        }
    }
}

public enum IPCError: LocalizedError {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case connectFailed(Int32)
    case pathTooLong
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .socketFailed(let code): return "socket の作成に失敗しました (errno: \(code))"
        case .bindFailed(let code): return "ソケットの bind に失敗しました (errno: \(code))"
        case .listenFailed(let code): return "ソケットの listen に失敗しました (errno: \(code))"
        case .connectFailed(let code): return "アプリに接続できません (errno: \(code))"
        case .pathTooLong: return "ソケットパスが長すぎます"
        case .invalidResponse: return "アプリからの応答を解釈できませんでした"
        }
    }
}

/// 改行区切り JSON の読み書き。サーバー/クライアントで共用する。
enum IPCSocket {
    /// 相手が先に閉じた fd への write は SIGPIPE でプロセスごと落とすため、
    /// signal(SIGPIPE, SIG_IGN) のようなプロセス全体への設定ではなく fd 単位で無効化する。
    static func disableSigPipe(on fd: Int32) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 改行を送らないクライアントに fd を握られ続けないよう、送受信に上限を設ける。
    static func setTimeouts(on fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func readMessage<T: Decodable>(_ type: T.Type, from fd: Int32) -> T? {
        var data = Data()
        var byte: UInt8 = 0
        // メッセージは高々数百バイト。1バイト読みでも実用上問題ない(接続は1往復で閉じる)。
        while data.count < 1_048_576 {
            let n = read(fd, &byte, 1)
            guard n == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { break }
            data.append(byte)
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func writeMessage<T: Encodable>(_ message: T, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { return }
                offset += n
            }
        }
    }
}
