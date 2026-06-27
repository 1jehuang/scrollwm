import AppKit

/// The visual language for the redesigned ScrollWM tutorial window.
///
/// `TutorialTheme` is the single source of truth for the tutorial's palette,
/// corner radii, spacing scale, and font ramp. Everything is exposed as static
/// members so the coordinator (and `TutorialComponents`) can compose a finished,
/// modern-looking window without re-deriving constants.
///
/// Design goals:
/// - **Light + dark correct.** Colors are either system semantic colors (already
///   dynamic) or custom `NSColor(name:dynamicProvider:)` colors that resolve a
///   light and a dark variant. Nothing is a hard-coded single appearance.
/// - **Mostly pure where it can be.** The spacing scale, corner radii, font
///   sizes, and the WCAG-style color math (`relativeLuminance`, `contrastRatio`,
///   `mix`, `readableForeground`) are deterministic value functions with no
///   AppKit state, so they get real unit assertions in `TutorialThemeTests`.
enum TutorialTheme {

    // MARK: - Spacing (4pt grid)

    /// A small, regular spacing scale built on a 4pt grid. Using a fixed scale
    /// (rather than ad-hoc magic numbers) keeps the layout rhythm consistent.
    enum Spacing {
        /// The base grid unit. Every step is a multiple of this.
        static let unit: CGFloat = 4

        /// `step(n)` == `n * unit`. The primitive the named steps are built on.
        static func step(_ n: Int) -> CGFloat { CGFloat(n) * unit }

        static let xxs: CGFloat = step(1)   // 4   hairline gaps
        static let xs: CGFloat  = step(2)   // 8   tight inline spacing
        static let sm: CGFloat  = step(3)   // 12  default control spacing
        static let md: CGFloat  = step(4)   // 16  content padding
        static let lg: CGFloat  = step(6)   // 24  card padding / section gap
        static let xl: CGFloat  = step(8)   // 32  page padding
        static let xxl: CGFloat = step(12)  // 48  hero padding

        /// The named steps in ascending order (used by tests to assert the scale
        /// is strictly increasing and positive).
        static let scale: [CGFloat] = [xxs, xs, sm, md, lg, xl, xxl]
    }

    // MARK: - Corner radii

    /// Corner radii for the different surface tiers, smallest (chips) to largest
    /// (hero). Strictly increasing so nested surfaces read as a hierarchy.
    enum Radius {
        static let badge: CGFloat   = 5    // status pills
        static let keycap: CGFloat  = 6    // keycaps
        static let control: CGFloat = 8    // segmented selector track
        static let card: CGFloat    = 12   // card containers
        static let hero: CGFloat    = 16   // hero header

        /// Ascending tiers (tests assert strictly increasing).
        static let scale: [CGFloat] = [badge, keycap, control, card, hero]
    }

    // MARK: - Font ramp

    /// Point sizes for the font ramp, largest (hero) to smallest (caption).
    /// Exposed separately from `Font` so tests can assert ordering without
    /// touching `NSFont`.
    enum FontSize {
        static let hero: CGFloat    = 26
        static let title: CGFloat   = 20
        static let section: CGFloat = 15
        static let body: CGFloat    = 13
        static let mono: CGFloat    = 12
        static let caption: CGFloat = 11
        static let keycap: CGFloat  = 13

        /// Descending sizes for the prose ramp (hero ... caption); tests assert
        /// this is strictly decreasing.
        static let ramp: [CGFloat] = [hero, title, section, body, caption]
    }

    /// Resolved fonts for each role. Computed (not stored) so they always honor
    /// the current system font.
    enum Font {
        static var hero: NSFont          { .systemFont(ofSize: FontSize.hero, weight: .bold) }
        static var title: NSFont         { .systemFont(ofSize: FontSize.title, weight: .bold) }
        static var section: NSFont       { .systemFont(ofSize: FontSize.section, weight: .semibold) }
        static var body: NSFont          { .systemFont(ofSize: FontSize.body, weight: .regular) }
        static var bodyEmphasis: NSFont  { .systemFont(ofSize: FontSize.body, weight: .semibold) }
        static var caption: NSFont       { .systemFont(ofSize: FontSize.caption, weight: .medium) }
        static var captionEmphasis: NSFont { .systemFont(ofSize: FontSize.caption, weight: .bold) }
        static var mono: NSFont          { .monospacedSystemFont(ofSize: FontSize.mono, weight: .regular) }
        static var keycap: NSFont        { .systemFont(ofSize: FontSize.keycap, weight: .semibold) }
        static var keycapSmall: NSFont   { .systemFont(ofSize: FontSize.keycap - 3, weight: .semibold) }
    }

    // MARK: - Palette

    /// Build a dynamic color that resolves a `light` value in light appearances
    /// and a `dark` value in dark ones. The closure is re-evaluated by AppKit
    /// whenever the effective appearance changes.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? dark : light
        }
    }

    enum Palette {
        /// Brand accent — a friendly indigo, a touch brighter in dark mode so it
        /// stays vivid against the darker surfaces.
        static let accent = dynamic(
            light: NSColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: 1),  // #5856D6
            dark:  NSColor(srgbRed: 0.482, green: 0.471, blue: 0.949, alpha: 1))  // #7B78F2

        /// A softer, lower-emphasis accent tint for fills/wash behind accent
        /// content (hero strip, selected segment hover).
        static let accentSoft = dynamic(
            light: NSColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: 0.12),
            dark:  NSColor(srgbRed: 0.482, green: 0.471, blue: 0.949, alpha: 0.22))

        /// Foreground that reads on top of `accent` (white in both modes — the
        /// accent is dark enough in both that white wins; verified by the
        /// contrast assertions in the tests).
        static let onAccent = NSColor.white

        /// Window backdrop. The system dynamic window color.
        static let windowBackground = NSColor.windowBackgroundColor

        /// Elevated card surface, slightly lifted from the window backdrop so
        /// cards read as floating panels in both appearances.
        static let cardSurface = dynamic(
            light: NSColor.white,
            dark:  NSColor(srgbRed: 0.157, green: 0.157, blue: 0.169, alpha: 1))  // #28282B

        /// A second, even-more-recessed surface (e.g. the segmented track, the
        /// keycap face) used inside cards.
        static let inset = dynamic(
            light: NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1),
            dark:  NSColor(srgbRed: 0.106, green: 0.106, blue: 0.118, alpha: 1))

        /// Hairline border for cards / controls.
        static let border = dynamic(
            light: NSColor(white: 0.0, alpha: 0.10),
            dark:  NSColor(white: 1.0, alpha: 0.14))

        /// Drop-shadow color for elevated surfaces.
        static let shadow = dynamic(
            light: NSColor(white: 0.0, alpha: 0.16),
            dark:  NSColor(white: 0.0, alpha: 0.55))

        // Text tiers (system semantic colors — already dynamic + accessible).
        static let textPrimary   = NSColor.labelColor
        static let textSecondary = NSColor.secondaryLabelColor
        static let textTertiary  = NSColor.tertiaryLabelColor
    }

    // MARK: - Status colors (LearnState)

    /// Semantic accent color for a learn state. System colors so they resolve in
    /// both appearances. NOTE: color is never the only signal in the UI — the
    /// `TutorialStatusBadge` always pairs it with `state.glyph` + `state.caption`.
    static func statusColor(for state: TutorialProgress.LearnState) -> NSColor {
        switch state {
        case .learned:    return .systemGreen
        case .rusty:      return .systemOrange
        case .learning:   return .systemBlue
        case .notStarted: return .systemGray
        }
    }

    /// A low-alpha tint of the status color for the badge's pill background.
    static func statusFill(for state: TutorialProgress.LearnState) -> NSColor {
        statusColor(for: state).withAlphaComponent(0.16)
    }

    // MARK: - Color math (pure, WCAG-style)

    /// A plain RGBA value in the sRGB color space, components in `[0, 1]`. The
    /// pure color math operates on this so it is fully deterministic + testable
    /// without resolving `NSColor` through an appearance.
    struct RGBA: Equatable {
        var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
        static let white = RGBA(1, 1, 1)
        static let black = RGBA(0, 0, 0)
    }

    /// Linearize a single gamma-encoded sRGB channel (the WCAG transfer curve).
    static func linearize(_ c: CGFloat) -> CGFloat {
        let c = min(max(c, 0), 1)
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance of an sRGB color, in `[0, 1]` (black 0, white 1).
    static func relativeLuminance(_ c: RGBA) -> CGFloat {
        0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b)
    }

    /// WCAG contrast ratio between two colors, in `[1, 21]`. Symmetric.
    static func contrastRatio(_ a: RGBA, _ b: RGBA) -> CGFloat {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Linear interpolation between two colors (component-wise, including alpha).
    /// `t` is clamped to `[0, 1]`; `t == 0` returns `a`, `t == 1` returns `b`.
    static func mix(_ a: RGBA, _ b: RGBA, _ t: CGFloat) -> RGBA {
        let t = min(max(t, 0), 1)
        return RGBA(
            a.r + (b.r - a.r) * t,
            a.g + (b.g - a.g) * t,
            a.b + (b.b - a.b) * t,
            a.a + (b.a - a.a) * t)
    }

    /// Pick the readable text color (near-black or white) for a given background
    /// luminance, choosing whichever yields the higher contrast.
    static func readableForeground(onLuminance bgLuminance: CGFloat) -> RGBA {
        // Contrast against white vs against (near) black.
        let whiteContrast = (1.0 + 0.05) / (bgLuminance + 0.05)
        let blackContrast = (bgLuminance + 0.05) / (0.0 + 0.05)
        return whiteContrast >= blackContrast ? .white : RGBA(0.05, 0.05, 0.06)
    }

    /// Convenience: readable foreground for an `RGBA` background.
    static func readableForeground(on bg: RGBA) -> RGBA {
        readableForeground(onLuminance: relativeLuminance(bg))
    }

    // MARK: - NSColor <-> RGBA bridge

    /// Resolve an `NSColor` to `RGBA` in sRGB under a specific appearance.
    /// Returns `nil` only for pattern colors that have no RGB representation.
    static func rgba(_ color: NSColor, in appearance: NSAppearance) -> RGBA? {
        var result: RGBA?
        appearance.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) {
                result = RGBA(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
            }
        }
        return result
    }
}
