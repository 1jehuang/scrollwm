import Foundation

/// PURE presentation logic for the onboarding window.
///
/// Why this file exists
/// --------------------
/// `OnboardingWindow.swift` is unavoidably impure: it builds `NSView`s, talks to
/// `AccessibilityPermission`, hides apps, and opens System Settings. None of that
/// can run headless or be unit-tested. But the *decisions* it makes about what to
/// show — the status line, the colour of the live status dot, whether the primary
/// button is enabled, and what troubleshooting hint (if any) to surface — are a
/// simple, total function of the permission `State`. If that mapping lives inline
/// in the AppKit code it silently drifts: a tweak to the `.denied` copy forgets
/// the matching VoiceOver label, or a colour changes without the dot's textual
/// meaning following it.
///
/// So the mapping (and every user-facing string) is hoisted here as a pure value
/// type with no AppKit dependency. `OnboardingCopyTests` pins it down for all
/// three states, which makes the window's behaviour verifiable without ever
/// presenting a window, firing the system modal, or touching TCC.
///
/// Accessibility is a first-class concern of this mapping, not an afterthought in
/// the view layer: the status dot communicates state by colour alone, which is
/// invisible to colour-blind users and to VoiceOver. Every `Presentation`
/// therefore carries a `statusAccessibilityLabel` that states the meaning in
/// words ("Waiting", "Granted", "Action needed") so the dot is decorative and the
/// label is authoritative.
enum OnboardingCopy {

    // MARK: - Static copy (single source of truth, so window + tests can't drift)

    /// Window title bar.
    static let windowTitle = "Set up ScrollWM"

    /// Big headline inside the window.
    static let heading = "Turn on Accessibility"

    /// One-line explanation under the headline.
    static let subheading = "It's the one permission ScrollWM needs to move your windows."

    /// The numbered steps, in order. These mirror exactly what the user sees in
    /// the Accessibility pane opened beside this window, and the final step
    /// reflects the real first-grant behaviour: ScrollWM auto-arranges the open
    /// windows the instant the toggle flips (see `arrangeOnFirstGrant`).
    static let steps: [String] = [
        "Find ScrollWM in the list on the right.",
        "Flip its switch ON.",
        "Done — your windows arrange instantly.",
    ]

    /// Primary action button: (re)opens the exact Settings pane.
    static let primaryButtonTitle = "Open Accessibility Settings"

    /// Secondary action: reveal the .app so the user can drag it into the list.
    static let revealButtonTitle = "Show in Finder"

    /// Tooltip explaining when "Show in Finder" helps.
    static let revealButtonTooltip =
        "If ScrollWM isn't in the list, drag it from here into the Accessibility list."

    /// Quiet escape-hatch button: copy plain setup steps for an AI assistant.
    static let copyAgentButtonTitle = "Copy setup steps for my AI assistant"

    /// Inline confirmation shown after copying the agent instructions.
    static let copiedConfirmation = "Copied. Paste this to your AI assistant for step-by-step help."

    // MARK: - Status dot colour (named, not an NSColor — keeps this AppKit-free)

    /// A semantic colour for the live status dot. The window maps each case to a
    /// concrete system colour that reads correctly in both light and dark mode;
    /// keeping it semantic here means the *meaning* is testable and the dot is
    /// never the only carrier of that meaning (see `statusAccessibilityLabel`).
    enum DotColor: String, Equatable {
        /// Neutral / idle: we are simply waiting for the user to act.
        case neutral
        /// Success: Accessibility is granted.
        case success
        /// Attention: Accessibility is explicitly off; the user needs to act.
        case warning
    }

    // MARK: - The pure state -> presentation mapping

    /// Everything the window needs to render for a given permission state.
    struct Presentation: Equatable {
        /// Visible status-row text.
        let statusText: String
        /// VoiceOver label for the status row. Always leads with an explicit
        /// state word so the dot's colour is never the only signal.
        let statusAccessibilityLabel: String
        /// Semantic dot colour.
        let dotColor: DotColor
        /// Troubleshooting hint, or `nil` when no hint should be shown.
        let troubleshootingText: String?
        /// Whether the primary "Open Accessibility Settings" button is enabled.
        /// Disabled only once granted, when there is nothing left to do.
        let primaryButtonEnabled: Bool
    }

    /// The single, total mapping from permission state to what the window shows.
    ///
    /// - `.granted`     → green dot, success copy, primary disabled (done).
    /// - `.notDetermined` → neutral dot, "waiting" copy, primary enabled, no hint.
    /// - `.denied`      → orange dot, "off" copy, primary enabled, toggle hint.
    static func presentation(for state: AccessibilityPermission.State) -> Presentation {
        switch state {
        case .granted:
            return Presentation(
                statusText: "Granted — arranging your windows…",
                statusAccessibilityLabel:
                    "Granted. Accessibility is on for ScrollWM; arranging your windows.",
                dotColor: .success,
                troubleshootingText: nil,
                primaryButtonEnabled: false
            )
        case .notDetermined:
            return Presentation(
                statusText: "Waiting for you to enable ScrollWM…",
                statusAccessibilityLabel:
                    "Waiting. ScrollWM is not yet enabled in Accessibility settings.",
                dotColor: .neutral,
                troubleshootingText: nil,
                primaryButtonEnabled: true
            )
        case .denied:
            return Presentation(
                statusText: "Accessibility is off for ScrollWM.",
                statusAccessibilityLabel:
                    "Action needed. Accessibility is currently off for ScrollWM.",
                dotColor: .warning,
                troubleshootingText:
                    "If ScrollWM is already in the list, toggle it OFF then ON to refresh the grant.",
                primaryButtonEnabled: true
            )
        }
    }

    // MARK: - "Show in Finder" applicability (pure)

    /// Whether "Show in Finder" should do anything, given the main bundle's path
    /// extension. It only makes sense for a real `.app` bundle the user can drag
    /// into the Accessibility list. For the dev binary (`.build/debug/WindowLab`,
    /// no extension) it must be a no-op, so we never reveal a bare executable.
    static func shouldRevealInFinder(bundlePathExtension: String) -> Bool {
        bundlePathExtension == "app"
    }

    // MARK: - Agent instructions (pure copy)

    /// Plain instructions any already-installed coding/assistant agent can act on.
    /// This is an optional escape hatch, never a dependency.
    ///
    /// Accuracy matters: this text is read by another agent and acted on verbatim,
    /// so it must match real behaviour. ScrollWM does NOT stay fully dormant after
    /// the first grant — `arrangeOnFirstGrant` (default on) arranges the open
    /// windows once the instant the toggle flips, which is exactly the "your
    /// windows arrange instantly" promise the onboarding makes. After that first
    /// arrange it is dormant until the user re-invokes arrange from the menu bar.
    static let agentInstructions = """
    Help me enable the macOS Accessibility permission for an app called "ScrollWM".

    ScrollWM is a scrolling window manager. It needs exactly one permission —
    Accessibility — to move windows. Steps:

    1. Open System Settings > Privacy & Security > Accessibility.
       (URL scheme: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility)
    2. Find "ScrollWM" in the list and turn its switch ON.
    3. If "ScrollWM" is present but the switch was already on, toggle it OFF
       then ON again — a stale entry from a previous build can block the grant.
    4. No relaunch is needed: ScrollWM detects the grant automatically. On this
       first grant it arranges the open windows once into its strip (its first
       visible act). After that it stays dormant and only rearranges when I pick
       "Arrange Windows into Strip" from its menu bar icon.

    Do not attempt to flip the switch yourself; macOS requires me to do it.
    Just walk me through the clicks and confirm when the switch is on.
    """
}
