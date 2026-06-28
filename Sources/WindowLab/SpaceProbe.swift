import Foundation
import CoreGraphics
import ColorSync

/// READ-ONLY native-Space identity probe.
///
/// macOS exposes no PUBLIC, stable identifier for a Mission Control Space:
/// `NSWorkspace.activeSpaceDidChangeNotification` fires on every Desktop switch
/// but carries no Space id, and the only way to learn *which* Space is active is
/// the private CoreGraphics/SkyLight ("CGS") window-server API.
///
/// The per-Space strip model (`docs/spaces/02_ownership.md`, Model B) needs a
/// stable key to file each display's strip under, so this is a *deliberate,
/// documented, isolated* opt-in to a SINGLE read-only private call - exactly the
/// "explicit, documented opt-in" carve-out in AGENTS.md's "no private APIs"
/// contract. The constraints that keep it safe:
///   - READ ONLY. We never create, destroy, switch, or move windows between
///     Spaces (that is the SIP-disabling yabai/scripting-addition territory this
///     project refuses). We only ASK "which Space am I viewing?".
///   - No new permission. CGS needs neither Screen Recording nor Input
///     Monitoring; the existing Accessibility grant is untouched.
///   - Resolved via `dlsym`, never linked: if a future macOS renames or removes
///     the symbol, the probe returns `nil` and the controller silently falls
///     back to the single-strip (Model A) behavior - it can NEVER fail to launch
///     or crash for lack of the symbol.
///   - Behind the `WindowBackend` seam, so every headless test runs against the
///     `SimWindowWorld`'s modeled Spaces and the real CGS call is reached ONLY in
///     production.
///
/// The id we return is the WindowServer's `ManagedSpaceID` for the Space
/// currently shown on a given display. It is stable for the lifetime of a Space
/// (it survives switching away and back) which is all the per-Space strip map
/// needs as a key. With "Displays have separate Spaces" ON each display shows its
/// own Space, so the probe is PER-DISPLAY: each strip keys on its OWN monitor's
/// current Space (`currentSpaceID(forDisplay:)`), and a switch on one monitor
/// never re-points another monitor's strip.
enum SpaceProbe {

    /// The active native-Space id for the MAIN display, or `nil` when it cannot
    /// be determined. Convenience for the single-display / spans-displays case.
    static func currentSpaceID() -> Int? { currentSpaceID(forDisplay: nil) }

    /// The active native-Space id for `displayID` (nil = main display), or `nil`
    /// when it cannot be determined (the private symbol is unavailable, the call
    /// returned nothing, or the display has no CGS entry). A `nil` return is the
    /// caller's signal to keep that strip on the single-strip model.
    ///
    /// Routes through `AXSource.backend` when one is installed (headless tests),
    /// so the production CGS path is exercised ONLY on a real machine.
    static func currentSpaceID(forDisplay displayID: CGDirectDisplayID?) -> Int? {
        if let backend = AXSource.backend { return backend.currentSpaceID(forDisplay: displayID) }
        return liveCurrentSpaceID(forDisplay: displayID)
    }

    // MARK: - Live (production) CGS path

    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> CFArray?

    /// Cached function pointers (resolved once via `dlsym`). `nil` after the
    /// first failed resolution so we never re-probe a missing symbol.
    private static let handle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_NOW)
    private static let mainConnection: MainConnFn? = sym("CGSMainConnectionID")
    private static let copyManagedDisplaySpaces: CopyDisplaySpacesFn? = sym("CGSCopyManagedDisplaySpaces")

    private static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// True when the live CGS probe is usable on this machine (the private
    /// symbols resolved). Lets the controller log "per-Space strips active" vs
    /// "unavailable, staying single-strip" exactly once at startup.
    static var isLiveProbeAvailable: Bool {
        mainConnection != nil && copyManagedDisplaySpaces != nil
    }

    /// Query the WindowServer for the active Space id on `displayID` (nil = main).
    /// Returns `nil` on any shortfall so the caller degrades gracefully.
    private static func liveCurrentSpaceID(forDisplay displayID: CGDirectDisplayID?) -> Int? {
        guard let mainConnection, let copyManagedDisplaySpaces else { return nil }
        let cid = mainConnection()
        guard let raw = copyManagedDisplaySpaces(cid) as? [[String: Any]] else { return nil }

        // Each element describes one display, identified by "Display Identifier":
        // the MAIN display is the literal string "Main"; every secondary display
        // is its display UUID string. Under "Displays have separate Spaces" each
        // entry carries its OWN "Current Space", so we match the requested
        // display's identifier and read THAT entry's active Space.
        let wantIdentifier = displayIdentifier(for: displayID)
        let display = raw.first { ($0["Display Identifier"] as? String) == wantIdentifier }
            // Fall back to the main entry, then the first entry, so a display we
            // cannot resolve (or the single-shared-Space case) still yields a
            // sensible id rather than nil.
            ?? raw.first { ($0["Display Identifier"] as? String) == "Main" }
            ?? raw.first
        guard let display, let current = display["Current Space"] as? [String: Any] else { return nil }
        return spaceID(from: current)
    }

    /// The CGS "Display Identifier" string for a `CGDirectDisplayID`: "Main" for
    /// the main display (CGS labels it that way), otherwise the display's UUID
    /// string. `nil` display -> "Main".
    private static func displayIdentifier(for displayID: CGDirectDisplayID?) -> String {
        guard let displayID, CGDisplayIsMain(displayID) == 0 else { return "Main" }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, uuid) as String? else { return "Main" }
        return s
    }

    /// Pull the managed Space id out of a "Current Space" dict, tolerating the
    /// `Int` vs `NSNumber` bridging differences across macOS versions.
    private static func spaceID(from current: [String: Any]) -> Int? {
        if let id = current["ManagedSpaceID"] as? Int { return id }
        if let id = current["id64"] as? Int { return id }
        if let n = current["ManagedSpaceID"] as? NSNumber { return n.intValue }
        if let n = current["id64"] as? NSNumber { return n.intValue }
        return nil
    }
}
