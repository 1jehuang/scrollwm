import Foundation

// ScrollWM control plane.
//
// The running ScrollWM app (the menu-bar agent started by `run`) listens on a
// Unix domain socket. A short-lived CLI process (`scrollwm <verb>`) connects,
// sends one command line, reads one response line, and exits. This is how you
// drive the LIVE app from a shell or script (arrange, focus, resize, status…)
// without hotkeys or the menu.
//
// Why a Unix socket (not a port / Distributed Notifications / URL scheme):
//   - No network exposure, no entitlement, filesystem-permission scoped to the
//     user (0700 dir). Fits the "one permission, no surprises" contract.
//   - Request/response is synchronous, so the CLI can print real results
//     (e.g. `status` JSON) and a meaningful exit code.
//
// Threading: the server accepts on a background thread but every command is
// executed on the MAIN thread (AX + AppKit are main-thread only), via
// DispatchQueue.main.sync, then the response is written back.

enum ControlSocket {
    /// Deterministic path both the app and the CLI compute identically.
    /// Lives next to the config/restore files under Application Support.
    /// `SCROLLWM_CONTROL_SOCK` overrides it (used by sandbox mode so the CLI
    /// can drive disposable windows without touching the real session).
    static func path() -> String {
        if let override = ProcessInfo.processInfo.environment["SCROLLWM_CONTROL_SOCK"],
           !override.isEmpty {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ScrollWM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("control.sock").path
    }
}

/// Server side: bound and listened to by the running controller.
final class ControlServer {
    private let handler: (String) -> String
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private let socketPath: String

    /// `handler` is always invoked on the main thread.
    init(socketPath: String = ControlSocket.path(), handler: @escaping (String) -> String) {
        self.socketPath = socketPath
        self.handler = handler
    }

    /// Bind + listen, then accept connections on a background thread.
    /// Returns false (and logs) if the socket can't be created; the app keeps
    /// running without the control plane rather than failing to launch.
    @discardableResult
    func start() -> Bool {
        unlink(socketPath) // clear any stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { perror("scrollwm control: socket"); return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            FileHandle.standardError.write("scrollwm control: socket path too long: \(socketPath)\n".data(using: .utf8)!)
            close(fd)
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindOK == 0 else { perror("scrollwm control: bind"); close(fd); return false }

        // Only the owner may talk to the socket.
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else { perror("scrollwm control: listen"); close(fd); return false }

        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "scrollwm.control"
        t.stackSize = 1 << 20
        t.start()
        thread = t
        return true
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            handle(client: client)
            close(client)
        }
    }

    private func handle(client fd: Int32) {
        // Read one request (commands are tiny; a single read is plenty, but we
        // loop until newline/EOF to be safe).
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(0x0A) || data.count > 64 * 1024 { break }
        }
        let line = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Execute on the main thread (AX/AppKit), capture the reply.
        var reply = ""
        if Thread.isMainThread {
            reply = handler(line)
        } else {
            DispatchQueue.main.sync { reply = handler(line) }
        }
        if !reply.hasSuffix("\n") { reply += "\n" }

        let out = Array(reply.utf8)
        var off = 0
        while off < out.count {
            let n = out[off...].withUnsafeBytes { write(fd, $0.baseAddress, out.count - off) }
            if n <= 0 { break }
            off += n
        }
    }
}

/// Client side: used by the `scrollwm` CLI verbs to talk to a running app.
enum ControlClient {
    enum Failure: Error { case notRunning, io(String) }

    /// Connect, send `command`, return the trimmed response.
    static func send(_ command: String, socketPath: String = ControlSocket.path()) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io("socket()") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Failure.io("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if connected != 0 {
            // ENOENT (no socket file) or ECONNREFUSED (stale socket) => not running.
            if errno == ENOENT || errno == ECONNREFUSED { throw Failure.notRunning }
            throw Failure.io("connect(): \(String(cString: strerror(errno)))")
        }

        var msg = command
        if !msg.hasSuffix("\n") { msg += "\n" }
        let bytes = Array(msg.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, bytes.count - off) }
            if n <= 0 { throw Failure.io("write()") }
            off += n
        }
        // Half-close our write side so the server sees EOF if it reads to end.
        shutdown(fd, SHUT_WR)

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { throw Failure.io("read()") }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
