import Foundation
import AppKit

/// First-run onboarding for ScrollWM's single permission.
///
/// Shown ONLY when the permission coordinator has decided we are genuinely
/// untrusted after the launch grace window (state `.notDetermined` or
/// `.denied`). It is never shown when permission is already granted, even if
/// the very first `AXIsProcessTrusted()` reading was a stale `false`.
///
/// Design goals (easy + understandable onboarding):
///   - Say plainly what ScrollWM does and why exactly one permission is needed.
///   - One primary action: open the right Settings pane.
///   - Reassure: ScrollWM stays dormant; nothing moves until you Arrange.
///   - Auto-continue the instant the toggle flips — no relaunch, no re-ask.
///   - Optional escape hatch for the stuck case: copy setup instructions an
///     AI assistant the user already has can act on.
///
/// All work happens on the main thread (AppKit), driven by the permission
/// coordinator's main-thread callbacks.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let permission = AccessibilityPermission.shared
    private var window: NSWindow?

    private var statusLabel: NSTextField?
    private var statusDot: NSView?
    private var primaryButton: NSButton?
    private var troubleshootLabel: NSTextField?

    /// True while we have hidden the user's other apps to focus onboarding, so
    /// we know to restore them when the window goes away.
    private var didHideOthers = false

    /// Guards the one-time granted hook so the live observer can re-deliver
    /// `.granted` without arranging twice.
    private var didFinish = false

    /// Invoked once, on the main thread, when permission becomes granted.
    var onGranted: (() -> Void)?

    func present() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        buildWindow()

        // Focus the user on exactly two things: these instructions and the
        // Accessibility toggle. Hide every other app so the desktop is calm,
        // pin this window to the LEFT edge, and open the Accessibility pane on
        // the right (its per-row switches sit on the right, clear of our
        // left-pinned window). Hidden apps are restored automatically on grant
        // or whenever this window closes.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.hideOtherApplications(nil)
        didHideOthers = true
        positionLeftEdge()

        // Fire the system modal ONLY on a genuine first run (untrusted and
        // never asked before). On any later launch we deep-link to Settings and
        // poll instead, so a stale-`false` reading or a TCC hiccup can never
        // re-spam the "turn on Accessibility" dialog when it's already enabled.
        if AccessibilityPermission.shouldAutoPrompt(isTrusted: permission.isTrustedNow,
                                                    hasPrompted: permission.hasPrompted) {
            _ = permission.requestSystemPrompt()
        }
        // Always land the user on the exact pane with the switch, on the right.
        permission.openSystemSettings()

        // React live: the moment trust appears, finish onboarding.
        permission.observe { [weak self] state in
            self?.apply(state: state)
        }
        apply(state: permission.state)

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        // windowWillClose restores the hidden apps; closing fires it.
        window?.close()
        window = nil
    }

    /// Pin the onboarding window to the left edge of the main screen, centered
    /// vertically, so it sits beside the Settings window instead of over it.
    private func positionLeftEdge() {
        guard let win = window, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        var frame = win.frame
        frame.origin.x = vf.minX + 28
        frame.origin.y = vf.midY - frame.height / 2
        win.setFrame(frame, display: true)
    }

    /// Restore the apps we hid for focus when onboarding goes away (granted,
    /// dismissed, or closed by the user). Safe to call more than once.
    func windowWillClose(_ notification: Notification) {
        if didHideOthers {
            NSApp.unhideAllApplications(nil)
            didHideOthers = false
        }
    }

    // MARK: - UI construction

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Set up ScrollWM"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.delegate = self

        let content = NSView(frame: win.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])

        // Title — short and clear.
        let title = label("Turn on Accessibility", font: .systemFont(ofSize: 19, weight: .bold))
        stack.addArrangedSubview(title)

        let subtitle = label("It's the one permission ScrollWM needs to move your windows.",
                             font: .systemFont(ofSize: 13))
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)

        // Numbered steps — the whole point: dead simple, super concise. These
        // match exactly what the user sees in the Settings pane opened to the
        // right of this window.
        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 10
        steps.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        steps.addArrangedSubview(stepRow(1, "Find ScrollWM in the list on the right."))
        steps.addArrangedSubview(stepRow(2, "Flip its switch ON."))
        steps.addArrangedSubview(stepRow(3, "Done — your windows arrange instantly."))
        stack.addArrangedSubview(steps)

        // Live status row: dot + text.
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 5
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])
        let status = label("Waiting for the switch…", font: .systemFont(ofSize: 13, weight: .semibold))
        statusRow.addArrangedSubview(dot)
        statusRow.addArrangedSubview(status)
        stack.addArrangedSubview(statusRow)
        self.statusDot = dot
        self.statusLabel = status

        // Troubleshooting line (shown only when denied).
        let trouble = label("", font: .systemFont(ofSize: 12))
        trouble.textColor = .systemOrange
        trouble.isHidden = true
        stack.addArrangedSubview(trouble)
        self.troubleshootLabel = trouble

        // Button row — primary reopens the pane; the rest are escape hatches.
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        let primary = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openSettings))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealInFinder))
        reveal.bezelStyle = .rounded
        reveal.toolTip = "If ScrollWM isn't in the list, drag it from here into the Accessibility list."
        buttonRow.addArrangedSubview(primary)
        buttonRow.addArrangedSubview(reveal)
        stack.addArrangedSubview(buttonRow)
        self.primaryButton = primary

        // Quiet escape hatch on its own line so the main flow stays clean.
        let copyForAgent = NSButton(title: "Copy setup steps for my AI assistant", target: self, action: #selector(copyAgentInstructions))
        copyForAgent.bezelStyle = .inline
        copyForAgent.controlSize = .small
        copyForAgent.contentTintColor = .secondaryLabelColor
        stack.addArrangedSubview(copyForAgent)

        win.contentView = content
        self.window = win
    }

    /// A "① text" step row: a circled number badge beside a concise line.
    private func stepRow(_ n: Int, _ text: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 9
        let badge = label("\(n)", font: .systemFont(ofSize: 13, weight: .bold))
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 10
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),
        ])
        let text = label(text, font: .systemFont(ofSize: 13, weight: .medium))
        text.preferredMaxLayoutWidth = 290
        row.addArrangedSubview(badge)
        row.addArrangedSubview(text)
        return row
    }

    private func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.isEditable = false
        field.isSelectable = true
        field.drawsBackground = false
        field.isBezeled = false
        field.preferredMaxLayoutWidth = 404
        return field
    }

    // MARK: - State application

    private func apply(state: AccessibilityPermission.State) {
        switch state {
        case .granted:
            statusDot?.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusLabel?.stringValue = "Granted — arranging your windows…"
            statusLabel?.textColor = .systemGreen
            troubleshootLabel?.isHidden = true
            primaryButton?.isEnabled = false
            // Fire the granted hook exactly once (the observer can re-deliver
            // .granted), restore the apps we hid, and auto-continue with no
            // relaunch. Brief beat so the user sees the green confirmation.
            guard !didFinish else { return }
            didFinish = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.onGranted?()
                self.close()
            }
        case .notDetermined:
            statusDot?.layer?.backgroundColor = NSColor.systemGray.cgColor
            statusLabel?.stringValue = "Waiting for you to enable ScrollWM…"
            statusLabel?.textColor = .secondaryLabelColor
            troubleshootLabel?.isHidden = true
            primaryButton?.isEnabled = true
        case .denied:
            statusDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusLabel?.stringValue = "Accessibility is off for ScrollWM."
            statusLabel?.textColor = .systemOrange
            troubleshootLabel?.stringValue =
                "If ScrollWM is already in the list, toggle it OFF then ON to refresh the grant."
            troubleshootLabel?.isHidden = false
            primaryButton?.isEnabled = true
        }
    }

    // MARK: - Actions

    @objc private func openSettings() {
        permission.openSystemSettings()
    }

    /// Reveal ScrollWM.app in Finder so the user can drag it directly into the
    /// Accessibility list when the system prompt didn't pre-populate it (a
    /// common case for downloaded copies). No-op for the dev binary.
    @objc private func revealInFinder() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }

    @objc private func copyAgentInstructions() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.agentInstructions, forType: .string)
        // Brief inline confirmation.
        troubleshootLabel?.isHidden = false
        troubleshootLabel?.textColor = .systemBlue
        troubleshootLabel?.stringValue = "Copied. Paste this to your AI assistant for step-by-step help."
    }

    /// Plain instructions any already-installed coding/assistant agent can act
    /// on. This is an optional escape hatch, never a dependency.
    static let agentInstructions = """
    Help me enable the macOS Accessibility permission for an app called "ScrollWM".

    ScrollWM is a scrolling window manager. It needs exactly one permission —
    Accessibility — to move windows. Steps:

    1. Open System Settings > Privacy & Security > Accessibility.
       (URL scheme: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility)
    2. Find "ScrollWM" in the list and turn its switch ON.
    3. If "ScrollWM" is present but the switch was already on, toggle it OFF
       then ON again — a stale entry from a previous build can block the grant.
    4. No relaunch is needed: ScrollWM detects the grant automatically and
       starts in a dormant state (it will not move any window until I choose
       "Arrange" from its menu bar icon).

    Do not attempt to flip the switch yourself; macOS requires me to do it.
    Just walk me through the clicks and confirm when the switch is on.
    """
}
