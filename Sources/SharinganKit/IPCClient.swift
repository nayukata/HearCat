import Foundation

/// CLI 側からアプリのソケットへ1往復のリクエストを送る。
public enum IPCClient {
    public static func send(_ request: IPCRequest, socketPath: String = SessionStore.socketPath) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketFailed(errno) }
        defer { close(fd) }

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

        IPCSocket.writeMessage(request, to: fd)
        guard let response = IPCSocket.readMessage(IPCResponse.self, from: fd) else {
            throw IPCError.invalidResponse
        }
        return response
    }
}
