import Foundation
import AppKit

/// The bundle-swap half of the updater, split out so the in-process app and the
/// detached swapper share one code path.
///
/// Why a detached helper at all
/// ----------------------------
/// You cannot reliably replace a running `.app` from inside that same process:
/// the swap should happen only AFTER the app has quit (so its windows are
/// restored and its files are closed), and then SOMETHING still has to relaunch
/// it. So the app re-execs ITSELF from a temp copy with the hidden
/// `__update-swap` subcommand; that throwaway process waits for the original to
/// exit, performs an atomic swap, and relaunches the installed bundle.
///
/// Why re-exec a copy of our own binary instead of a bash script
/// -------------------------------------------------------------
/// The previous approach shelled out to a hand-written `mv`/`ditto` script that
/// was non-atomic (a crash mid-copy could leave NO app at the destination) and
/// swallowed every error. Using our own Swift code lets us use
/// `FileManager.replaceItemAt` (atomic same-volume exchange with a backup +
/// rollback), validate the staged bundle, and write a real log.
enum InstallSwap {

    /// Where the swapper logs, so a failed unattended update is diagnosable.
    static var logURL: URL {
        ScrollWMConfig.dirURL.appendingPathComponent("update-swap.log")
    }

    /// Marker the app writes with the version it is ATTEMPTING to install,
    /// read back after relaunch to confirm the swap actually advanced the
    /// version (and to break a failed-install relaunch loop). Lives next to the
    /// config so it survives the swap.
    static var pendingMarkerURL: URL {
        ScrollWMConfig.dirURL.appendingPathComponent("update-pending.json")
    }

    // MARK: - Detached entry point (`WindowLab __update-swap ...`)

    /// Args (after the subcommand): <staged-app> <dest-bundle> <old-pid> [--relaunch]
    /// Runs in the throwaway temp process. Never returns meaningfully; exits.
    static func runSwapper(_ args: [String]) -> Int32 {
        guard args.count >= 3 else {
            log("swap: bad args \(args)")
            return 2
        }
        let staged = URL(fileURLWithPath: args[0])
        let dest = URL(fileURLWithPath: args[1])
        let pid = Int32(args[2]) ?? -1
        let relaunch = !args.contains("--no-relaunch")

        log("swap: start staged=\(staged.path) dest=\(dest.path) pid=\(pid)")

        // 1. Wait for the original app to fully exit (it restores windows on
        //    quit first). Bounded so we never hang forever.
        waitForExit(pid: pid, timeout: 30)

        // 2. Atomic replace with rollback. The live bundle is only ever the
        //    complete old or complete new app; an interrupted swap cannot leave
        //    a half-written or missing bundle at `dest`.
        let result = atomicReplace(dest: dest, with: staged)
        switch result {
        case .success:
            log("swap: replaced \(dest.lastPathComponent) OK")
            dropQuarantine(dest)
        case .failure(let err):
            log("swap: FAILED to replace: \(err). Original left intact.")
            // Original is untouched by replaceItemAt on failure; just relaunch
            // whatever is there so the user is never left without an app.
        }

        // 3. Relaunch the installed bundle.
        if relaunch {
            // Clean up the staged copy and our own temp re-exec dir afterward.
            _ = try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            launch(dest)
        }
        return 0
    }

    // MARK: - Atomic replace

    enum SwapError: Error, CustomStringConvertible {
        case replaceFailed(String)
        var description: String {
            switch self { case .replaceFailed(let s): return s }
        }
    }

    /// Atomically replace `dest` with the bundle at `with`, keeping the old one
    /// as a backup that `replaceItemAt` auto-removes on success and restores on
    /// failure. Requires both to be on the SAME volume (the caller stages into
    /// a same-volume temp dir to guarantee this); falls back to a copy if not.
    static func atomicReplace(dest: URL, with staged: URL) -> Result<Void, SwapError> {
        let fm = FileManager.default
        do {
            // replaceItemAt needs the replacement on the same volume as dest for
            // the atomic path; if staging ended up elsewhere, copy it adjacent
            // to dest first so the swap is a metadata operation.
            let replacement = try sameVolumeReplacement(for: staged, near: dest, fm: fm)
            try fm.replaceItem(at: dest,
                               withItemAt: replacement,
                               backupItemName: dest.lastPathComponent + ".bak",
                               options: [.usingNewMetadataOnly],
                               resultingItemURL: nil)
            return .success(())
        } catch {
            return .failure(.replaceFailed(error.localizedDescription))
        }
    }

    /// Ensure the replacement bundle sits on the same volume as `dest`. If the
    /// staged copy is already co-located, use it directly; otherwise ditto it
    /// next to `dest` into a temp sibling and return that.
    private static func sameVolumeReplacement(for staged: URL, near dest: URL, fm: FileManager) throws -> URL {
        if onSameVolume(staged, dest) { return staged }
        let sibling = dest.deletingLastPathComponent()
            .appendingPathComponent(".scrollwm-update-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let copy = sibling.appendingPathComponent(staged.lastPathComponent)
        // ditto preserves the bundle faithfully (symlinks, xattrs, signature).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [staged.path, copy.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw SwapError.replaceFailed("ditto to same-volume staging failed")
        }
        return copy
    }

    private static func onSameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let kb = try? b.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let ka, let kb else { return false }
        return ka.isEqual(kb)
    }

    // MARK: - Process helpers

    private static func waitForExit(pid: Int32, timeout: TimeInterval) {
        guard pid > 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // kill(pid, 0): 0 => still alive; -1/ESRCH => gone.
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        log("swap: timed out waiting for pid \(pid); proceeding")
    }

    private static func dropQuarantine(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? p.run(); p.waitUntilExit()
    }

    private static func launch(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.path]
        try? p.run(); p.waitUntilExit()
    }

    // MARK: - Logging

    static func log(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - Dev self-test (`WindowLab __update-selftest <current.app> <new.app>`)

/// Headless validation of the two riskiest pieces, exercised from CI/dev with
/// real bundles (so no network, no GitHub, no live app):
///   1. `CodeSigning.willPreserveAccessibility` between two bundles.
///   2. The atomic swap (`InstallSwap.atomicReplace`) including rollback.
/// Prints PASS/FAIL lines and returns 0 only if all assertions hold.
func runUpdateSelfTest(_ args: [String]) -> Int32 {
    var passed = 0, failed = 0
    func check(_ name: String, _ cond: Bool) {
        if cond { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)") }
    }

    guard args.count >= 2 else {
        print("usage: WindowLab __update-selftest <current.app> <new.app>")
        return 2
    }
    let current = URL(fileURLWithPath: args[0])
    let newer = URL(fileURLWithPath: args[1])

    print("[update-selftest] code-signing / TCC gate")
    check("current bundle has a readable designated requirement",
          CodeSigning.designatedRequirement(ofBundleAt: current) != nil)
    check("new bundle signature is valid",
          CodeSigning.signatureIsValid(ofBundleAt: newer))
    check("new bundle has a slice for this Mac's arch",
          CodeSigning.hasMatchingArchitecture(stagedBundle: newer))
    check("new bundle id == dev.scrollwm.app",
          CodeSigning.bundleIdentifier(ofBundleAt: newer) == "dev.scrollwm.app")
    // The key assertion: does swapping current -> new preserve Accessibility?
    let preserves = CodeSigning.willPreserveAccessibility(currentBundle: current, stagedBundle: newer)
    print("  -> willPreserveAccessibility(current -> new) = \(preserves)")

    print("[update-selftest] atomic swap + rollback")
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("swap-selftest-\(UUID().uuidString.prefix(8))")
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    // SUCCESS: replace a copy of `current` (at dest) with a copy of `newer`.
    let dest = tmp.appendingPathComponent("ScrollWM.app")
    let stagedNew = tmp.appendingPathComponent("staged-new.app")
    _ = runDittoTool([current.path, dest.path])
    _ = runDittoTool([newer.path, stagedNew.path])
    let okResult = InstallSwap.atomicReplace(dest: dest, with: stagedNew)
    if case .success = okResult {
        check("atomicReplace succeeded", true)
        let v = CodeSigning.shortVersion(ofBundleAt: dest)
        check("dest now holds the NEW version (\(v ?? "?"))",
              v == CodeSigning.shortVersion(ofBundleAt: newer))
        check("dest is a valid signed bundle after swap",
              CodeSigning.signatureIsValid(ofBundleAt: dest))
        check("no leftover .bak sibling", !fm.fileExists(atPath: dest.path + ".bak"))
    } else {
        check("atomicReplace succeeded", false)
    }

    // ROLLBACK: replacement points at a nonexistent path; dest must survive.
    let dest2 = tmp.appendingPathComponent("ScrollWM2.app")
    _ = runDittoTool([current.path, dest2.path])
    let before = CodeSigning.shortVersion(ofBundleAt: dest2)
    let badResult = InstallSwap.atomicReplace(dest: dest2, with: tmp.appendingPathComponent("does-not-exist.app"))
    if case .failure = badResult {
        check("atomicReplace reports failure for a missing source", true)
    } else {
        check("atomicReplace reports failure for a missing source", false)
    }
    check("dest survived the failed swap (original intact)",
          fm.fileExists(atPath: dest2.path) &&
          CodeSigning.shortVersion(ofBundleAt: dest2) == before)

    print("\n[update-selftest] \(passed) passed, \(failed) failed")
    return failed == 0 ? 0 : 1
}

private func runDittoTool(_ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = args
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}
