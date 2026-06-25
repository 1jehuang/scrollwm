import Foundation
import ApplicationServices
import AppKit

/// LIVE binding check for the strip-move path ([md-move]).
///
/// Unlike `displaytest`, this NEVER arranges or moves a window, so it is safe to
/// run even while the screen is locked (where `arrange` correctly refuses). It
/// drives the REAL production `ScrollWMController.moveStripToDisplay` against the
/// REAL `NSScreen` layout and reads back the engine's bound frames, proving on
/// the actual negative-origin external that:
///
///   * launch + every runtime move flips AppKit->AX about the PRIMARY display's
///     height (so a strip on a non-primary external lands at the right AX Y), and
///   * the OLD hand-rolled own-height flip (the launch bug) is NOT what we
///     produce for a non-primary strip.
///
/// It touches ZERO windows (the strip is empty), so it obeys the GOLDEN RULE
/// outright. Run under the AX lock anyway for courtesy:
///   `/tmp/scrollwm-axlock.sh .build/debug/WindowLab displaybindcheck`
func runDisplayBindCheck() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Isolate any crash-recovery state from the real session, like sandbox.
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let controller = ScrollWMController()
    scrollWMControllerKeepAlive = controller

    DispatchQueue.main.async {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }
        func approx(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 1) -> Bool {
            abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
                && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
        }
        func rs(_ r: CGRect) -> String {
            "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
        }

        let screens = NSScreen.screens
        let primaryHeight = (screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.main ?? screens[0]).frame.height
        print("[displaybindcheck] \(screens.count) display(s), primaryHeight=\(Int(primaryHeight))")
        for (i, s) in screens.enumerated() {
            let axV = DisplayGeometry.axFrame(appKitFrame: s.visibleFrame, primaryHeight: primaryHeight)
            print("  display \(i + 1): \(s.localizedName) AppKit=\(rs(s.frame)) "
                  + "visibleAX=\(rs(axV)) main=\(s === NSScreen.main) primary=\(s.frame.origin == .zero)")
        }

        // Drive a runtime move onto EVERY display by 1-based index and read back
        // the engine's bound frames; compare to the primary-height flip (correct)
        // and the own-height flip (the bug).
        for (i, s) in screens.enumerated() {
            let reply = controller.moveStripToDisplay("\(i + 1)")
            let expectedVisible = DisplayGeometry.axFrame(appKitFrame: s.visibleFrame, primaryHeight: primaryHeight)
            let expectedFull = DisplayGeometry.axFrame(appKitFrame: s.frame, primaryHeight: primaryHeight)
            let buggyVisible = CGRect(x: s.visibleFrame.origin.x,
                                      y: s.frame.height - s.visibleFrame.maxY,
                                      width: s.visibleFrame.width, height: s.visibleFrame.height)
            let gotVisible = controller.debugScreenFrame
            let gotFull = controller.debugStripDisplayFrame ?? .null
            print("[displaybindcheck] move -> display \(i + 1): \(reply)")
            print("    bound visible=\(rs(gotVisible)) full=\(rs(gotFull)) "
                  + "(expected visible=\(rs(expectedVisible)), buggy own-height=\(rs(buggyVisible)))")
            check("display \(i + 1): strip visible frame uses PRIMARY-height flip",
                  approx(gotVisible, expectedVisible))
            check("display \(i + 1): strip full (parking ref) uses PRIMARY-height flip",
                  approx(gotFull, expectedFull))
            // The regression guard only bites on a NON-primary display, where the
            // two flips differ; on the primary they coincide (and that's fine).
            if s.frame.origin != .zero && abs(buggyVisible.minY - expectedVisible.minY) > 1 {
                check("display \(i + 1): NOT the buggy own-height Y (\(Int(buggyVisible.minY)))",
                      !approx(gotVisible, buggyVisible))
            }
        }

        // Symbolic specs resolve against the real hardware too.
        for spec in ["main", "primary", "largest", "next"] {
            let reply = controller.moveStripToDisplay(spec)
            print("[displaybindcheck] move -> \(spec): \(reply)")
            check("spec '\(spec)' returns ok", reply.hasPrefix("ok:"))
        }
        // Bad spec is a clean error and leaves the binding intact.
        let beforeBad = controller.debugScreenFrame
        let badReply = controller.moveStripToDisplay("banana")
        check("bad spec returns error", badReply.hasPrefix("error:"))
        check("bad spec leaves the strip binding unchanged",
              approx(controller.debugScreenFrame, beforeBad))
        let oorReply = controller.moveStripToDisplay("\(screens.count + 1)")
        check("out-of-range index returns error", oorReply.hasPrefix("error:"))

        print("\n[displaybindcheck] \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
    app.run()
}
