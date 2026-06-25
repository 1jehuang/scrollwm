import Foundation

/// Pure-logic tests for the onboarding window's copy + state mapping.
///
/// These exercise `OnboardingCopy` ONLY — no `NSWindow`, no AppKit, no
/// `AccessibilityPermission` side effects, no system modal, no TCC. They run
/// fully headless and are safe on the user's real machine: nothing here can
/// present a window or move a real window.
///
/// Run with: `WindowLab onboardingcopytest` (wired by the coordinator).
enum OnboardingCopyTests {

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name)") }
        }

        // MARK: - presentation(for:) — total over all three states

        let granted = OnboardingCopy.presentation(for: .granted)
        let notDet = OnboardingCopy.presentation(for: .notDetermined)
        let denied = OnboardingCopy.presentation(for: .denied)

        // .granted: success dot, primary disabled (nothing left to do), no hint.
        check("granted dot is success", granted.dotColor == .success)
        check("granted primary disabled", granted.primaryButtonEnabled == false)
        check("granted has no troubleshooting", granted.troubleshootingText == nil)
        check("granted status mentions arranging",
              granted.statusText.lowercased().contains("arrang"))
        check("granted a11y leads with 'Granted'",
              granted.statusAccessibilityLabel.hasPrefix("Granted"))

        // .notDetermined: neutral dot, primary enabled, no hint, "waiting" copy.
        check("notDetermined dot is neutral", notDet.dotColor == .neutral)
        check("notDetermined primary enabled", notDet.primaryButtonEnabled == true)
        check("notDetermined has no troubleshooting", notDet.troubleshootingText == nil)
        check("notDetermined status says waiting",
              notDet.statusText.lowercased().contains("waiting"))
        check("notDetermined a11y leads with 'Waiting'",
              notDet.statusAccessibilityLabel.hasPrefix("Waiting"))

        // .denied: warning dot, primary enabled, toggle-off-on hint present.
        check("denied dot is warning", denied.dotColor == .warning)
        check("denied primary enabled", denied.primaryButtonEnabled == true)
        check("denied has troubleshooting", denied.troubleshootingText != nil)
        check("denied hint mentions toggle off then on",
              (denied.troubleshootingText ?? "").lowercased().contains("off")
              && (denied.troubleshootingText ?? "").lowercased().contains("on"))
        check("denied a11y leads with 'Action needed'",
              denied.statusAccessibilityLabel.hasPrefix("Action needed"))

        // The three states must produce three DISTINCT presentations and three
        // distinct dot colours — no two states should read identically.
        check("three distinct presentations",
              granted != notDet && granted != denied && notDet != denied)
        let dots: Set<OnboardingCopy.DotColor> = [granted.dotColor, notDet.dotColor, denied.dotColor]
        check("three distinct dot colours", dots.count == 3)

        // Meaning beyond colour: every state carries a non-empty a11y label, and
        // it differs from the plain status text (it states the meaning in words).
        for (name, p) in [("granted", granted), ("notDetermined", notDet), ("denied", denied)] {
            check("\(name) a11y label non-empty", !p.statusAccessibilityLabel.isEmpty)
            check("\(name) status text non-empty", !p.statusText.isEmpty)
        }

        // Idempotence / purity: same input → equal output, no hidden state.
        check("presentation is pure (granted)",
              OnboardingCopy.presentation(for: .granted) == granted)
        check("presentation is pure (denied)",
              OnboardingCopy.presentation(for: .denied) == denied)

        // MARK: - shouldRevealInFinder — no-op for the dev binary

        check("reveal enabled for .app bundle",
              OnboardingCopy.shouldRevealInFinder(bundlePathExtension: "app") == true)
        check("reveal no-op for dev binary (no extension)",
              OnboardingCopy.shouldRevealInFinder(bundlePathExtension: "") == false)
        check("reveal no-op for raw executable extension",
              OnboardingCopy.shouldRevealInFinder(bundlePathExtension: "out") == false)

        // MARK: - Static copy sanity (catches accidental emptying)

        check("window title set", !OnboardingCopy.windowTitle.isEmpty)
        check("heading set", !OnboardingCopy.heading.isEmpty)
        check("subheading set", !OnboardingCopy.subheading.isEmpty)
        check("exactly three steps", OnboardingCopy.steps.count == 3)
        check("no empty step", OnboardingCopy.steps.allSatisfy { !$0.isEmpty })
        check("primary button titled", !OnboardingCopy.primaryButtonTitle.isEmpty)
        check("reveal button titled", !OnboardingCopy.revealButtonTitle.isEmpty)
        check("copy-agent button titled", !OnboardingCopy.copyAgentButtonTitle.isEmpty)

        // MARK: - Agent instructions accuracy

        let agent = OnboardingCopy.agentInstructions
        check("agent text non-empty", !agent.isEmpty)
        check("agent names the app", agent.contains("ScrollWM"))
        check("agent names Accessibility", agent.contains("Accessibility"))
        check("agent has the exact settings URL scheme",
              agent.contains("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
        check("agent says no relaunch", agent.lowercased().contains("no relaunch"))
        // Accuracy: it must reference the REAL menu label and the REAL first-grant
        // auto-arrange behaviour, not a non-existent "Arrange" item or a claim
        // that nothing happens until the user acts.
        check("agent uses the real menu label",
              agent.contains("Arrange Windows into Strip"))
        check("agent reflects first-grant auto-arrange",
              agent.lowercased().contains("arranges the open windows"))
        check("agent tells assistant not to flip the switch",
              agent.lowercased().contains("do not attempt to flip the switch"))

        print("\n[onboardingcopytest] \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
