import Foundation

/// CLI 側からアプリのソケットへ1往復のリクエストを送る。
public enum IPCClient {
    public static func send(_ request: IPCRequest, socketPath: String = SessionStore.socketPath) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketFailed(errno) }
        defer { close(fd) }
        IPCSocket.disableSigPipe(on: fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw IPCError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count)))
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw IPCError.connectFailed(errno) }
        // アプリ側のハンドラは await の間ずっと応答しない。初回起動はマイクや音声認識の
        // 許可ダイアログを人が操作するまで待つし、停止は確定処理に十数秒かかることがある。
        // それでもアプリが固まって永久に返らない経路(過去に10分ハングした実績がある)は
        // 切り離したいので、それらより十分長い120秒で打ち切る。
        IPCSocket.setTimeouts(on: fd, seconds: 120)

        IPCSocket.writeMessage(request, to: fd)
        switch IPCSocket.readMessage(IPCResponse.self, from: fd) {
        case .success(let response): return response
        case .timedOut: throw IPCError.timedOut
        case .failed: throw IPCError.invalidResponse
        }
    }
}
