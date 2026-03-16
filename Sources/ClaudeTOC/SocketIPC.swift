import Foundation

/// Message sent from hook invocations to the running instance
struct IPCMessage: Codable, Sendable {
    let transcriptPath: String
    let hookPid: Int32?
    let terminalBundleId: String?
    let terminalColumns: Int?
}

/// User-isolated socket path (macOS $TMPDIR includes per-user directory)
private let socketPath: String = {
    let tmpDir = NSTemporaryDirectory()
    return (tmpDir as NSString).appendingPathComponent("claude-toc.sock")
}()

/// Maximum bytes the server will read from a single client connection (64 KB)
private let maxReadBytes = 65_536

/// Read/write timeout for socket operations (seconds)
private let socketTimeout: Int = 5

/// Set SO_RCVTIMEO on a file descriptor
private func setReceiveTimeout(fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// Set SO_SNDTIMEO on a file descriptor
private func setSendTimeout(fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// Bind a sockaddr_un to the given path
private func makeUnixAddress() -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        socketPath.withCString { cstr in
            _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
        }
    }
    return addr
}

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

        var addr = makeUnixAddress()
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

        // Set timeouts to prevent hanging on misbehaving clients
        setReceiveTimeout(fd: clientFD, seconds: socketTimeout)
        setSendTimeout(fd: clientFD, seconds: socketTimeout)

        // Read data with size limit
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < maxReadBytes {
            let n = read(clientFD, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
        }

        // Send OK first, then process — avoids client blocking on read while we decode
        _ = "OK".withCString { write(clientFD, $0, 2) }
        close(clientFD)

        if let msg = try? JSONDecoder().decode(IPCMessage.self, from: data) {
            log("SocketServer: received session for \(msg.transcriptPath)")
            handler(msg)
        }
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

        // Set timeouts so we don't hang forever
        setReceiveTimeout(fd: fd, seconds: socketTimeout)
        setSendTimeout(fd: fd, seconds: socketTimeout)

        var addr = makeUnixAddress()
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
