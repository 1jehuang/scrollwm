import Foundation
import Security

/// Code-signing introspection used by the updater to decide whether an update
/// is SAFE to apply, especially: "will macOS keep ScrollWM's Accessibility
/// grant after we swap the bundle?"
///
/// Why this is the crux of a safe self-update
/// ------------------------------------------
/// ScrollWM's ONLY permission is Accessibility (TCC `kTCCServiceAccessibility`).
/// macOS stores that grant against a serialized code requirement (`csreq`,
/// effectively the app's *designated requirement*) captured when the user first
/// approved it. On every use, TCC re-validates the live process against that
/// stored requirement. So whether a replaced bundle keeps the grant depends on
/// the SIGNING IDENTITY, not the file path:
///
///   - ad-hoc signed: the designated requirement is `cdhash H"..."`. Every
///     rebuild has a new cdhash, so a replaced bundle NO LONGER satisfies the
///     stored requirement -> Accessibility silently drops. A window manager
///     that can't move windows is "broken" to the user.
///   - stable self-signed (same leaf cert) or Developer ID (same Team ID): the
///     requirement is identifier + leaf/anchor based and is independent of the
///     cdhash, so a new build still satisfies it -> the grant is PRESERVED and
///     the update is seamless.
///
/// We can't read the SIP-protected TCC.db, but we can compute the running
/// app's designated requirement and check whether the staged (new) bundle
/// satisfies it. That is the same predicate TCC will apply, so it is a faithful
/// "will the grant survive?" probe.
enum CodeSigning {

    /// Result of inspecting a staged bundle for update-safety.
    struct BundleCheck: Equatable {
        /// The bundle has a structurally valid, unbroken signature (ad-hoc is OK).
        var signatureValid: Bool
        /// `CFBundleIdentifier` read from the staged bundle (nil if unreadable).
        var bundleIdentifier: String?
        /// The staged main executable contains a slice for the running CPU arch.
        var hasMatchingArchitecture: Bool
    }

    // MARK: - Designated requirement / TCC preservation

    /// The designated requirement of the bundle at `url`, or nil if it has no
    /// readable signature.
    static func designatedRequirement(ofBundleAt url: URL) -> SecRequirement? {
        guard let code = staticCode(at: url) else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess else { return nil }
        return req
    }

    /// Does the bundle at `url` satisfy `requirement` AND have an intact
    /// signature? (`SecStaticCodeCheckValidity` validates the seal too.)
    static func bundle(at url: URL, satisfies requirement: SecRequirement) -> Bool {
        guard let code = staticCode(at: url) else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// True when the signature seal of the bundle at `url` is structurally
    /// valid and unbroken. Accepts ad-hoc signatures (we are not asserting a
    /// trusted anchor here, only integrity), which matches how a non-notarized
    /// build still runs locally.
    static func signatureIsValid(ofBundleAt url: URL) -> Bool {
        guard let code = staticCode(at: url) else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        return status == errSecSuccess
    }

    /// Will swapping `currentBundle` for `stagedBundle` PRESERVE the
    /// Accessibility grant? True only when the staged bundle satisfies the
    /// current bundle's designated requirement (the predicate TCC stored).
    ///
    /// Returns false when either bundle has no readable signature, or when the
    /// staged build no longer matches (the ad-hoc cdhash case). A false result
    /// is not "unsafe to install" on its own; it means "the user will have to
    /// re-grant Accessibility", which the caller must handle honestly instead
    /// of silently breaking the app.
    static func willPreserveAccessibility(currentBundle: URL, stagedBundle: URL) -> Bool {
        guard let req = designatedRequirement(ofBundleAt: currentBundle) else { return false }
        return bundle(at: stagedBundle, satisfies: req)
    }

    // MARK: - Staged-bundle sanity

    /// Inspect a staged bundle for the invariants we require before replacing
    /// the live app: intact signature, a readable bundle id, and a slice for
    /// the running architecture.
    static func inspect(stagedBundle url: URL) -> BundleCheck {
        BundleCheck(
            signatureValid: signatureIsValid(ofBundleAt: url),
            bundleIdentifier: bundleIdentifier(ofBundleAt: url),
            hasMatchingArchitecture: hasMatchingArchitecture(stagedBundle: url)
        )
    }

    /// `CFBundleIdentifier` from a bundle's Info.plist.
    static func bundleIdentifier(ofBundleAt url: URL) -> String? {
        Bundle(url: url)?.infoDictionary?["CFBundleIdentifier"] as? String
    }

    /// `CFBundleShortVersionString` from a bundle's Info.plist.
    static func shortVersion(ofBundleAt url: URL) -> String? {
        Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Does the staged bundle's main executable include a slice for the CPU we
    /// are currently running on? Prevents relaunching into an x86_64-only (or
    /// otherwise mismatched) build that can't execute.
    static func hasMatchingArchitecture(stagedBundle url: URL) -> Bool {
        guard let bundle = Bundle(url: url),
              let archs = bundle.executableArchitectures?.map({ $0.intValue }) else {
            return false
        }
        return archs.contains(currentExecutableArchitecture)
    }

    /// The Mach-O architecture constant for the running process, matching the
    /// `NSBundleExecutableArchitecture*` values returned by
    /// `Bundle.executableArchitectures`.
    static var currentExecutableArchitecture: Int {
        #if arch(arm64)
        return NSBundleExecutableArchitectureARM64
        #elseif arch(x86_64)
        return NSBundleExecutableArchitectureX86_64
        #else
        return 0
        #endif
    }

    // MARK: - Helpers

    private static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }
}
