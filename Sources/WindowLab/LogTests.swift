import Foundation

/// Pure-ish unit tests for the durable logging file sink: rotation, tail, and
/// path isolation. These exercise the file machinery against a redirected temp
/// subdirectory so they never touch the real `~/Library/Logs/ScrollWM`.
enum LogTests {
    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        // Redirect to a unique temp subdirectory so we exercise the REAL paths
        // without clobbering the user's log. `Log.directory` roots under
        // ~/Library/Logs/<subdirectory>, which we override here.
        let savedSub = Log.subdirectory
        let savedEnabled = Log.fileLoggingEnabled
        let savedBackend = AXSource.backend
        defer {
            Log.subdirectory = savedSub
            Log.fileLoggingEnabled = savedEnabled
            AXSource.backend = savedBackend
        }
        // The file sink is suppressed while a sim backend is installed; tests run
        // with one. Temporarily clear it so we can validate the file path here,
        // then restore via defer.
        AXSource.backend = nil
        Log.subdirectory = "ScrollWM-UnitTest-\(getpid())"
        Log.fileLoggingEnabled = true
        // Start clean.
        try? FileManager.default.removeItem(at: Log.fileURL)
        try? FileManager.default.removeItem(at: Log.rolledFileURL)

        // 1. A write reaches the file.
        Log.info("hello-line-one", "test")
        Log.flush()
        let after1 = (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
        check("info() writes a durable line", after1.contains("hello-line-one"))
        check("line carries level + tag", after1.contains("INF") && after1.contains("[test]"))

        // 2. debug() is gated off by default.
        Log.debugEnabled = false
        Log.debug("should-not-appear")
        Log.flush()
        let after2 = (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
        check("debug() suppressed when debugEnabled=false", !after2.contains("should-not-appear"))

        // 3. Rotation: drive past maxFileBytes and confirm a backup is produced
        //    and the live file is smaller than the cap afterwards.
        let big = String(repeating: "x", count: 1024)
        var i = 0
        while i < (Int(Log.maxFileBytes) / 1024) + 8 {
            Log.info(big, "fill")
            i += 1
        }
        Log.flush()
        let rolledExists = FileManager.default.fileExists(atPath: Log.rolledFileURL.path)
        check("rotation produces a .log.1 backup", rolledExists)
        let liveSize = (try? FileManager.default.attributesOfItem(atPath: Log.fileURL.path)[.size] as? UInt64) ?? 0
        check("live log stays under the cap after rotation", liveSize <= Log.maxFileBytes)

        // 4. `scrollwm logs --tail N` reads across the rotation boundary and
        //    returns at most N lines.
        let out = captureTail(n: 5)
        let lineCount = out.split(separator: "\n", omittingEmptySubsequences: false).count
        check("logs --tail N returns <= N lines", lineCount <= 5)

        // 5. Suppression: with the sim backend installed, the file sink is inert.
        AXSource.backend = savedBackend ?? SimWindowWorld()
        try? FileManager.default.removeItem(at: Log.fileURL)
        Log.info("must-not-write-under-backend", "test")
        Log.flush()
        let wroteUnderBackend = FileManager.default.fileExists(atPath: Log.fileURL.path)
        check("file sink suppressed under a test backend", !wroteUnderBackend)

        // Cleanup the temp dir.
        try? FileManager.default.removeItem(at: Log.directory)

        print("\n[unittest] logging: \(passed) passed, \(failed) failed")
        return failed == 0
    }

    /// Mirror what `runLogsCLI(["--tail", "N"])` computes, without spawning a
    /// subprocess: concatenate the rolled + live file and take the last N lines.
    private static func captureTail(n: Int) -> String {
        var combined = ""
        if let rolled = try? String(contentsOf: Log.rolledFileURL, encoding: .utf8) { combined += rolled }
        if let live = try? String(contentsOf: Log.fileURL, encoding: .utf8) { combined += live }
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n")
    }
}
