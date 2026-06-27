import Foundation
import AppKit
import CryptoKit

/// In-app updater: keeps an installed ScrollWM.app current with GitHub Releases.
///
/// Cutting a release (`scripts/release.sh --publish`, or the tag-triggered CI in
/// `.github/workflows/release.yml`) uploads `ScrollWM-<ver>.zip` + a
/// `SHA256SUMS.txt` to a `v<ver>` GitHub Release. This type lets the running app
/// notice that, tell the user, and (optionally) download + verify + swap itself
/// in place and relaunch — so users actually GET new releases instead of being
/// stuck on whatever they first installed.
///
/// Design:
///   - The "is there an update, and which asset?" logic is PURE
///     (`parseRelease`, `decideUpdate`, `expectedSHA256`) so it is unit-tested
///     with no network (`WindowLab unittest`).
///   - The network + install side effects live in instance methods that hop to
///     the main thread for their UI/relaunch callbacks.
///   - Install is safe: download to a temp dir, verify SHA-256 against the
///     release's `SHA256SUMS.txt`, then a tiny detached shell script waits for
///     this process to exit (so windows are restored on quit first) before
///     swapping the bundle and relaunching. A `.bak` of the old bundle is kept
///     until the new one is in place.
///   - Only an installed `.app` bundle updates itself; the dev `WindowLab`
///     binary refuses to self-replace (it just reports what it found).
enum AppVersion {
    /// The running app's version. Prefers the bundle's
    /// `CFBundleShortVersionString` (set by `scripts/make-bundle.sh` from the
    /// `VERSION` file); falls back to a dev sentinel for the bare CLI binary.
    ///
    /// When launched through a SYMLINK to the bundle's executable (e.g. the
    /// Homebrew `scrollwm` shim at `/opt/homebrew/bin/scrollwm`), `Bundle.main`
    /// resolves to the symlink's directory, NOT the `.app`, so its
    /// `infoDictionary` is empty. In that case we resolve the executable's real
    /// path, find the enclosing `.app`, and read its Info.plist directly - so
    /// `scrollwm --version` reports the real version no matter how it was run.
    static var currentString: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.isEmpty {
            return v
        }
        if let v = versionFromResolvedBundle(), !v.isEmpty {
            return v
        }
        return "0.0.0-dev"
    }

    static var current: SemVer { SemVer(currentString) ?? SemVer("0.0.0-dev")! }

    /// Resolve the real executable (following symlinks), walk up to the
    /// enclosing `*.app`, and return its `CFBundleShortVersionString`, if any.
    private static func versionFromResolvedBundle() -> String? {
        let rawPath = Bundle.main.executableURL?.path
            ?? Bundle.main.executablePath
            ?? CommandLine.arguments.first
        guard let rawPath, !rawPath.isEmpty else { return nil }

        // Follow symlinks so a `/opt/homebrew/bin/scrollwm` shim lands inside
        // `…/ScrollWM.app/Contents/MacOS/ScrollWM`.
        let resolved = (rawPath as NSString).resolvingSymlinksInPath
        var url = URL(fileURLWithPath: resolved)

        // Walk up from the executable looking for the `.app` bundle root.
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" {
                return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

/// One published release, distilled to what the updater needs.
struct ReleaseInfo: Equatable {
    let version: SemVer
    let tagName: String          // e.g. "v0.1.2"
    let htmlURL: String          // release page (for "View notes")
    let notes: String            // release body (markdown)
    let isPrerelease: Bool
    let zipURL: String           // browser_download_url of ScrollWM-<ver>.zip
    let zipName: String          // e.g. "ScrollWM-0.1.2.zip"
    let sha256SumsURL: String?   // browser_download_url of SHA256SUMS.txt, if any
}

/// What an update check found.
enum UpdateCheckResult: Equatable {
    case upToDate(current: SemVer)
    case updateAvailable(ReleaseInfo, current: SemVer)
    case noUsableAsset(ReleaseInfo)   // newer tag exists but no .zip asset yet
}

enum UpdateError: LocalizedError {
    case network(String)
    case badResponse(String)
    case noRelease
    case noZipAsset
    case downloadFailed(String)
    case checksumMismatch(expected: String, got: String)
    case extractFailed(String)
    case notInstalledBundle
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .network(let s):          return "network error: \(s)"
        case .badResponse(let s):      return "bad response from GitHub: \(s)"
        case .noRelease:               return "no published release found"
        case .noZipAsset:              return "release has no ScrollWM .zip asset yet"
        case .downloadFailed(let s):   return "download failed: \(s)"
        case .checksumMismatch(let e, let g):
            return "checksum mismatch (expected \(e.prefix(12))…, got \(g.prefix(12))…)"
        case .extractFailed(let s):    return "could not unpack the download: \(s)"
        case .notInstalledBundle:      return "not an installed .app bundle (dev binary won't self-replace)"
        case .installFailed(let s):    return "install failed: \(s)"
        }
    }
}

final class Updater {
    static let owner = "1jehuang"
    static let repo = "scrollwm"
    /// Allow pre-release (`-dev`, `-rc`) tags to be offered. Off by default so
    /// stable users only ever see stable releases.
    var allowPrerelease: Bool

    private let session: URLSession

    init(allowPrerelease: Bool = false) {
        self.allowPrerelease = allowPrerelease
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Pure logic (unit-tested)

    /// The GitHub releases API URL. We list releases (not just /latest) so we
    /// can honor `allowPrerelease` and skip drafts/assets-less tags ourselves.
    static var releasesAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20")!
    }

    /// Parse the GitHub `/releases` JSON array into `ReleaseInfo`, newest-first.
    /// Drafts and tags with an unparseable version are dropped. Pure: feed it
    /// canned JSON in tests.
    static func parseReleases(_ data: Data) -> [ReleaseInfo] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap(parseRelease(_:))
    }

    /// Parse one release object. Returns nil for drafts or unversioned tags.
    static func parseRelease(_ obj: [String: Any]) -> ReleaseInfo? {
        if (obj["draft"] as? Bool) == true { return nil }
        guard let tag = obj["tag_name"] as? String, let version = SemVer(tag) else { return nil }

        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        func url(forSuffix suffix: String, contains: String? = nil) -> (name: String, url: String)? {
            for a in assets {
                guard let name = a["name"] as? String,
                      let dl = a["browser_download_url"] as? String else { continue }
                if name.hasSuffix(suffix), contains == nil || name.contains(contains!) {
                    return (name, dl)
                }
            }
            return nil
        }
        guard let zip = url(forSuffix: ".zip", contains: "ScrollWM") else { return nil }
        let sums = url(forSuffix: "SHA256SUMS.txt") ?? url(forSuffix: ".txt", contains: "SHA256")

        return ReleaseInfo(
            version: version,
            tagName: tag,
            htmlURL: (obj["html_url"] as? String) ?? "",
            notes: (obj["body"] as? String) ?? "",
            isPrerelease: (obj["prerelease"] as? Bool) ?? version.isPrerelease,
            zipURL: zip.url,
            zipName: zip.name,
            sha256SumsURL: sums?.url
        )
    }

    /// Decide what an update check found, given the parsed releases and the
    /// running version. Pure so the policy is unit-testable.
    static func evaluate(releases: [ReleaseInfo], current: SemVer, allowPrerelease: Bool) -> UpdateCheckResult {
        let candidates = releases
            .filter { allowPrerelease || !$0.isPrerelease }
            .sorted { $0.version > $1.version }
        guard let newest = candidates.first else { return .upToDate(current: current) }
        if newest.version > current {
            return .updateAvailable(newest, current: current)
        }
        return .upToDate(current: current)
    }

    /// Pull the expected hex SHA-256 for `fileName` out of a `shasum`-style
    /// `SHA256SUMS.txt` (`<hex>␠␠<name>` per line). Pure.
    static func expectedSHA256(fromSums text: String, fileName: String) -> String? {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "*" })
                .map(String.init).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let name = (parts.last ?? "")
            let base = (name as NSString).lastPathComponent
            if base == fileName || name == fileName {
                return parts[0].lowercased()
            }
        }
        return nil
    }

    // MARK: - Network: check

    /// Fetch releases and report the result on the main thread.
    func check(completion: @escaping (Result<UpdateCheckResult, UpdateError>) -> Void) {
        var req = URLRequest(url: Self.releasesAPIURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ScrollWM/\(AppVersion.currentString)", forHTTPHeaderField: "User-Agent")
        let allowPre = allowPrerelease
        let current = AppVersion.current
        session.dataTask(with: req) { data, resp, err in
            let finish = { (r: Result<UpdateCheckResult, UpdateError>) in
                DispatchQueue.main.async { completion(r) }
            }
            if let err = err { return finish(.failure(.network(err.localizedDescription))) }
            guard let http = resp as? HTTPURLResponse else {
                return finish(.failure(.badResponse("no HTTP response")))
            }
            guard (200...299).contains(http.statusCode) else {
                return finish(.failure(.badResponse("HTTP \(http.statusCode)")))
            }
            guard let data = data else { return finish(.failure(.badResponse("empty body"))) }
            let releases = Self.parseReleases(data)
            if releases.isEmpty { return finish(.failure(.noRelease)) }
            finish(.success(Self.evaluate(releases: releases, current: current, allowPrerelease: allowPre)))
        }.resume()
    }

    /// Synchronous check for the CLI control-socket path, which runs on the main
    /// thread and must return a single reply line. This intentionally bypasses
    /// `check` (whose completion hops to the main thread, which would deadlock a
    /// blocked main thread): the URLSession callback fires on a background queue,
    /// so the semaphore wait is safe. Bounded by a short timeout so `scrollwm
    /// update` can't hang.
    func checkSync(timeout: TimeInterval = 15) -> Result<UpdateCheckResult, UpdateError> {
        var out: Result<UpdateCheckResult, UpdateError> = .failure(.network("timed out"))
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: Self.releasesAPIURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ScrollWM/\(AppVersion.currentString)", forHTTPHeaderField: "User-Agent")
        let allowPre = allowPrerelease
        let current = AppVersion.current
        let task = session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { out = .failure(.network(err.localizedDescription)); return }
            guard let http = resp as? HTTPURLResponse else {
                out = .failure(.badResponse("no HTTP response")); return
            }
            guard (200...299).contains(http.statusCode) else {
                out = .failure(.badResponse("HTTP \(http.statusCode)")); return
            }
            guard let data = data else { out = .failure(.badResponse("empty body")); return }
            let releases = Self.parseReleases(data)
            if releases.isEmpty { out = .failure(.noRelease); return }
            out = .success(Self.evaluate(releases: releases, current: current, allowPrerelease: allowPre))
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout) == .timedOut { task.cancel() }
        return out
    }

    // MARK: - Network: download + verify + install

    /// Download the release zip, verify its SHA-256, and extract it, returning
    /// the path to the unpacked `ScrollWM.app`.
    ///
    /// - `requireChecksum`: when true (the automatic path), a missing or
    ///   unmatched SHA256SUMS entry is a HARD failure rather than a skip, so a
    ///   silent install never trusts an unverifiable asset.
    /// - `stageNear`: if provided, the bundle is extracted into a temporary
    ///   directory on the SAME volume as this URL (the installed app), so the
    ///   later `replaceItemAt` swap is an atomic metadata operation rather than
    ///   a cross-volume copy. Falls back to the system temp dir otherwise.
    ///
    /// All work is on a background queue; `completion` fires on the main thread.
    func downloadAndStage(_ release: ReleaseInfo,
                          requireChecksum: Bool = false,
                          stageNear: URL? = nil,
                          progress: ((Double) -> Void)? = nil,
                          completion: @escaping (Result<URL, UpdateError>) -> Void) {
        let finish = { (r: Result<URL, UpdateError>) in
            DispatchQueue.main.async { completion(r) }
        }
        guard let zipURL = URL(string: release.zipURL) else {
            return finish(.failure(.downloadFailed("invalid asset URL")))
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let tmp: URL
            do {
                tmp = try Self.makeStagingDir(near: stageNear)
            } catch {
                return finish(.failure(.downloadFailed("could not create staging dir: \(error.localizedDescription)")))
            }
            let zipDest = tmp.appendingPathComponent(release.zipName)

            // 1. Download the zip.
            guard let zipData = self.syncDownload(zipURL, progress: progress) else {
                return finish(.failure(.downloadFailed("could not fetch \(release.zipName)")))
            }
            do { try zipData.write(to: zipDest) }
            catch { return finish(.failure(.downloadFailed(error.localizedDescription))) }

            // 2. Verify SHA-256 against SHA256SUMS.txt. Present + matching is
            //    required for the automatic path; otherwise verify-if-available.
            let sumsText: String? = {
                guard let s = release.sha256SumsURL, let u = URL(string: s),
                      let d = self.syncDownload(u) else { return nil }
                return String(data: d, encoding: .utf8)
            }()
            let expected = sumsText.flatMap { Self.expectedSHA256(fromSums: $0, fileName: release.zipName) }
            if let expected = expected {
                let got = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
                if got.lowercased() != expected.lowercased() {
                    return finish(.failure(.checksumMismatch(expected: expected, got: got)))
                }
            } else if requireChecksum {
                return finish(.failure(.downloadFailed("no SHA256SUMS entry for \(release.zipName); refusing to auto-install an unverified asset")))
            }

            // 3. Extract with ditto (handles macOS-style zips + xattrs).
            let extractDir = tmp.appendingPathComponent("extracted")
            if let err = self.runDitto(["-x", "-k", zipDest.path, extractDir.path]) {
                return finish(.failure(.extractFailed(err)))
            }
            let app = extractDir.appendingPathComponent("ScrollWM.app")
            guard FileManager.default.fileExists(atPath: app.path) else {
                return finish(.failure(.extractFailed("archive did not contain ScrollWM.app")))
            }
            finish(.success(app))
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    /// Create a staging directory on the same volume as `near` when possible
    /// (via `.itemReplacementDirectory`), so the eventual swap is atomic. Falls
    /// back to the system temp dir.
    private static func makeStagingDir(near: URL?) throws -> URL {
        let fm = FileManager.default
        if let near = near {
            if let dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                     appropriateFor: near, create: true) {
                return dir
            }
        }
        let dir = fm.temporaryDirectory
            .appendingPathComponent("ScrollWM-update-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Validate a staged bundle before it is allowed to replace the live app.
    /// Returns nil when OK, or a human-readable reason it must be rejected.
    /// Checks: intact signature, matching bundle id, a slice for the running
    /// CPU, and a version strictly newer than what's running.
    func validateStaged(_ stagedApp: URL, expectedMinVersion: SemVer) -> String? {
        let check = CodeSigning.inspect(stagedBundle: stagedApp)
        if !check.signatureValid {
            return "staged build has a broken or unreadable code signature"
        }
        let runningID = Bundle.main.bundleIdentifier ?? "dev.scrollwm.app"
        if let id = check.bundleIdentifier, id != runningID {
            return "staged build bundle id \(id) != \(runningID)"
        }
        if !check.hasMatchingArchitecture {
            return "staged build has no slice for this Mac's architecture"
        }
        if let vs = CodeSigning.shortVersion(ofBundleAt: stagedApp), let v = SemVer(vs) {
            if !(v >= expectedMinVersion) {
                return "staged build v\(v) is not newer than expected v\(expectedMinVersion)"
            }
        }
        return nil
    }

    /// Swap the running bundle for `stagedApp` and relaunch, by re-exec'ing a
    /// throwaway copy of our OWN binary with the hidden `__update-swap`
    /// subcommand (see `InstallSwap`). This DOES NOT restore windows itself:
    /// call `controller.quit()` right after so windows are restored and the app
    /// exits, then the detached swapper performs an ATOMIC replace + relaunch.
    ///
    /// Only valid for an installed `.app` bundle; throws for the dev binary.
    func installAndRelaunch(stagedApp: URL) throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { throw UpdateError.notInstalledBundle }
        guard let exe = Bundle.main.executableURL else {
            throw UpdateError.installFailed("cannot locate running executable")
        }

        // Copy our Mach-O to a temp path so the swapper isn't executing from the
        // bundle it is about to replace. The binary links only system
        // frameworks, so a standalone copy runs fine (ad-hoc or Developer ID).
        let helperDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrollwm-swapper-\(UUID().uuidString.prefix(8))")
        let helper = helperDir.appendingPathComponent("scrollwm-swapper")
        do {
            try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: exe, to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        } catch {
            throw UpdateError.installFailed("could not stage swapper: \(error.localizedDescription)")
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let proc = Process()
        proc.executableURL = helper
        proc.arguments = ["__update-swap", stagedApp.path, bundleURL.path, String(pid)]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() }
        catch { throw UpdateError.installFailed("could not launch swapper: \(error.localizedDescription)") }
        // Detach: the child outlives us. We do not wait.
    }

    // MARK: - Small blocking helpers (run on a background queue)

    private func syncDownload(_ url: URL, progress: ((Double) -> Void)? = nil) -> Data? {
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url)
        req.setValue("ScrollWM/\(AppVersion.currentString)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                out = nil
            } else {
                out = data
            }
            sem.signal()
        }
        task.resume()
        sem.wait()
        return out
    }

    @discardableResult
    private func runDitto(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? "ditto exited \(p.terminationStatus)"
        }
        return nil
    }
}

// MARK: - Dev CLI helper

/// `WindowLab updatecheck [--install] [--prerelease]`: run the live GitHub
/// update check without a running app. Prints the outcome and, with --install
/// on an installed bundle, downloads + verifies + applies it (relaunching).
/// Returns a process exit code (0 = up to date / handled, non-zero = error).
func runUpdateCheckCLI(install: Bool, allowPrerelease: Bool) -> Int32 {
    let stageOnly = CommandLine.arguments.contains("--stage-only")
    let updater = Updater(allowPrerelease: allowPrerelease)
    print("ScrollWM \(AppVersion.currentString) — checking \(Updater.owner)/\(Updater.repo) releases…")
    switch updater.checkSync(timeout: 25) {
    case .failure(let err):
        FileHandle.standardError.write("update check failed: \(err.localizedDescription)\n".data(using: .utf8)!)
        return 1
    case .success(.upToDate(let cur)):
        print("up to date (v\(cur))")
        return 0
    case .success(.noUsableAsset(let rel)):
        print("newer tag \(rel.tagName) found but no installable .zip asset yet")
        return 0
    case .success(.updateAvailable(let rel, let cur)):
        print("update available: v\(rel.version) (you have v\(cur))")
        print("  asset: \(rel.zipName)")
        print("  notes: \(rel.htmlURL)")
        if !install && !stageOnly { return 0 }

        // --stage-only validates the heavy path (download + SHA-256 verify +
        // ditto extract) end-to-end against the REAL published asset, without
        // self-replacing — usable from the dev binary and in CI.
        if stageOnly {
            let sem = DispatchSemaphore(value: 0)
            var rc: Int32 = 0
            print("downloading + verifying + extracting (stage-only)…")
            updater.downloadAndStage(rel) { result in
                switch result {
                case .success(let app):
                    print("STAGED OK -> \(app.path)")
                    print("verified SHA-256 against SHA256SUMS.txt and extracted ScrollWM.app")
                case .failure(let err):
                    FileHandle.standardError.write("stage failed: \(err.localizedDescription)\n".data(using: .utf8)!)
                    rc = 1
                }
                sem.signal()
            }
            while sem.wait(timeout: .now() + 0.05) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return rc
        }

        guard Bundle.main.bundleURL.pathExtension == "app" else {
            print("(dev binary; not self-replacing. Download from the page above, or use --stage-only to validate the download path.)")
            return 0
        }
        let sem = DispatchSemaphore(value: 0)
        var rc: Int32 = 0
        print("downloading + verifying…")
        updater.downloadAndStage(rel) { result in
            switch result {
            case .success(let app):
                do {
                    try updater.installAndRelaunch(stagedApp: app)
                    print("staged; the swapper will replace + relaunch ScrollWM once this process exits.")
                } catch {
                    FileHandle.standardError.write("install failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                    rc = 1
                }
            case .failure(let err):
                FileHandle.standardError.write("download failed: \(err.localizedDescription)\n".data(using: .utf8)!)
                rc = 1
            }
            sem.signal()
        }
        // downloadAndStage hops its completion to the main thread; pump the
        // run loop until it fires so this CLI process can report + exit.
        while sem.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return rc
    }
}
