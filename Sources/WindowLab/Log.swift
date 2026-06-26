import Foundation
import os

/// Durable, low-overhead application logging for ScrollWM.
///
/// Why this exists
/// ---------------
/// Historically ScrollWM only ever `print()`ed to stdout/stderr, so once the
/// menu-bar agent was running as `~/Applications/ScrollWM.app` its diagnostics
/// went nowhere: a crash or a misbehaving arrange left no trail except a macOS
/// `.ips` report. This gives us a real, on-disk, rotating log plus the unified
/// system log, so "what was the app doing when X happened?" is answerable after
/// the fact.
///
/// Two sinks, always in sync:
///   1. **Unified log** (`os.Logger`, subsystem `dev.scrollwm.app`). Visible in
///      Console.app and via `log show --predicate 'subsystem == "dev.scrollwm.app"'`.
///      Free, structured, and survives even if the file sink is unavailable.
///   2. **Rotating file** at `~/Library/Logs/ScrollWM/scrollwm.log` (the idiomatic
///      macOS location; shows up under Console.app → Log Reports). Capped in
///      size with one rolled-over backup so it never grows unbounded.
///
/// Console behavior is preserved: `info` still echoes to stdout and
/// `warn`/`error` still echo to stderr, so anyone watching the terminal sees the
/// same lines they always did — they are just durable now too.
///
/// Safety / test isolation
/// -----------------------
/// File logging is automatically suppressed whenever a headless test backend is
/// installed (`AXSource.backend != nil`), so the suite never writes to the real
/// user log. The unified-log + console echo still happen (cheap, harmless), and
/// `Log.fileLoggingEnabled = false` can force-disable the file sink outright.
enum Log {

    enum Level: String {
        case debug = "DBG"
        case info  = "INF"
        case warn  = "WRN"
        case error = "ERR"

        var osType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info:  return .info
            case .warn:  return .default   // unified log has no "warn"; default is visible
            case .error: return .error
            }
        }
    }

    // MARK: - Configuration

    /// Master switch for the on-disk file sink. The unified-log + console echo
    /// are independent of this. Tests can force it off; it is also implicitly
    /// off whenever a sim backend is installed (see `fileSinkActive`).
    static var fileLoggingEnabled = true

    /// Emit `debug` lines? Off by default to keep the log readable; flip on with
    /// the `SCROLLWM_DEBUG` env var or by setting this directly.
    static var debugEnabled: Bool =
        ProcessInfo.processInfo.environment["SCROLLWM_DEBUG"] == "1"

    /// Rotate when the live file passes this many bytes (keeps 1 backup).
    static let maxFileBytes: UInt64 = 2 * 1024 * 1024   // 2 MB

    /// Subdirectory under `~/Library/Logs`. Redirected for sandbox mode so the
    /// sandbox can never append to (or rotate) the real session's log — mirrors
    /// `RestoreStore.subdirectory`.
    static var subdirectory = "ScrollWM"

    // MARK: - Locations

    /// `~/Library/Logs/<subdirectory>`, created on demand.
    static var directory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var fileURL: URL { directory.appendingPathComponent("scrollwm.log") }
    static var rolledFileURL: URL { directory.appendingPathComponent("scrollwm.log.1") }

    // MARK: - Internals

    private static let osLog = os.Logger(subsystem: "dev.scrollwm.app", category: "app")

    /// All file I/O is serialized here so concurrent loggers never interleave a
    /// half-written line or race the rotation.
    private static let queue = DispatchQueue(label: "dev.scrollwm.log")
    private static var handle: FileHandle?
    private static var openedPath: String?

    /// The file sink is active only when explicitly enabled AND no headless test
    /// backend is installed (so the suite never touches the user's real log).
    private static var fileSinkActive: Bool {
        fileLoggingEnabled && AXSource.backend == nil
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Public API

    static func debug(_ message: @autoclosure () -> String, _ tag: String? = nil) {
        guard debugEnabled else { return }
        emit(.debug, message(), tag)
    }
    static func info(_ message: @autoclosure () -> String, _ tag: String? = nil) {
        emit(.info, message(), tag)
    }
    static func warn(_ message: @autoclosure () -> String, _ tag: String? = nil) {
        emit(.warn, message(), tag)
    }
    static func error(_ message: @autoclosure () -> String, _ tag: String? = nil) {
        emit(.error, message(), tag)
    }

    /// Install process-wide crash logging: an uncaught-Obj-C-exception handler
    /// (this is exactly what bit us with the tutorial `objectAtIndex:` crash —
    /// it would now be captured WITH a backtrace before the process dies) plus
    /// fatal-signal handlers that drop a marker line and then re-raise the
    /// default handler so the OS `.ips` report is still produced. Idempotent.
    static func installCrashHandlers() {
        guard fileSinkActive else { return }
        guard !crashHandlersInstalled else { return }
        crashHandlersInstalled = true

        NSSetUncaughtExceptionHandler { exc in
            let frames = exc.callStackSymbols.joined(separator: "\n    ")
            Log.error(
                "UNCAUGHT EXCEPTION \(exc.name.rawValue): \(exc.reason ?? "(no reason)")\n    "
                + frames, "crash")
            Log.flush()
        }

        for sig in [SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGSEGV, SIGFPE] {
            signal(sig, Log.handleFatalSignal)
        }
    }

    /// Block until any queued writes have hit disk. Cheap; used on the crash and
    /// shutdown paths so the last lines aren't lost.
    static func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    // MARK: - Emit

    private static func emit(_ level: Level, _ message: String, _ tag: String?) {
        let tagPart = tag.map { "[\($0)] " } ?? ""

        // 1. Unified log (always).
        osLog.log(level: level.osType, "\(tagPart + message, privacy: .public)")

        // 2. Console echo, preserving the historical stream split.
        let consoleLine = tagPart + message + "\n"
        switch level {
        case .info, .debug:
            FileHandle.standardOutput.write(Data(consoleLine.utf8))
        case .warn, .error:
            FileHandle.standardError.write(Data(consoleLine.utf8))
        }

        // 3. Durable file (when active).
        guard fileSinkActive else { return }
        let stamp = timestampFormatter.string(from: Date())
        let fileLine = "\(stamp) \(level.rawValue) \(tagPart)\(message)\n"
        let data = Data(fileLine.utf8)
        queue.async {
            writeToFileLocked(data)
        }
    }

    /// Must run on `queue`.
    private static func writeToFileLocked(_ data: Data) {
        let path = fileURL.path
        if handle == nil || openedPath != path {
            try? handle?.close()
            handle = openHandleLocked(at: fileURL)
            openedPath = path
        }
        guard let h = handle else { return }
        h.write(data)
        // Rotate after the write so the current line is never split across files.
        if let size = try? h.seekToEnd(), size > maxFileBytes {
            try? h.close()
            handle = nil
            openedPath = nil
            try? FileManager.default.removeItem(at: rolledFileURL)
            try? FileManager.default.moveItem(at: fileURL, to: rolledFileURL)
        }
    }

    /// Open (creating if needed) `url` for appending. Must run on `queue`.
    private static func openHandleLocked(at url: URL) -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            _ = directory   // ensure the dir exists
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        return h
    }

    // MARK: - Crash signal handling

    private static var crashHandlersInstalled = false

    /// Async-signal-safe-ish fatal handler: write a fixed marker via raw `write`
    /// (no allocation), then restore + re-raise the default disposition so macOS
    /// still generates the crash report. We intentionally do NOT symbolicate here
    /// — that belongs to the uncaught-exception handler and the `.ips`.
    private static let handleFatalSignal: @convention(c) (Int32) -> Void = { sig in
        let prefix = "\n*** ScrollWM fatal signal "
        prefix.withCString { _ = write(2, $0, strlen($0)) }
        var n = sig
        var digits = [CChar](repeating: 0, count: 4)
        var i = 3
        if n == 0 { digits[i] = 48; i -= 1 }       // '0'
        while n > 0 && i >= 0 { digits[i] = CChar(48 + (n % 10)); n /= 10; i -= 1 }
        digits.withUnsafeBufferPointer { buf in
            _ = write(2, buf.baseAddress!.advanced(by: i + 1), 3 - i)
        }
        let suffix = " ***\n"
        suffix.withCString { _ = write(2, $0, strlen($0)) }

        // Best-effort: also drop a marker into the log file fd if we hold one.
        if let h = handle {
            let line = "\nFATAL SIGNAL \(sig)\n"
            try? h.write(contentsOf: Data(line.utf8))
            try? h.synchronize()
        }

        signal(sig, SIG_DFL)
        raise(sig)
    }
}

// MARK: - `scrollwm logs` CLI

/// `scrollwm logs [--path | --tail [N] | --follow | --clear]`
///   (default)     print the last 50 lines of the log
///   --path        print the log file path only (for piping)
///   --tail [N]    print the last N lines (default 50)
///   --follow, -f  stream new lines as they are written (Ctrl-C to stop)
///   --clear       truncate the log file
/// Runs locally; no socket / running app required.
func runLogsCLI(_ args: [String]) -> Int32 {
    let url = Log.fileURL

    if args.contains("--path") {
        print(url.path)
        return 0
    }

    if args.contains("--clear") {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: Log.rolledFileURL)
        print("cleared \(url.path)")
        return 0
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write("scrollwm: no log yet at \(url.path)\n".data(using: .utf8)!)
        return 0
    }

    if args.contains("--follow") || args.contains("-f") {
        return followLog(url)
    }

    // Default / --tail N: print the last N lines (concatenating the rolled file
    // first so a recent rotation doesn't hide history).
    let n = tailCount(args)
    var combined = ""
    if let rolled = try? String(contentsOf: Log.rolledFileURL, encoding: .utf8) { combined += rolled }
    if let live = try? String(contentsOf: url, encoding: .utf8) { combined += live }
    let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
    let tail = lines.suffix(n).joined(separator: "\n")
    print(tail)
    return 0
}

private func tailCount(_ args: [String]) -> Int {
    if let i = args.firstIndex(of: "--tail"), args.indices.contains(i + 1), let n = Int(args[i + 1]) {
        return n
    }
    return 50
}

/// `tail -f`-style follow: print existing tail, then poll for appended bytes.
private func followLog(_ url: URL) -> Int32 {
    guard let h = try? FileHandle(forReadingFrom: url) else {
        FileHandle.standardError.write("scrollwm: cannot open \(url.path)\n".data(using: .utf8)!)
        return 1
    }
    // Seek near the end so we show the recent tail, then follow.
    let size = (try? h.seekToEnd()) ?? 0
    let back: UInt64 = 4096
    try? h.seek(toOffset: size > back ? size - back : 0)
    if let initial = try? h.readToEnd(), let s = String(data: initial, encoding: .utf8) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }
    while true {
        if let chunk = try? h.readToEnd(), !chunk.isEmpty {
            FileHandle.standardOutput.write(chunk)
        } else {
            Thread.sleep(forTimeInterval: 0.4)
        }
    }
}
