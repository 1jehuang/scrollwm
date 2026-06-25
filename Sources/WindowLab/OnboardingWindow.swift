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
///   - Reassure: ScrollWM stays dormant; nothing moves until the first grant.
///   - Auto-continue the instant the toggle flips — no relaunch, no re-ask.
///   - Optional escape hatch for the stuck case: copy setup instructions an
///     AI assistant the user already has can act on.
///   - Accessible: every control is labelled, the status dot's meaning is
///     spoken (not colour-only), and focus order is top-to-bottom.
///
/// All the *copy* and the state → presentation decisions live in the pure
/// `OnboardingCopy` enum so they are unit-tested and cannot drift from the view.
/// This file is the thin, impure AppKit shell around that logic.
///
/// All work happens on the main thread (AppKit), driven by the permission
/// coordinator's main-thread callbacks.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let permission = AccessibilityPermission.shared
    private var window: NSWindow?

    private var statusLabel: NSTextField?
    private var statusRow: NSView?
    private var statusDot: NSView?
    private var primaryButton: NSButton?
    private var revealButton: NSButton?
    private var copyAgentButton: NSButton?
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
        // Sane focus order: land keyboard focus on the primary action.
        window?.makeFirstResponder(primaryButton)
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
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = OnboardingCopy.windowTitle
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
        // Pin the stack on all four edges. Pinning the BOTTOM (equal, not
        // less-than) makes the content view's fitting height track the stack, so
        // the window can size itself to the content and never clip the last row.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Title — short and clear.
        let title = label(OnboardingCopy.heading, font: .systemFont(ofSize: 19, weight: .bold))
        title.setAccessibilityRole(.staticText)
        stack.addArrangedSubview(title)

        let subtitle = label(OnboardingCopy.subheading, font: .systemFont(ofSize: 13))
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
        for (i, text) in OnboardingCopy.steps.enumerated() {
            steps.addArrangedSubview(stepRow(i + 1, text))
        }
        stack.addArrangedSubview(steps)

        // Live status row: dot + text. The dot is colour; the *meaning* is
        // carried by the row's accessibility label so it survives colour
        // blindness and VoiceOver. The dot view itself is hidden from a11y.
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 5
        dot.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])
        let status = label(OnboardingCopy.presentation(for: .notDetermined).statusText,
                           font: .systemFont(ofSize: 13, weight: .semibold))
        statusRow.addArrangedSubview(dot)
        statusRow.addArrangedSubview(status)
        // Group the dot + text into one a11y element with a spoken meaning.
        statusRow.setAccessibilityElement(true)
        statusRow.setAccessibilityRole(.staticText)
        stack.addArrangedSubview(statusRow)
        self.statusDot = dot
        self.statusLabel = status
        self.statusRow = statusRow

        // Troubleshooting line (shown only when denied / after copying steps).
        let trouble = label("", font: .systemFont(ofSize: 12))
        trouble.textColor = .systemOrange
        trouble.isHidden = true
        stack.addArrangedSubview(trouble)
        self.troubleshootLabel = trouble

        // Button row — primary reopens the pane; the rest are escape hatches.
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        let primary = NSButton(title: OnboardingCopy.primaryButtonTitle,
                               target: self, action: #selector(openSettings))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.setAccessibilityLabel(OnboardingCopy.primaryButtonTitle)
        let reveal = NSButton(title: OnboardingCopy.revealButtonTitle,
                              target: self, action: #selector(revealInFinder))
        reveal.bezelStyle = .rounded
        reveal.toolTip = OnboardingCopy.revealButtonTooltip
        reveal.setAccessibilityLabel(OnboardingCopy.revealButtonTitle)
        reveal.setAccessibilityHelp(OnboardingCopy.revealButtonTooltip)
        buttonRow.addArrangedSubview(primary)
        buttonRow.addArrangedSubview(reveal)
        stack.addArrangedSubview(buttonRow)
        self.primaryButton = primary
        self.revealButton = reveal

        // Quiet escape hatch on its own line so the main flow stays clean.
        let copyForAgent = NSButton(title: OnboardingCopy.copyAgentButtonTitle,
                                    target: self, action: #selector(copyAgentInstructions))
        copyForAgent.bezelStyle = .inline
        copyForAgent.controlSize = .small
        copyForAgent.contentTintColor = .secondaryLabelColor
        copyForAgent.setAccessibilityLabel(OnboardingCopy.copyAgentButtonTitle)
        copyForAgent.setAccessibilityHelp("Copies plain setup steps to the clipboard for an AI assistant.")
        stack.addArrangedSubview(copyForAgent)
        self.copyAgentButton = copyForAgent

        win.contentView = content
        // Size the window to fit its content so nothing clips in either mode.
        win.setContentSize(stack.fittingSize)
        self.window = win

        // Sane focus order: title region → steps → primary, reveal, copy.
        win.initialFirstResponder = primary
        primary.nextKeyView = reveal
        reveal.nextKeyView = copyForAgent
        copyForAgent.nextKeyView = primary
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
        badge.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),
        ])
        let textField = label(text, font: .systemFont(ofSize: 13, weight: .medium))
        textField.preferredMaxLayoutWidth = 300
        row.addArrangedSubview(badge)
        row.addArrangedSubview(textField)
        // Speak the step as one element: "Step 1: Find ScrollWM…".
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel("Step \(n): \(text)")
        return row
    }

    private func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.isEditable = false
        field.isSelectable = true
        field.drawsBackground = false
        field.isBezeled = false
        field.preferredMaxLayoutWidth = 352
        return field
    }

    // MARK: - State application

    private func apply(state: AccessibilityPermission.State) {
        let p = OnboardingCopy.presentation(for: state)

        statusDot?.layer?.backgroundColor = Self.cgColor(for: p.dotColor)
        statusLabel?.stringValue = p.statusText
        statusLabel?.textColor = Self.textColor(for: p.dotColor)
        // The dot is colour-only; the row's a11y label states the meaning so it
        // is conveyed beyond colour to VoiceOver / colour-blind users.
        statusRow?.setAccessibilityLabel(p.statusAccessibilityLabel)

        if let trouble = p.troubleshootingText {
            troubleshootLabel?.stringValue = trouble
            troubleshootLabel?.textColor = .systemOrange
            troubleshootLabel?.isHidden = false
        } else {
            troubleshootLabel?.isHidden = true
        }

        primaryButton?.isEnabled = p.primaryButtonEnabled

        guard state == .granted else { return }
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
    }

    /// Concrete dot fill for a semantic colour. System colours so they read
    /// correctly in light AND dark mode.
    private static func cgColor(for dot: OnboardingCopy.DotColor) -> CGColor {
        switch dot {
        case .neutral: return NSColor.systemGray.cgColor
        case .success: return NSColor.systemGreen.cgColor
        case .warning: return NSColor.systemOrange.cgColor
        }
    }

    /// Status-text colour matching the dot's semantics. Neutral uses the
    /// secondary label colour (adaptive) rather than a fixed grey.
    private static func textColor(for dot: OnboardingCopy.DotColor) -> NSColor {
        switch dot {
        case .neutral: return .secondaryLabelColor
        case .success: return .systemGreen
        case .warning: return .systemOrange
        }
    }

    // MARK: - Actions

    @objc private func openSettings() {
        permission.openSystemSettings()
    }

    /// Reveal ScrollWM.app in Finder so the user can drag it directly into the
    /// Accessibility list when the system prompt didn't pre-populate it (a
    /// common case for downloaded copies). No-op for the dev binary (decided by
    /// the pure `OnboardingCopy.shouldRevealInFinder`).
    @objc private func revealInFinder() {
        let bundleURL = Bundle.main.bundleURL
        guard OnboardingCopy.shouldRevealInFinder(bundlePathExtension: bundleURL.pathExtension) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }

    @objc private func copyAgentInstructions() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(OnboardingCopy.agentInstructions, forType: .string)
        // Brief inline confirmation.
        troubleshootLabel?.isHidden = false
        troubleshootLabel?.textColor = .systemBlue
        troubleshootLabel?.stringValue = OnboardingCopy.copiedConfirmation
    }

    /// Plain instructions any already-installed coding/assistant agent can act
    /// on. This is an optional escape hatch, never a dependency. Kept here as a
    /// compatibility alias; the source of truth is `OnboardingCopy`.
    static var agentInstructions: String { OnboardingCopy.agentInstructions }
}
