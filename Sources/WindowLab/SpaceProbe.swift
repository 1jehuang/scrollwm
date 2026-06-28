import Foundation
import CoreGraphics

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
/// currently shown on the MAIN display. It is stable for the lifetime of a Space
/// (it survives switching away and back) which is all the per-Space strip map
/// needs as a key.
enum SpaceProbe {

    /// The active native-Space id, or `nil` when it cannot be determined (the
    /// private symbol is unavailable, the call returned nothing, or a headless
    /// backend without a modeled Space is installed). A `nil` return is the
    /// caller's signal to stay on the single-strip model.
    ///
    /// Routes through `AXSource.backend` when one is installed (headless tests),
    /// so the production CGS path is exercised ONLY on a real machine.
    static func currentSpaceID() -> Int? {
        if let backend = AXSource.backend { return backend.currentSpaceID() }
        return liveCurrentSpaceID()
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

    /// Query the WindowServer for the active Space id on the main display.
    /// Returns `nil` on any shortfall so the caller degrades gracefully.
    private static func liveCurrentSpaceID() -> Int? {
        guard let mainConnection, let copyManagedDisplaySpaces else { return nil }
        let cid = mainConnection()
        guard let raw = copyManagedDisplaySpaces(cid) as? [[String: Any]] else { return nil }
        // Each element describes one display: its "Current Space" dict holds the
        // active Space's id under "ManagedSpaceID" (with "id64" as a fallback on
        // older systems). With "Displays have separate Spaces" ON each display has
        // its OWN active Space, so prefer the MAIN display (identifier "Main");
        // fall back to the first entry for the single-display / spans-displays
        // case. The strip we key today lives on the main display, so the main
        // display's Space is the right key. (A future per-display-Space refinement
        // for multi-strip setups can read each entry by its display UUID.)
        let display = raw.first { ($0["Display Identifier"] as? String) == "Main" } ?? raw.first
        guard let display, let current = display["Current Space"] as? [String: Any] else { return nil }
        return spaceID(from: current)
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
