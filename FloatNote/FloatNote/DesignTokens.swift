import SwiftUI
import AppKit

/// Central design-token registry. Every visual constant (font, size, spacing,
/// color, radius, fixed dimension) lives here so the UI stays consistent and
/// tweaks land in one place. Never hard-code a number elsewhere — add a token.
///
/// Typography ratios follow Obsidian's defaults:
///   body    = user-set (default 14, persisted via UserDefaults)
///   h3      ≈ body × 1.14
///   h2      ≈ body × 1.36
///   h1      ≈ body × 1.71
/// Line-height 1.5 across body + lists; paragraph spacing ≈ 1em between
/// true paragraphs; zero between items of the same list.
enum Tokens {

    // MARK: - Persisted body size

    /// Internal (not private) so the pickers can bind to it with `@AppStorage`
    /// and stay in sync no matter which menu changed the value.
    static let bodySizeKey = "fn.bodyFontSize"
    /// Allowed body font sizes in the dropdown.
    static let bodySizeOptions: [CGFloat] = [10, 11, 12, 13, 14, 15, 16, 18, 20]

    /// Current body font size, read from UserDefaults (default 14pt).
    static var currentBodySize: CGFloat {
        let v = UserDefaults.standard.double(forKey: bodySizeKey)
        return v > 0 ? CGFloat(v) : 14
    }
    /// Setter; call `reloadActiveNote` on the view-model afterwards to reflow.
    static func setBodySize(_ size: CGFloat) {
        UserDefaults.standard.set(Double(size), forKey: bodySizeKey)
    }

    // MARK: - Persisted editor font family

    /// Internal for the same reason as `bodySizeKey`.
    static let fontFamilyKey = "fn.fontFamily"
    /// Sentinel meaning "use the built-in system font" (the original default).
    static let systemFontName = "System"
    /// Font families shown in the toolbar picker: the current default (System),
    /// five popular preinstalled families, and Monaco.
    static let fontOptions: [String] = [
        systemFontName,        // current default
        "Helvetica Neue",
        "Georgia",
        "Times New Roman",
        "Verdana",
        "Arial",
        "Monaco",
    ]

    /// Currently selected editor font family (defaults to System).
    static var currentFontFamily: String {
        UserDefaults.standard.string(forKey: fontFamilyKey) ?? systemFontName
    }
    /// Setter; call `reloadActive` on the view-model afterwards to re-render.
    static func setFontFamily(_ name: String) {
        UserDefaults.standard.set(name, forKey: fontFamilyKey)
    }

    // MARK: - Typography
    enum Typography {
        /// Build an editor font in the currently-selected family at the given
        /// size, applying bold/italic traits. Falls back to the system font when
        /// the family is the System sentinel or unavailable on this machine.
        static func editorFont(size: CGFloat, weight: NSFont.Weight = .regular,
                               bold: Bool = false, italic: Bool = false) -> NSFont {
            let family = Tokens.currentFontFamily
            let fm = NSFontManager.shared
            var base: NSFont
            if family != Tokens.systemFontName, let named = NSFont(name: family, size: size) {
                base = named
                if bold { base = fm.convert(base, toHaveTrait: .boldFontMask) }
            } else {
                base = bold ? NSFont.boldSystemFont(ofSize: size)
                            : NSFont.systemFont(ofSize: size, weight: weight)
            }
            if italic { base = fm.convert(base, toHaveTrait: .italicFontMask) }
            return base
        }

        static func body(size: CGFloat = Tokens.currentBodySize, weight: NSFont.Weight = .regular) -> NSFont {
            editorFont(size: size, weight: weight)
        }
        static func bold(size: CGFloat) -> NSFont { editorFont(size: size, bold: true) }

        /// SF Pro Rounded variant — used for ☐/☑ checkbox glyphs so the box
        /// corners read noticeably rounder than the default system font.
        static func rounded(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let desc = base.fontDescriptor.withDesign(.rounded),
               let font = NSFont(descriptor: desc, size: size) {
                return font
            }
            return base
        }

        /// Text attributes for a checkbox glyph. SF Rounded contains ☑ but NOT
        /// ☐ — the unchecked box falls back to Apple Symbols, whose thin,
        /// square-cornered box clashes with ☑'s rounded one. The character in
        /// the document must stay ☐ (badge counting, HTML persistence, MCP all
        /// key off it), so for unchecked boxes we attach an NSGlyphInfo that
        /// makes TextKit display SF Rounded's □ (U+25A1) glyph instead — its
        /// box matches ☑'s corners, stroke and advance exactly.
        static func checkboxAttributes(checked: Bool) -> [NSAttributedString.Key: Any] {
            let font = rounded(size: checkboxSize, weight: .medium)
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if !checked, let info = uncheckedBoxGlyphInfo(for: font) {
                attrs[.glyphInfo] = info
            }
            // The box glyph is checkboxSize (≈1.35× body), so on the shared text
            // baseline it pokes above the caps and reads as "raised" next to body
            // text. Drop it with a baselineOffset so its optical center lines up
            // with the body text's cap band — box, text and caret then align.
            let off = checkboxBaselineOffset(checked: checked, font: font)
            if off != 0 { attrs[.baselineOffset] = off }
            return attrs
        }

        /// Vertical shift (points, negative = down) that centers the enlarged box
        /// glyph on the body text. Derived from the actual rendered glyph's
        /// bounding box vs the body font's cap height, so it scales with the
        /// chosen body size/family instead of being a magic number.
        private static func checkboxBaselineOffset(checked: Bool, font: NSFont) -> CGFloat {
            // Unchecked renders □ (U+25A1) via glyphInfo; checked renders ☑.
            let utf16 = Array((checked ? "☑" : "□").utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), glyphs[0] != 0 else { return 0 }
            let boxRect = CTFontGetBoundingRectsForGlyphs(font, .default, &glyphs, nil, 1)
            let boxCenter = boxRect.midY               // box optical center above baseline
            let textCenter = body().capHeight / 2      // cap-band center of body text
            return (textCenter - boxCenter).rounded()
        }

        /// Apply checkbox glyph styling in place. Removes any stale glyphInfo
        /// when a box becomes checked (☐→☑ keeps the old character's attributes).
        static func styleCheckboxGlyph(_ storage: NSMutableAttributedString, range: NSRange, checked: Bool) {
            storage.removeAttribute(.glyphInfo, range: range)
            storage.addAttributes(checkboxAttributes(checked: checked), range: range)
        }

        private static func uncheckedBoxGlyphInfo(for font: NSFont) -> NSGlyphInfo? {
            let utf16 = Array("□".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), glyphs[0] != 0 else { return nil }
            return NSGlyphInfo(cgGlyph: glyphs[0], for: font, baseString: "☐")
        }

        // Editor body + heading sizes (derived from current body size)
        static var bodySize: CGFloat { Tokens.currentBodySize }
        static var h3Size:   CGFloat { round(bodySize * 1.14) }
        static var h2Size:   CGFloat { round(bodySize * 1.36) }
        static var h1Size:   CGFloat { round(bodySize * 1.71) }
        /// Size multiplier applied to ☐ / ☑ checkbox characters so they render
        /// visibly larger than surrounding body text. The glyph edges also
        /// appear more rounded at higher sizes.
        static var checkboxSize: CGFloat { round(bodySize * 1.35) }

        // Chrome sizes (fixed)
        static let toolbar:        CGFloat = 11
        static let toolbarLabel:   CGFloat = 11
        static let sidebarHeader:  CGFloat = 10
        static let sidebarItem:    CGFloat = 12
        static let statusSmall:    CGFloat = 11
        static let statusVersion:  CGFloat = 9
        static let mono:           CGFloat = 11
    }

    // MARK: - Spacing (editor + lists)
    enum Spacing {
        /// Space added between wrapped lines of the same paragraph (AppKit
        /// `lineSpacing`). Gives Obsidian-like breathing room on prose while
        /// leaving single-line paragraphs at the font's natural height — this
        /// is important because `lineHeightMultiple` inflates the line box
        /// which pushes the text caret off-center.
        static var bodyLineSpacing: CGFloat { round(Tokens.currentBodySize * 0.35) }
        /// Smaller lineSpacing for list items — bullets sit tight but still
        /// breathe when wrapped.
        static var listLineSpacing: CGFloat { round(Tokens.currentBodySize * 0.15) }
        /// Space after a true paragraph (hard return between blocks).
        /// ≈ 1em at current body size.
        static var paragraphSpacing: CGFloat { round(Tokens.currentBodySize * 0.25) }
        /// Space after a list item. Obsidian keeps this at 0 — list lines sit
        /// tight together; only real paragraphs get breathing room.
        static let listItemSpacing: CGFloat = 0
        /// Extra top spacing above a parent list item when a deeper-indent
        /// child follows (light visual grouping, no break).
        static let listParentSpacingBefore: CGFloat = 2
        /// Indent added per Tab-level in list items (number of spaces).
        static let listIndentStep: Int = 4

        // Window chrome padding
        static let toolbarPaddingH: CGFloat = 8
        static let toolbarPaddingV: CGFloat = 3
        static let sidebarHeaderH:  CGFloat = 12
        static let sidebarHeaderTop: CGFloat = 10
        static let sidebarHeaderBot: CGFloat = 6
        static let sidebarListPad:  CGFloat = 4
        static let sidebarItemH:    CGFloat = 10
        static let sidebarItemV:    CGFloat = 7
        static let statusH:         CGFloat = 12
        static let statusV:         CGFloat = 6
    }

    // MARK: - Sizes (fixed widths / heights)
    enum Size {
        static let windowMinWidth:   CGFloat = 50
        static let windowMinHeight:  CGFloat = 50
        static let defaultWidth:     CGFloat = 800
        static let defaultHeight:    CGFloat = 600

        static let sidebarWidth:     CGFloat = 220

        static let toolbarBtnW:      CGFloat = 26
        static let toolbarBtnH:      CGFloat = 22
        static let toolbarDividerH:  CGFloat = 14
        static let toolbarDividerPad: CGFloat = 4

        static let sidebarPlusBtn:   CGFloat = 22
    }

    // MARK: - Radii
    enum Radius {
        static let button:      CGFloat = 3
        static let sidebarItem: CGFloat = 6
        static let statusPill:  CGFloat = 3
    }

    // MARK: - Colors (AppKit)
    enum Color {
        static let bodyText  = NSColor(calibratedWhite: 0.88, alpha: 1.0)
        static let doneText  = NSColor(calibratedWhite: 0.45, alpha: 1.0)
        static let linkHex   = "#6cb6ff"
    }

    // MARK: - SwiftUI color helpers
    enum SUI {
        static let hoverBG:    SwiftUI.Color = .primary.opacity(0.08)
        static let activeTint: SwiftUI.Color = .accentColor.opacity(0.18)
        static let divider:    SwiftUI.Color = .primary.opacity(0.10)
        /// Amber accent for a per-note terminal-folder override (distinct from the
        /// inherited/project state, which uses `.accentColor`).
        static let overrideTint: SwiftUI.Color = SwiftUI.Color(red: 0.95, green: 0.64, blue: 0.20)
        /// Green for "this note's board has drawings" (closed). The open board
        /// uses `.accentColor` instead, so the two states never collide.
        static let boardHasContent: SwiftUI.Color = SwiftUI.Color(red: 0.22, green: 0.74, blue: 0.40)
        /// Red for hands-free listening — deliberately the same signal the app
        /// already uses for "the microphone is live" during recording.
        static let handsfreeListening: SwiftUI.Color = SwiftUI.Color(red: 1.0, green: 0.231, blue: 0.188)
    }
}

// MARK: - Paragraph style helpers

extension NSMutableParagraphStyle {
    /// Body paragraph style: LTR, left-aligned, uses `lineSpacing` (between
    /// wrapped lines) rather than `lineHeightMultiple` so the caret stays
    /// visually aligned on short/single-line paragraphs.
    static func readableBody() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = .leftToRight
        p.alignment = .left
        p.lineHeightMultiple = 0            // reset any inherited inflation
        p.lineSpacing        = Tokens.Spacing.bodyLineSpacing
        p.paragraphSpacing   = Tokens.Spacing.paragraphSpacing
        return p
    }

    /// Tight list-item paragraph style: small lineSpacing for wrapped lines,
    /// zero paragraphSpacing so items sit flush.
    static func tightListItem(headIndent: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = .leftToRight
        p.alignment = .left
        p.lineHeightMultiple = 0
        p.lineSpacing        = Tokens.Spacing.listLineSpacing
        p.paragraphSpacing   = Tokens.Spacing.listItemSpacing
        p.headIndent = headIndent
        return p
    }

    /// Applies readable body spacing (legacy helper). Prefer the factory methods.
    func applyReadableBodySpacing() {
        self.lineHeightMultiple = 0
        self.lineSpacing        = Tokens.Spacing.bodyLineSpacing
        self.paragraphSpacing   = Tokens.Spacing.paragraphSpacing
    }

    /// Applies tight list-item spacing (small lineSpacing, 0 after-paragraph).
    func applyTightListSpacing() {
        self.lineHeightMultiple = 0
        self.lineSpacing        = Tokens.Spacing.listLineSpacing
        self.paragraphSpacing   = Tokens.Spacing.listItemSpacing
    }
}
