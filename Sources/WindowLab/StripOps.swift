import Foundation
import ApplicationServices
import AppKit

/// Window operations on the focused column: resize to a fraction of the
/// usable width, reorder within the strip, and close.
///
/// All operations are pure AX (no extra permission) and keep the strip's
/// canvas model consistent: after any geometry change we recompact columns
/// left-to-right and re-teleport so the viewport stays coherent.
extension TeleportEngine {

    /// Standard column-width presets, as fractions of the usable strip width.
    /// Index maps to the Alt+1..4 hotkeys.
    static let widthPresets: [CGFloat] = [0.25, 0.50, 0.75, 1.0]

    /// Width in points for a given fraction of the viewport.
    ///
    /// The strip lays columns out as `gap | col | gap | col | ... | gap`, i.e.
    /// a `gap` margin on both outer edges and a `gap` between every column,
    /// INSIDE the usable content region `V = contentWidth` (the screen minus a
    /// `peekInset` peek lane on each side). For a fraction `f = 1/N` we want
    /// exactly `N` columns to tile the content region:
    ///
    ///   leftMargin + N*w + (N-1)*gap + rightMargin = V,  margins == gap
    ///     => N*w = V - (N+1)*gap
    ///     => w   = f*(V - gap) - gap        (with f = 1/N)
    ///
    /// So `width(0.5)` fits exactly two columns (both with a `gap` on the
    /// outside and a `gap` between them), `width(0.25)` fits four, and
    /// `width(1.0) == V - 2*gap` fills the content region with a symmetric
    /// margin. With `peekInset == 0`, `V == screenFrame.width` (old behavior).
    /// Clamped to a sane minimum so a window can never collapse to nothing.
    func width(forFraction fraction: CGFloat) -> CGFloat {
        let clamped = max(0.05, min(1.0, fraction))
        let w = clamped * (contentWidth - gap) - gap
        return max(minColumnWidth, w.rounded())
    }

    /// Resize the focused column to a fraction of the usable width.
    /// Returns false when there is nothing focused.
    ///
    /// Many apps enforce a minimum window size (e.g. Apple Music, Calendar,
    /// System Settings) and silently clamp any `setSize` smaller than their
    /// floor. Crucially, AX usually still reports `.success` for the set: the
    /// attribute write "succeeded", the app just overrode the value afterward.
    /// So we cannot trust either the requested width OR the AX error code.
    /// Instead we ALWAYS read back the real size and store that, so the strip
    /// model never diverges from reality (which would otherwise make compacted
    /// columns overlap and the viewport mini-map drift).
    @discardableResult
    func setFocusedWidth(fraction: CGFloat) -> Bool {
        // Honor the window the user is REALLY on: focus may have moved outside
        // ScrollWM (mouse click, Cmd+Tab) since our last navigation, so the
        // engine's `focusIndex` can be stale. Without this, pressing a width key
        // after clicking a window on the right would resize the LAST column
        // ScrollWM navigated to and never scroll the viewport to the window the
        // user is actually looking at - the exact "the window on the right does
        // not size up / the viewport does not follow it" symptom. Same fix as
        // `closeFocused`'s focus reconcile.
        syncFocusToSystemFocusedWindow()
        guard slots.indices.contains(focusIndex) else { return false }
        let requestedWidth = width(forFraction: fraction)

        let slot = slots[focusIndex]
        if slot.window.healthy {
            // Optimistically update the model so a missing/stale readback still
            // reflects the user's intent. Safe ONLY for a healthy window: the
            // immediate readback below plus `scheduleWidthReconcile` and the
            // periodic resync all pull the model back to the real frame, so any
            // optimism is short-lived.
            slots[focusIndex].width = requestedWidth
            // Aspect-locked apps (notably QuickTime Player movie windows) may
            // refuse a wider width if the paired height stays at the old short
            // value. In fill-height mode, ask for the full column height at the
            // SAME time as the width so the app has enough vertical room to
            // preserve its aspect ratio while growing horizontally.
            let requestedHeight = fillHeight ? screenFrame.height : slot.height

            // CRUCIAL ORDERING: move the window to where the (wider) column will
            // sit BEFORE resizing it. macOS/AppKit curtails an in-place resize at
            // the display's visible-frame edge (`constrainFrameRect`), so a window
            // anchored near the RIGHT edge could otherwise only grow until its
            // right edge met the screen edge - the reported "expand to 100% only
            // fills to the viewport edge instead of resizing the window fully and
            // scrolling to it" bug. Re-pack with the requested width, compute the
            // focused column's scrolled (left-anchored) on-screen origin, and
            // place the window there first, giving it room to the right to reach
            // the full requested width. The viewport then follows it into view.
            compactStrip()
            let preViewportX = clampViewportX(
                viewportTarget(for: slots[focusIndex], mode: focusMode, currentViewportX: viewportX))
            let preTarget = CGPoint(x: contentOriginX + slots[focusIndex].canvasX - preViewportX,
                                    y: slots[focusIndex].y)
            let needsMove = slot.window.lastCommittedOrigin.map {
                abs($0.x - preTarget.x) > 0.5 || abs($0.y - preTarget.y) > 0.5
            } ?? true
            if needsMove,
               AXSource.setPoint(slot.window.element, kAXPositionAttribute as String, preTarget) == .success {
                slot.window.lastCommittedOrigin = preTarget
            }

            _ = AXSource.setSize(
                slot.window.element,
                kAXSizeAttribute as String,
                CGSize(width: requestedWidth, height: requestedHeight)
            )
            // Reconcile against the live frame: an app that clamps to its own
            // minimum reports success but keeps a larger size, and an app that
            // resizes ASYNCHRONOUSLY reports success while the new frame lands a
            // few run-loop turns later (so this read can be the OLD size).
            // Either way we store the REAL current width and never the request;
            // `scheduleWidthReconcile` below keeps watching until the resize
            // settles and follows the viewport to it, so a window growing toward
            // 100% scrolls fully into view once it actually reaches its new size
            // (rather than the stale-small read leaving it spilling off the edge).
            if let actual = AXSource.copySize(slot.window.element, kAXSizeAttribute as String) {
                slots[focusIndex].width = actual.width
                slots[focusIndex].height = actual.height
            }
        }
        // For an UNHEALTHY window we deliberately do NOT touch the model: there
        // is no AX write and no readback, so writing `requestedWidth` would be a
        // pure lie that strands the column at a width the real window never
        // adopts (the exact "all columns claim 717 but 5 are really 735"
        // desync). Keep the last known real size; the resync size-reconcile
        // will refresh it if/when the window becomes reachable again.

        compactStrip()
        focus(index: focusIndex) // re-centers viewport on the resized column
        onLayoutChange?()

        // Many apps resize ASYNCHRONOUSLY (and some animate), so the readback
        // above can still report the OLD size: AX returns `.success` for the
        // set, but the new frame is not visible until a later run-loop turn. If
        // we trusted only the immediate readback, a window that grows wider than
        // the viewport would never get the viewport scrolled to reveal it (the
        // model still thinks it is small, so `fit` sees no overflow). So we
        // re-read the live size shortly after and, if it changed, re-pack and
        // re-fit the viewport to the focused column. This is what makes the
        // viewport follow a grown window to full visibility.
        if slot.window.healthy {
            scheduleWidthReconcile(for: slot.window,
                                   targetWidth: requestedWidth,
                                   startWidth: slots[focusIndex].width)
        }
        return true
    }

    /// After an async resize, re-read the real size of `window` and, if it no
    /// longer matches the model, update the model, re-pack the strip, and (when
    /// the window is still focused) re-fit the viewport so it follows the new
    /// size.
    ///
    /// Polling is ADAPTIVE rather than a fixed-length budget: apps settle at
    /// wildly different rates (instant, a few frames, or a multi-hundred-ms
    /// animation), and a fixed budget that expires before a slow app finishes
    /// left the model stuck at the OLD width - so a focused window grown toward
    /// 100% never scrolled into view and just spilled off the right edge (the
    /// reported bug). Instead we keep following until either the live width
    /// REACHES the requested `targetWidth` (when known), the size SETTLES (it has
    /// moved away from `startWidth` and then held steady across two consecutive
    /// polls -> the app finished resizing or clamped to its own minimum), or a
    /// wall-clock safety `deadline` passes. Crucially we do NOT stop while the
    /// width still equals `startWidth`: a slow app that has not yet BEGUN its
    /// async resize looks deceptively "stable" at the old size, and an earlier
    /// fixed-attempt loop gave up there - the exact stuck-viewport bug. Each poll
    /// is a single cheap AX read, so even the bounded worst case is negligible.
    private func scheduleWidthReconcile(for window: ManagedWindowRef,
                                        targetWidth: CGFloat? = nil,
                                        startWidth: CGFloat = .nan,
                                        lastSeenWidth: CGFloat = -1,
                                        stableCount: Int = 0,
                                        deadline: Date? = nil,
                                        delay: TimeInterval = 0.05) {
        let deadline = deadline ?? Date().addingTimeInterval(1.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
            guard let self, let window, window.healthy else { return }
            guard let idx = self.slots.firstIndex(where: { $0.window === window }) else { return }
            guard let actual = AXSource.copySize(window.element, kAXSizeAttribute as String) else { return }

            let changed = abs(self.slots[idx].width - actual.width) > 1
                || abs(self.slots[idx].height - actual.height) > 1
            if changed {
                self.slots[idx].width = actual.width
                self.slots[idx].height = actual.height
                self.compactStrip()
                // Re-fit only when this window is the focused one; otherwise just
                // re-pack/teleport so the layout stays consistent.
                if idx == self.focusIndex {
                    self.refitViewportToFocused()
                } else {
                    self.teleport()
                    self.onLayoutChange?()
                }
            }

            // Stop once the resize has clearly finished: the live width reached
            // the requested target (when known), OR it has MOVED off the starting
            // width and then held steady across two consecutive polls (settled /
            // clamped), OR the safety deadline elapsed. The "moved" guard is what
            // stops us bailing out while a slow app is still sitting at its old
            // width before it begins resizing.
            let reachedTarget = targetWidth.map { abs(actual.width - $0) <= 1 } ?? false
            let hasMoved = startWidth.isNaN || abs(actual.width - startWidth) > 1
            let stable = lastSeenWidth >= 0 && abs(actual.width - lastSeenWidth) <= 1
            let nextStableCount = (hasMoved && stable) ? stableCount + 1 : 0
            if !reachedTarget && nextStableCount < 2 && Date() < deadline {
                self.scheduleWidthReconcile(for: window,
                                            targetWidth: targetWidth,
                                            startWidth: startWidth,
                                            lastSeenWidth: actual.width,
                                            stableCount: nextStableCount,
                                            deadline: deadline,
                                            delay: delay)
            }
        }
    }

    /// Resize a freshly adopted column at index `idx` toward the configured
    /// `spawnWidthFraction`, if any. This is what makes a native app land at a
    /// tidy column width instead of whatever (often oversized) frame it opened
    /// with - the recurring "native apps don't spawn at the suggested size"
    /// complaint.
    ///
    /// Robustness mirrors `setFocusedWidth`: many apps (Discord, Messages,
    /// Firefox, ...) enforce a larger minimum and silently clamp the request
    /// while STILL returning AX `.success`, and some resize asynchronously so the
    /// immediate read-back is stale. So we never trust the request: we write it,
    /// read back the REAL frame, store that, and schedule the same async
    /// reconcile the width keys use, so the strip model always matches reality
    /// even when the app wins. No-op when no spawn width is configured, the
    /// window is unhealthy, or it is already within a point of the target.
    ///
    /// Grid snap-up (spawn ONLY): if the app refuses to shrink to the target and
    /// clamps WIDER, we round the column UP to the smallest preset width that
    /// fits the clamped window, so it still tiles on the same grid as its
    /// neighbors instead of sitting at an arbitrary in-between width. This is
    /// deliberately NOT done for the manual width keys (`setFocusedWidth`), which
    /// stay best-effort-exact: the user asked for a specific size there.
    func applySpawnWidth(toSlotAt idx: Int) {
        guard let fraction = spawnWidthFraction else { return }
        guard slots.indices.contains(idx) else { return }
        let slot = slots[idx]
        guard slot.window.healthy else { return }

        let target = width(forFraction: fraction)
        // Already close enough (e.g. a window that opened at exactly the column
        // width): skip the cross-process round-trip entirely.
        if abs(slot.width - target) <= 1 { return }

        // Attempt 1: request the configured spawn width. Optimistically reflect
        // it, then pull the model back to the real frame.
        slots[idx].width = target
        _ = AXSource.setSize(
            slot.window.element,
            kAXSizeAttribute as String,
            CGSize(width: target, height: slot.height)
        )
        let live = AXSource.copySize(slot.window.element, kAXSizeAttribute as String)
        if let live {
            slots[idx].width = live.width
            slots[idx].height = live.height
        }

        // Attempt 2 (snap-up): the app clamped WIDER than we asked, so it has a
        // minimum bigger than the target. Round up to the smallest preset that
        // accommodates the clamped width so the column lands on the grid. We only
        // re-issue when a strictly larger preset exists (else the window already
        // overflows even the 100% preset - leave it; `viewportTarget` handles
        // an over-wide column).
        let snapTolerance: CGFloat = 2
        if let clamped = live?.width, clamped > target + snapTolerance,
           let snap = nextPresetWidth(atLeast: clamped), snap > clamped + snapTolerance {
            slots[idx].width = snap
            _ = AXSource.setSize(
                slot.window.element,
                kAXSizeAttribute as String,
                CGSize(width: snap, height: slot.height)
            )
            if let after = AXSource.copySize(slot.window.element, kAXSizeAttribute as String) {
                slots[idx].width = after.width
                slots[idx].height = after.height
            }
        }
        // Slow/animated apps settle after the immediate read-back; the async
        // reconcile refreshes the model + re-packs once the real size lands.
        scheduleWidthReconcile(for: slot.window)
    }

    /// Stretch the column at `idx` to FILL the usable strip height (PaperWM /
    /// niri style): pin its top to the strip's top edge and its height to the
    /// full usable height. No-op unless `fillHeight` is enabled. This is what
    /// makes a freshly opened (often short) window occupy the whole column
    /// instead of leaving dead space below it.
    ///
    /// Robustness mirrors `applySpawnWidth`: many apps enforce a larger MINIMUM
    /// (or a fixed) height and silently clamp the request while STILL returning
    /// AX `.success`, and some resize asynchronously so the immediate read-back
    /// is stale. So we never trust the request: we always pin `y` (teleport
    /// positions from `slot.y`), write the full height, read back the REAL
    /// frame, store that, and schedule the same async reconcile the width keys
    /// use — so the strip model always matches reality even when the app wins.
    ///
    /// `force` skips the "already full height" early-return and ALWAYS issues
    /// the resize. The display-rebind path (`rebindStripDisplay`, a resolution /
    /// monitor change) needs this: it updates the stored model height to the new
    /// usable height up front, so the model would otherwise look "already full"
    /// and the cross-process `setSize` would be skipped, leaving the REAL window
    /// stuck at its old-resolution height. The adopt / spawn paths leave `force`
    /// off so an unchanged window still skips the round-trip.
    func applyFillHeight(toSlotAt idx: Int, force: Bool = false) {
        guard fillHeight else { return }
        guard slots.indices.contains(idx) else { return }
        guard slots[idx].window.healthy else { return }
        // Always pin the top to the strip's top edge regardless of whether a
        // resize is needed: `teleport()` places the window from `slot.y`, so
        // this is what seats it just under the menu bar.
        slots[idx].y = screenFrame.origin.y
        if fillSlotToUsableHeight(&slots[idx], force: force) {
            // Slow/animated apps settle after the immediate read-back; the async
            // reconcile refreshes the model + re-packs once the real size lands.
            scheduleWidthReconcile(for: slots[idx].window)
        }
    }

    /// Resize an arbitrary slot's REAL window to the usable strip height and
    /// pull the model back to the live frame. Shared by the on-strip
    /// `applyFillHeight` and the display-rebind relayout (which must also
    /// re-fill windows parked in INACTIVE workspaces, where there is no `slots`
    /// index to address). Returns true when a cross-process resize was issued
    /// (so the caller can schedule the async reconcile). No top-pin here: the
    /// caller owns `y` (the active strip pins it to the new top; parked windows
    /// keep theirs until re-placed). No-op unless `fillHeight` is enabled, the
    /// window is healthy, and (without `force`) the height actually differs.
    @discardableResult
    func fillSlotToUsableHeight(_ slot: inout Slot, force: Bool) -> Bool {
        guard fillHeight, slot.window.healthy else { return false }
        let target = screenFrame.height
        // Already full height: skip the cross-process round-trip entirely
        // (unless forced, e.g. a resolution change where the model was already
        // updated to the new height but the real window has not been resized).
        if !force && abs(slot.height - target) <= 1 { return false }

        // CRUCIAL: pin the window's TOP to the destination strip top (`slot.y`)
        // BEFORE growing its height. macOS/AppKit (`constrainFrameRect`) curtails
        // an in-place GROW at the display's visible-frame bottom edge, so a
        // window spawned LOW on screen - e.g. Messages opened from Spotlight,
        // which lands centered/low - could only stretch until its bottom met the
        // screen edge and end up SHORT of the full usable height (the reported
        // "spawns at not full height" bug). Moving the top up first gives it the
        // full vertical room to reach `target`. We keep the current X (the
        // teleport pass repositions it horizontally afterward); only the Y
        // matters for the vertical clamp. Mirrors the horizontal pre-move in
        // `setFocusedWidth`. The immediate readback below still pulls the model
        // back to whatever the app actually adopts.
        if let origin = AXSource.copyPoint(slot.window.element, kAXPositionAttribute as String),
           abs(origin.y - slot.y) > 0.5,
           AXSource.setPoint(slot.window.element, kAXPositionAttribute as String,
                             CGPoint(x: origin.x, y: slot.y)) == .success {
            // The teleport pass owns the final on-screen X; clear the cached
            // committed origin so it re-places this window after the resize.
            slot.window.lastCommittedOrigin = nil
        }

        // Optimistically reflect the request, then pull the model back to the
        // real frame (apps clamp to their own min/fixed height while still
        // reporting success). Width is preserved at whatever the spawn-width
        // pass settled it to.
        slot.height = target
        _ = AXSource.setSize(
            slot.window.element,
            kAXSizeAttribute as String,
            CGSize(width: slot.width, height: target)
        )
        if let actual = AXSource.copySize(slot.window.element, kAXSizeAttribute as String) {
            slot.width = actual.width
            slot.height = actual.height
        }
        return true
    }

    /// Smallest preset COLUMN width (from `widthPresets`) that is at least
    /// `minimum` points wide, or nil when even the widest preset is narrower
    /// than `minimum` (the window is wider than the 100% column). Used by the
    /// spawn path to round a clamp-resistant window up onto the width grid.
    func nextPresetWidth(atLeast minimum: CGFloat) -> CGFloat? {
        widthPresets
            .map { width(forFraction: $0) }
            .sorted()
            .first { $0 >= minimum - 0.5 }
    }

    /// Move the focused column one position toward `delta` (negative = left,
    /// positive = right) within the strip. Returns false at the edges or when
    /// nothing is focused.
    @discardableResult
    func moveFocused(by delta: Int) -> Bool {
        // Act on the window the user is REALLY on (focus may have moved via a
        // mouse click / Cmd+Tab since our last navigation), same as the width
        // and close ops.
        syncFocusToSystemFocusedWindow()
        guard slots.indices.contains(focusIndex), slots.count > 1 else { return false }
        let target = focusIndex + delta
        guard slots.indices.contains(target) else { return false }
        slots.swapAt(focusIndex, target)
        focusIndex = target
        compactStrip()
        focus(index: focusIndex)
        onLayoutChange?()
        return true
    }

    /// Resolve the OS's currently-focused window to a managed column and, if it
    /// is one of ours, make that the engine's `focusIndex`.
    ///
    /// ## Why this exists (the "Cmd+Q closed the wrong window" bug)
    ///
    /// The engine's `focusIndex` only moves when the user navigates via
    /// ScrollWM itself (Cmd+H/L, jump keys, the menu). But focus also changes
    /// OUTSIDE ScrollWM all the time: a mouse click on a window, Cmd+Tab,
    /// Mission Control, an app stealing focus. After any of those, `focusIndex`
    /// is stale, so a focus-dependent op (close/width/move) would act on the
    /// last column ScrollWM navigated to, NOT the window the user is actually
    /// on. The reported symptom: Cmd+Q closing "the window on the right"
    /// instead of the focused one.
    ///
    /// We read the system-wide focused application's focused window (works
    /// regardless of activation policy, unlike `frontmostApplication`) and, if
    /// it is one of our managed slots, adopt it as the focus. If the focused
    /// window is NOT managed (e.g. focus is on some unmanaged window), we leave
    /// `focusIndex` untouched. We only update the index; we do NOT re-raise or
    /// re-activate (the window is already focused), so there is no flicker and
    /// no behavior change when ScrollWM's own focus already matches reality.
    ///
    /// Returns true when the live focused window was found among our slots.
    @discardableResult
    func syncFocusToSystemFocusedWindow() -> Bool {
        if case .managed = reconcileFocusToSystem() { return true }
        return false
    }

    /// The relationship between the live OS keyboard focus and the strip, used
    /// to decide whether a "focused-window" op (close/resize/move) should act.
    enum FocusReconcile {
        /// The OS-focused window is one of our slots; `focusIndex` was updated to it.
        case managed
        /// The OS focus resolved to a window we do NOT manage (e.g. the user
        /// clicked an unarranged app, or one on another Space). Acting on
        /// `focusIndex` now would hit a window the user is not even on.
        case unmanaged
        /// The OS focus could not be resolved at all (nil). No evidence either
        /// way, so callers fall back to the current `focusIndex` (also the path
        /// the pure unit tests take, where there is no GUI focus).
        case unresolved
    }

    /// Reconcile `focusIndex` with the live system keyboard focus and classify
    /// the result. Focus may have moved outside ScrollWM (mouse click, Cmd+Tab)
    /// since our last navigation, so `focusIndex` can be stale; this is the
    /// single place that decides what the user is REALLY on.
    @discardableResult
    func reconcileFocusToSystem() -> FocusReconcile {
        guard let focused = AXSource.systemFocusedWindow() else { return .unresolved }
        guard !slots.isEmpty,
              let idx = slots.firstIndex(where: { CFEqual($0.window.element, focused) }) else {
            return .unmanaged
        }
        focusIndex = idx
        return .managed
    }

    /// The AX window element that currently holds keyboard focus, system-wide,
    /// or nil if it cannot be resolved. Routed through `AXSource` so the headless
    /// backend can answer from the sim world.
    static func systemFocusedWindowElement() -> AXUIElement? {
        AXSource.systemFocusedWindow()
    }

    /// Close the focused window via its Accessibility close button, then drop
    /// it from the strip. Returns false when nothing is focused or the window
    /// has no usable close button.
    ///
    /// We do NOT restore this window's frame: the user asked to close it, and
    /// the app owns teardown. We simply stop managing it.
    @discardableResult
    func closeFocused() -> Bool {
        // Honor the window the user is REALLY on: focus may have moved outside
        // ScrollWM (mouse click, Cmd+Tab) since our last navigation, so reconcile
        // `focusIndex` with the live system focus before deciding what to close.
        //
        // CRUCIAL: if the OS focus is on a window we do NOT manage (e.g. the user
        // clicked Discord, which is not arranged, or is on another Space), we must
        // NOT close a strip window. The keystroke (Cmd+Q) belongs to that focused
        // app; acting on the stale `focusIndex` here would close the wrong window
        // (the user's "Cmd+Q closed the right-hand window instead of quitting
        // Discord" bug). Bail so the app receives Cmd+Q itself.
        if case .unmanaged = reconcileFocusToSystem() { return false }
        guard slots.indices.contains(focusIndex) else { return false }
        let slot = slots[focusIndex]
        let element = slot.window.element

        let closed = AXSource.pressCloseButton(element)

        // Drop from the strip regardless: if the press succeeded the window is
        // gone; if it failed, the lifecycle monitor would otherwise keep trying
        // to teleport a window the user wanted closed. A failed close leaves the
        // real window untouched (we never force-killed anything).
        _ = removeSlots { CFEqual($0.window.element, element) }
        compactStrip()
        if !slots.isEmpty { focus(index: focusIndex) } else { teleport() }
        onLayoutChange?()
        return closed
    }
}
