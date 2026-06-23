import Foundation
import ApplicationServices
import AppKit

/// Sandbox mode: run the REAL production ScrollWM controller, but locked to a
/// set of disposable test windows it spawns itself. Your actual session windows
/// are never enumerated or moved, so this is safe to run live.
///
/// How the isolation is guaranteed:
///   - `controller.sandboxPIDs` is set to the spawned helper PIDs. Every
///     arrange path (menu, hotkey, direct) is forced through that filter, and
///     the `LifecycleMonitor` only observes/adopts those PIDs.
///   - `RestoreStore.subdirectory` is redirected to a separate folder, so the
///     sandbox's crash-recovery file can never clobber or recover your real
///     managed windows.
///
/// Usage:
///   WindowLab sandbox [n]            spawn n windows (default 4), arrange, and
///                                    stay live so you can drive the real
///                                    hotkeys against them. Ctrl-C / Quit
///                                    restores + cleans up the test windows.
func runSandbox(windowCount: Int) {
    guard AXSource.isTrusted else {
        print("sandbox: needs Accessibility permission. Grant it and re-run.")
        exit(2)
    }

    // Isolate crash-recovery state from the real ScrollWM session.
    RestoreStore.subdirectory = "ScrollWM-Sandbox"
    RestoreStore.clear()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    print("[sandbox] spawning \(windowCount) disposable test windows...")
    let spawned = spawnTestWindows(count: windowCount)
    let pids = Set(spawned.map { $0.processIdentifier })

    // Build the real controller and LOCK it to the sandbox windows.
    let controller = ScrollWMController()
    controller.sandboxPIDs = pids
    scrollWMControllerKeepAlive = controller

    // Expose a control socket so `scrollwm <verb>` can drive the sandbox.
    // Point the CLI at it with SCROLLWM_CONTROL_SOCK (printed below).
    controller.startControlServer()

    // Clean up the spawned helpers on exit so nothing leaks.
    func cleanup() {
        if controller.isManaging { controller.release() }
        for p in spawned where p.isRunning { p.terminate() }
        RestoreStore.clear()
    }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { print("\n[sandbox] cleaning up..."); cleanup(); exit(0) }
        src.resume()
        sandboxSignalSources.append(src)
    }

    // Give the helpers a beat to register their windows, then arrange.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        controller.arrange() // sandboxPIDs forces the filter
        print("""
        [sandbox] arranged \(controller.debugSlotCount) sandbox windows into the strip.
        Drive the REAL hotkeys against them safely:
          ctrl+opt+left/right   focus prev/next       ctrl+opt+1..9  jump
          opt+1/2/3/4           width 25/50/75/100%   cmd+h / cmd+l  move
          cmd+q                 close focused          ctrl+opt+esc   toggle
        Your real windows are untouched. Ctrl-C (or Quit) restores + cleans up.
        """)
    }

    app.run()
}

/// Keep sandbox signal sources alive for the process lifetime.
var sandboxSignalSources: [DispatchSourceSignal] = []
