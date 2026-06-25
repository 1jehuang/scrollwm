import Foundation
import CoreGraphics

/// Pure-logic hardening tests for the negative-origin EXTERNAL monitor that is
/// physically connected right now: in AppKit it is a 1920x1080 panel at origin
/// `(-225, 956)` (ABOVE-AND-LEFT of the 1470x956 built-in primary). In the
/// engine's AX top-left plane that becomes `(-225, -1080, 1920, 1080)` — both X
/// and Y are NEGATIVE.
///
/// The existing `StripOpsTests` geometry block models a *hypothetical*
/// `2560x1440` external; these tests pin behavior to the EXACT resolution that
/// is plugged in, and close three coverage gaps the brief calls out:
///   (a) PARKING when the strip lives on the negative-origin external — the
///       unavoidable ~40px macOS clamp sliver must stay on the EXTERNAL, never
///       spill onto the built-in below/right.
///   (b) PARKING when displays are stacked VERTICALLY (external ABOVE the
///       built-in), in both directions (strip on the built-in, strip on the
///       external).
///   (c) RESTORE of a saved frame whose display was UNPLUGGED — `ensureVisible`
///       must land it on a surviving display, including rescuing ONTO the
///       negative-origin external.
///   (d) RESTORE correctness across the negative-Y plane (clamp / contains /
///       round-trip on negative origins).
///   (e) ROUND-TRIP `axFrame`/`appKitFrame` on negative origins.
///
/// Kept in its OWN file (not appended to the shared `StripOpsTests.swift`) so it
/// merges cleanly; `StripOpsTests.run` invokes it with the shared `check`
/// closure via a single call site.
enum GeometryHardeningTests {

    /// The off-screen parking shove distance, matching
    /// `TeleportEngine.computeParkingX`'s default `margin`.
    static let parkMargin: CGFloat = 4000

    /// Run every hardening check, reporting through the caller's `check`.
    static func run(_ check: (String, Bool) -> Void) {
        // ---- The LIVE hardware, in both coordinate systems --------------------
        // Primary (built-in) defines the Y-flip height for the whole AX plane.
        let primaryH: CGFloat = 956
        let builtinAppKit  = CGRect(x: 0,    y: 0,   width: 1470, height: 956)
        let extAppKit      = CGRect(x: -225, y: 956, width: 1920, height: 1080)
        let builtinAX = DisplayGeometry.axFrame(appKitFrame: builtinAppKit, primaryHeight: primaryH)
        let extAX     = DisplayGeometry.axFrame(appKitFrame: extAppKit,     primaryHeight: primaryH)

        // ===================== (e) negative-origin round-trips =================
        check("hard/geom: built-in AppKit(0,0) maps to AX origin",
              builtinAX == CGRect(x: 0, y: 0, width: 1470, height: 956))
        // The LIVE external: ABOVE in AppKit (y=956) => NEGATIVE AX y; its own
        // negative AppKit x is carried straight through.
        check("hard/geom: LIVE external maps to AX (-225,-1080,1920,1080)",
              extAX == CGRect(x: -225, y: -1080, width: 1920, height: 1080))
        check("hard/geom: external AX origin is negative in BOTH axes",
              extAX.minX < 0 && extAX.minY < 0)
        // axFrame is an involution: AX -> AppKit -> AX returns the input exactly,
        // and AppKit -> AX -> AppKit likewise. A sign error in the flip would
        // break one direction.
        check("hard/geom: AX->AppKit round-trips to the live AppKit frame",
              DisplayGeometry.appKitFrame(axFrame: extAX, primaryHeight: primaryH) == extAppKit)
        check("hard/geom: AX->AppKit->AX is identity on negative origins",
              DisplayGeometry.axFrame(
                appKitFrame: DisplayGeometry.appKitFrame(axFrame: extAX, primaryHeight: primaryH),
                primaryHeight: primaryH) == extAX)
        check("hard/geom: AppKit->AX->AppKit is identity on negative origins",
              DisplayGeometry.appKitFrame(
                axFrame: DisplayGeometry.axFrame(appKitFrame: extAppKit, primaryHeight: primaryH),
                primaryHeight: primaryH) == extAppKit)

        // ===================== (a) PARK on the negative-origin external ========
        // Strip lives on the EXTERNAL; the built-in sits directly BELOW it. A
        // parked column keeps its full height and only slides off a SIDE, so a
        // display below does NOT block either horizontal edge (it shares no part
        // of the external's vertical band as a side neighbor). prefer is honored
        // on each side, and the resulting sliver stays on the external display.
        let extRight = TeleportEngine.computeParkingX(stripDisplay: extAX, others: [builtinAX], prefer: .right)
        let extLeft  = TeleportEngine.computeParkingX(stripDisplay: extAX, others: [builtinAX], prefer: .left)
        check("hard/park: external-strip prefer=right shoves past the external's right edge",
              extRight == extAX.maxX + parkMargin)
        check("hard/park: external-strip prefer=left shoves past the external's left edge",
              extLeft == extAX.minX - parkMargin)
        check("hard/park: external-strip left/right edges differ (one sliver per side)",
              extLeft != extRight)
        // Contract mirror of the LIVE displaytest assertion: each park edge is on
        // the FAR side of a strip edge that has no neighbor in that direction.
        check("hard/park: external-strip prefer=right edge favors the strip (no neighbor spill)",
              parkingEdgeFavorsStrip(extRight, strip: extAX, others: [builtinAX]))
        check("hard/park: external-strip prefer=left edge favors the strip (no neighbor spill)",
              parkingEdgeFavorsStrip(extLeft, strip: extAX, others: [builtinAX]))

        // ===================== (b) VERTICAL stack, strip on the built-in =======
        // External is ABOVE the built-in. Because we never push off the top/
        // bottom, the vertical neighbor is irrelevant and prefer is honored on
        // each horizontal side. This is the real user-facing case (strip on the
        // laptop panel, monitor mounted above): the peek is a tall sliver on the
        // built-in's own left/right edge.
        let biRight = TeleportEngine.computeParkingX(stripDisplay: builtinAX, others: [extAX], prefer: .right)
        let biLeft  = TeleportEngine.computeParkingX(stripDisplay: builtinAX, others: [extAX], prefer: .left)
        check("hard/park: built-in-strip honors prefer=right horizontally (free edge)",
              biRight == builtinAX.maxX + parkMargin)
        check("hard/park: built-in-strip honors prefer=left horizontally (free edge)",
              biLeft == builtinAX.minX - parkMargin)
        check("hard/park: built-in-strip edges favor the strip (no spill onto external above)",
              parkingEdgeFavorsStrip(biRight, strip: builtinAX, others: [extAX])
                && parkingEdgeFavorsStrip(biLeft, strip: builtinAX, others: [extAX]))

        // A neighbor sharing the strip's vertical band on a side DOES flip it. A
        // display directly to the RIGHT (overlapping the built-in's rows) forces
        // an off-right park to flip to the free left edge.
        let sideExt = CGRect(x: builtinAX.maxX, y: builtinAX.minY, width: 1920, height: 1080)
        check("hard/park: side neighbor on the right flips an off-right park to the left edge",
              TeleportEngine.computeParkingX(stripDisplay: builtinAX, others: [sideExt], prefer: .right)
                == builtinAX.minX - parkMargin)

        // ===================== (c) RESTORE: display unplugged ==================
        let bothDisplays = [builtinAX, extAX]
        let builtinOnly  = [builtinAX]   // external unplugged
        let externalOnly = [extAX]       // built-in "gone" (lid closed / clamshell)

        // A window saved on the now-gone EXTERNAL is rescued onto the surviving
        // built-in (mostly visible there, never larger than it).
        let savedOnExternal = CGRect(x: -100, y: -900, width: 800, height: 600)
        let rescuedToBuiltin = TeleportEngine.restoreFrame(original: savedOnExternal, displays: builtinOnly)
        check("hard/restore: frame on the unplugged external is rescued onto the built-in",
              DisplayGeometry.isMostlyVisible(rescuedToBuiltin, on: builtinOnly)
                && builtinAX.contains(rescuedToBuiltin))

        // The MIRROR case the negative-origin plane makes interesting: a window
        // saved on the built-in, then ONLY the negative-origin external survives
        // (clamshell). It must be pulled ONTO the negative-Y external, not left
        // stranded at positive coords off every screen.
        let savedOnBuiltin = CGRect(x: 100, y: 100, width: 600, height: 400)
        let rescuedToExternal = TeleportEngine.restoreFrame(original: savedOnBuiltin, displays: externalOnly)
        check("hard/restore: frame on a gone built-in is rescued ONTO the negative-origin external",
              DisplayGeometry.isMostlyVisible(rescuedToExternal, on: externalOnly)
                && extAX.contains(rescuedToExternal))
        // The negative-PLANE crossing is the point: the saved frame lived at
        // positive Y (100..500) but the only survivor is entirely at AX Y<=0, so
        // a correct rescue MUST pull it into NEGATIVE Y. (X legitimately stays at
        // 100 — already inside the external's X range [-225,1695] — so we assert
        // only the axis the clamp had to move, not an over-strong both-negative.)
        check("hard/restore: rescue crosses into the external's negative-Y plane",
              rescuedToExternal.maxY <= 0 && rescuedToExternal.minY < 0)

        // No perturbation when the saved frame's display is still present.
        check("hard/restore: external frame untouched while the external is present",
              TeleportEngine.restoreFrame(original: savedOnExternal, displays: bothDisplays) == savedOnExternal)
        check("hard/restore: built-in frame untouched while the built-in is present",
              TeleportEngine.restoreFrame(original: savedOnBuiltin, displays: bothDisplays) == savedOnBuiltin)

        // RestoreStore crash-recovery entries follow the same policy across the
        // negative plane: an entry on the gone external is clamped onto the
        // surviving built-in; an on-screen entry is left byte-for-byte.
        let crashOnExternal = RestoreStore.Entry(
            pid: 4242, appName: "App", title: "Win", x: -100, y: -900, w: 800, h: 600)
        let safeCrash = RestoreStore.safeTarget(for: crashOnExternal, displays: builtinOnly)
        check("hard/restore: crash entry on a gone external is pulled onto a survivor",
              DisplayGeometry.isMostlyVisible(safeCrash, on: builtinOnly) && builtinAX.contains(safeCrash))
        // And a crash entry already on the negative-origin external is untouched
        // when that external is the surviving display (round-trips negative y).
        let crashOnExternalLive = RestoreStore.Entry(
            pid: 4242, appName: "App", title: "Win", x: -100, y: -900, w: 800, h: 600)
        check("hard/restore: crash entry on the surviving external is left untouched",
              RestoreStore.safeTarget(for: crashOnExternalLive, displays: externalOnly)
                == CGRect(x: -100, y: -900, width: 800, height: 600))

        // ===================== (d) negative-Y clamp / contains =================
        // clamp an oversize window directly into the negative-origin external:
        // it shrinks to fit and lands fully inside the negative-Y bounds.
        let oversize = DisplayGeometry.clamp(
            CGRect(x: 9000, y: 9000, width: 5000, height: 5000), into: extAX)
        check("hard/geom: clamp oversize INTO the negative-origin external fits & is contained",
              extAX.contains(oversize) && oversize.width <= extAX.width && oversize.height <= extAX.height)
        // clamp a window that overshoots the external's TOP-LEFT (most negative
        // corner): it pins to the external's min edges, not past them.
        let pinned = DisplayGeometry.clamp(
            CGRect(x: -9000, y: -9000, width: 400, height: 300), into: extAX)
        check("hard/geom: clamp pins to the external's negative min corner",
              pinned.minX == extAX.minX && pinned.minY == extAX.minY)
        // A frame squarely on the negative-Y external is "mostly visible" there.
        check("hard/geom: a frame on the negative-Y external is mostly visible",
              DisplayGeometry.isMostlyVisible(
                CGRect(x: 0, y: -800, width: 600, height: 400), on: [extAX]))
        // best-overlap correctly picks the negative-origin external for a window
        // centered on it (no positive-coordinate bias).
        check("hard/geom: best-overlap picks the negative-origin external",
              DisplayGeometry.display(
                bestOverlapping: CGRect(x: 0, y: -700, width: 800, height: 500),
                displays: bothDisplays) == extAX)

        // ===================== (d) L-shaped dead zone the layout creates =======
        // The built-in (x>=0, y in [0,956]) and the external (y<=0, x in
        // [-225,1695]) only meet at the y=0 corner, so they DON'T tile: the
        // region x in [-225,0], y in [0,956] is on NEITHER display — an L-shaped
        // dead zone unique to this negative-origin layout. A frame stranded there
        // overlaps nothing, so ensureVisible must take the `bestOverlapping ??
        // displays[0]` fallback and still pull it onto a real display.
        let deadZone = CGRect(x: -200, y: 100, width: 180, height: 700)
        check("hard/geom: a frame in the inter-display dead zone is NOT mostly visible",
              !DisplayGeometry.isMostlyVisible(deadZone, on: bothDisplays))
        let rescuedFromGap = DisplayGeometry.ensureVisible(deadZone, displays: bothDisplays)
        check("hard/geom: a frame in the dead zone is rescued onto SOME real display",
              DisplayGeometry.isMostlyVisible(rescuedFromGap, on: bothDisplays))
        check("hard/restore: a window stranded in the dead zone is restored onto a display",
              DisplayGeometry.isMostlyVisible(
                TeleportEngine.restoreFrame(original: deadZone, displays: bothDisplays),
                on: bothDisplays))

        // A frame straddling the y=0 SEAM where the displays DO share x (x in
        // [0,1470]) is genuinely contiguous (built-in above, external below), so
        // summing the two overlaps correctly reports it visible — it must NOT be
        // perturbed by a restore. Guards against an over-eager clamp that would
        // yank a legitimately-spanning window onto one screen.
        let seam = CGRect(x: 100, y: -478, width: 600, height: 956)
        check("hard/geom: a frame straddling the shared y=0 seam is mostly visible",
              DisplayGeometry.isMostlyVisible(seam, on: bothDisplays))
        check("hard/restore: a seam-straddling frame is left untouched (no spurious clamp)",
              TeleportEngine.restoreFrame(original: seam, displays: bothDisplays) == seam)
    }

    /// Deterministic mirror of the LIVE displaytest assertion: the park edge `x`
    /// sits on the FAR side of a strip edge that has NO side neighbor in that
    /// direction, so the macOS clamp sliver will stay on the strip display. A
    /// parked window keeps its full height and slides off a side only, so this is
    /// a purely horizontal contract; the displaytest proves the real clamp honors
    /// it on hardware.
    static func parkingEdgeFavorsStrip(_ x: CGFloat, strip s: CGRect, others: [CGRect]) -> Bool {
        func vOverlap(_ d: CGRect) -> Bool { d.minY < s.maxY && d.maxY > s.minY }
        let rightBlocked = others.contains { $0.minX >= s.maxX - 1 && vOverlap($0) }
        let leftBlocked  = others.contains { $0.maxX <= s.minX + 1 && vOverlap($0) }
        // X must be past a FREE horizontal edge. When one side is blocked we
        // expect the flip to the opposite (free) side; when both are blocked,
        // either far side is the unavoidable fallback.
        if rightBlocked && !leftBlocked { return x < s.minX }
        if leftBlocked && !rightBlocked { return x > s.maxX }
        return x > s.maxX || x < s.minX
    }
}
