import Foundation

/// Message sent from hook invocations to the running instance
struct IPCMessage: Codable, Sendable {
    let transcriptPath: String
    let hookPid: Int32?
}

private let socketPath = "/tmp/claude-toc.sock"

/// Listens on a Unix domain socket for incoming IPCMessages
class SocketServer {
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let handler: @Sendable (IPCMessage) -> Void

    init(handler: @escaping @Sendable (IPCMessage) -> Void) {
        self.handler = handler
    }

    func start() {
        unlink(socketPath)

        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            log("SocketServer: failed to create socket")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fileDescriptor, $0, addrLen)
            }
        }
        guard bindResult == 0 else {
            log("SocketServer: bind failed: \(errno)")
            return
        }

        guard listen(fileDescriptor, 5) == 0 else {
            log("SocketServer: listen failed")
            return
        }

        source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: .global())
        source?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 { close(fd) }
            unlink(socketPath)
        }
        source?.resume()
        log("SocketServer: listening on \(socketPath)")
    }

    private func acceptConnection() {
        let clientFD = accept(fileDescriptor, nil, nil)
        guard clientFD >= 0 else { return }

        // Read all data then close
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(clientFD, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
        }

        if let msg = try? JSONDecoder().decode(IPCMessage.self, from: data) {
            log("SocketServer: received session for \(msg.transcriptPath)")
            handler(msg)
        }
        // Send OK
        _ = "OK".withCString { write(clientFD, $0, 2) }
        close(clientFD)
    }

    func stop() {
        source?.cancel()
    }

    deinit {
        stop()
    }
}

/// One-shot client: sends an IPCMessage to the running instance
enum SocketClient {
    static func send(message: IPCMessage) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, addrLen)
            }
        }
        guard connectResult == 0 else { return false }

        guard let data = try? JSONEncoder().encode(message) else { return false }
        let written = data.withUnsafeBytes { buf in
            write(fd, buf.baseAddress!, buf.count)
        }
        shutdown(fd, SHUT_WR)

        // Read OK
        var resp = [UInt8](repeating: 0, count: 16)
        _ = read(fd, &resp, resp.count)

        return written == data.count
    }
}
