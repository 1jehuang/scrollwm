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
final class OnboardingWindowController: NSObject {
    private let permission = AccessibilityPermission.shared
    private var window: NSWindow?

    private var statusLabel: NSTextField?
    private var statusDot: NSView?
    private var primaryButton: NSButton?
    private var troubleshootLabel: NSTextField?

    /// Invoked once, on the main thread, when permission becomes granted.
    var onGranted: (() -> Void)?

    func present() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        buildWindow()
        // Fire the system prompt once so ScrollWM appears in the list.
        if permission.state != .granted {
            _ = permission.requestSystemPrompt()
        }
        // React live: the moment trust appears, finish onboarding.
        permission.observe { [weak self] state in
            self?.apply(state: state)
        }
        apply(state: permission.state)

        window?.makeKeyAndOrderFront(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    // MARK: - UI construction

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to ScrollWM"
        win.isReleasedWhenClosed = false
        win.level = .floating

        let content = NSView(frame: win.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])

        // Title.
        let title = label("ScrollWM needs one permission", font: .systemFont(ofSize: 18, weight: .bold))
        stack.addArrangedSubview(title)

        // Explanation.
        let body = label(
            "ScrollWM arranges your windows into a scrolling strip. To move "
            + "windows for you, macOS requires the Accessibility permission — "
            + "this one switch is the only thing ScrollWM ever needs. No screen "
            + "recording, no input monitoring.",
            font: .systemFont(ofSize: 13)
        )
        body.textColor = .secondaryLabelColor
        stack.addArrangedSubview(body)

        // Reassurance.
        let calm = label(
            "Nothing moves yet. ScrollWM stays dormant until you choose Arrange.",
            font: .systemFont(ofSize: 12, weight: .medium)
        )
        calm.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(calm)

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
        let status = label("Checking permission…", font: .systemFont(ofSize: 13, weight: .semibold))
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

        // Button row.
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        let primary = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openSettings))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        let copyForAgent = NSButton(title: "Copy setup steps for my AI assistant", target: self, action: #selector(copyAgentInstructions))
        copyForAgent.bezelStyle = .rounded
        buttonRow.addArrangedSubview(primary)
        buttonRow.addArrangedSubview(copyForAgent)
        stack.addArrangedSubview(buttonRow)
        self.primaryButton = primary

        win.contentView = content
        self.window = win
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
            statusLabel?.stringValue = "Granted — ScrollWM is ready."
            statusLabel?.textColor = .systemGreen
            troubleshootLabel?.isHidden = true
            primaryButton?.isEnabled = false
            // Auto-continue, no relaunch. Briefly let the user see the green.
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
