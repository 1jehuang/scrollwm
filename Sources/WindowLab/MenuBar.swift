import Foundation
import AppKit

/// Menu bar presence for the teleport tier:
/// - status item icon is a LIVE MINI-MAP of the strip (focus + viewport drawn)
/// - menu lists all windows; selecting one teleports to it
/// - shows last teleport latency and permission tier
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let engine: TeleportEngine
    private let onSelectIndex: (Int) -> Void
    private let onQuit: () -> Void

    /// High-refresh animated mini-map (springs + per-action flourishes).
    private let stripView = MenuBarStripView(frame: NSRect(x: 0, y: 0, width: 46, height: 22))

    /// Width of the mini-map. Kept modest so we fit on notched MacBooks,
    /// where macOS silently hides items that don't fit.
    static let mapWidth: CGFloat = 46

    /// Autosave identity for position persistence.
    static let autosaveName = "ScrollWMMiniMap"

    init(engine: TeleportEngine, onSelectIndex: @escaping (Int) -> Void, onQuit: @escaping () -> Void) {
        self.engine = engine
        self.onSelectIndex = onSelectIndex
        self.onQuit = onQuit
        super.init()

        // Notch workaround: macOS inserts NEW status items at the left end of
        // the status area. On notched screens with several items, that slot can
        // be parked offscreen (frame.x goes negative) instead of overlapping
        // the notch. Seeding a preferred position (measured from the RIGHT
        // screen edge) before creation makes the item land in visible space.
        // Harmless on non-notched displays; user drags still override it.
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(400.0, forKey: positionKey)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: Self.mapWidth + 4)
        statusItem.autosaveName = NSStatusItem.AutosaveName(Self.autosaveName)
        if let button = statusItem.button {
            button.image = nil
            stripView.frame = button.bounds
            stripView.autoresizingMask = [.width, .height]
            button.addSubview(stripView)
        }
        // The teleport tier is always "managing" (it adopts on launch).
        stripView.apply(state: engine.stripState, managing: true)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.onLayoutChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshIcon() }
        }
    }

    func refreshIcon() {
        stripView.apply(state: engine.stripState, managing: true)
    }

    /// Visibility check: notch-parked items report negative x. We verify the
    /// item's backing window actually landed in visible screen space.
    var isVisibleInMenuBar: Bool {
        guard statusItem.isVisible, let window = statusItem.button?.window else { return false }
        let frame = window.frame
        guard frame.width > 0, frame.origin.x >= 0 else { return false }
        // Also reject the notch shadow zone if one exists.
        if let screen = NSScreen.main,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = CGRect(x: left.maxX, y: frame.origin.y, width: right.minX - left.maxX, height: frame.height)
            if frame.intersects(notch) { return false }
        }
        return true
    }

    var debugDescription2: String {
        let visible = statusItem.isVisible
        let frame = statusItem.button?.window?.frame ?? .zero
        return "statusItem visible=\(visible) windowFrame=\(frame)"
    }

    // MARK: - NSMenuDelegate (menu built fresh on every open: always live)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = engine.stripState

        let header = NSMenuItem(
            title: String(format: "Strip: %d windows  ·  last teleport %.1f ms",
                          state.slots.count, state.lastTeleportMs),
            action: nil, keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for (i, slot) in state.slots.enumerated() {
            let inViewport = slot.canvasX + slot.width > state.viewportX
                && slot.canvasX < state.viewportX + state.viewportWidth
            let marker = i == state.focusIndex ? "● " : (inViewport ? "○ " : "   ")
            let title = "\(marker)\(slot.appName) — \(slot.title)"
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(menuSelect(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
            item.tag = i
            if !slot.healthy {
                item.attributedTitle = NSAttributedString(
                    string: String(title.prefix(60)),
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let permItem = NSMenuItem(
            title: "Tier: Teleport (Accessibility only)",
            action: nil, keyEquivalent: ""
        )
        permItem.isEnabled = false
        menu.addItem(permItem)

        let quitItem = NSMenuItem(title: "Quit WindowLab", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func menuSelect(_ sender: NSMenuItem) {
        onSelectIndex(sender.tag)
    }

    @objc private func quit() {
        onQuit()
    }
}
