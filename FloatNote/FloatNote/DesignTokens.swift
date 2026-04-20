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

    private static let bodySizeKey = "fn.bodyFontSize"
    /// Allowed body font sizes in the dropdown.
    static let bodySizeOptions: [CGFloat] = [12, 13, 14, 15, 16, 18, 20]

    /// Current body font size, read from UserDefaults (default 14pt).
    static var currentBodySize: CGFloat {
        let v = UserDefaults.standard.double(forKey: bodySizeKey)
        return v > 0 ? CGFloat(v) : 14
    }
    /// Setter; call `reloadActiveNote` on the view-model afterwards to reflow.
    static func setBodySize(_ size: CGFloat) {
        UserDefaults.standard.set(Double(size), forKey: bodySizeKey)
    }

    // MARK: - Typography
    enum Typography {
        static func body(size: CGFloat = Tokens.currentBodySize, weight: NSFont.Weight = .regular) -> NSFont {
            NSFont.systemFont(ofSize: size, weight: weight)
        }
        static func bold(size: CGFloat) -> NSFont { NSFont.boldSystemFont(ofSize: size) }

        // Editor body + heading sizes (derived from current body size)
        static var bodySize: CGFloat { Tokens.currentBodySize }
        static var h3Size:   CGFloat { round(bodySize * 1.14) }
        static var h2Size:   CGFloat { round(bodySize * 1.36) }
        static var h1Size:   CGFloat { round(bodySize * 1.71) }

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
        /// Multiplier for body prose line height. Matches Obsidian's
        /// `--line-height-normal` (1.5) — helps scannability of wrapped text.
        static let lineHeightMultiple: CGFloat = 1.5
        /// Tighter line-height for single-line list items. AppKit applies
        /// lineHeightMultiple per-line (unlike CSS which collapses on short
        /// lines), so lists need a lower multiplier to avoid excess vertical air.
        static let listLineHeightMultiple: CGFloat = 1.2
        /// Space after a true paragraph (hard return between blocks).
        /// ≈ 1em at current body size.
        static var paragraphSpacing: CGFloat { round(Tokens.currentBodySize * 0.85) }
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
    }
}

// MARK: - Paragraph style helpers

extension NSMutableParagraphStyle {
    /// Body paragraph style: LTR, left-aligned, 1.5× line height, ~1em
    /// after-paragraph spacing. Use for regular prose lines.
    static func readableBody() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = .leftToRight
        p.alignment = .left
        p.lineHeightMultiple = Tokens.Spacing.lineHeightMultiple
        p.paragraphSpacing   = Tokens.Spacing.paragraphSpacing
        return p
    }

    /// Tight list-item paragraph style: reduced line-height (1.2) and zero
    /// after-paragraph spacing so list items sit flush — matches Obsidian's
    /// visual density for bullets/checkboxes.
    static func tightListItem(headIndent: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = .leftToRight
        p.alignment = .left
        p.lineHeightMultiple = Tokens.Spacing.listLineHeightMultiple
        p.paragraphSpacing   = Tokens.Spacing.listItemSpacing
        p.headIndent = headIndent
        return p
    }

    /// Applies readable body spacing (legacy helper). Prefer the factory methods.
    func applyReadableBodySpacing() {
        self.lineHeightMultiple = Tokens.Spacing.lineHeightMultiple
        self.paragraphSpacing   = Tokens.Spacing.paragraphSpacing
    }

    /// Applies tight list-item spacing (1.2× line-height, 0 after-paragraph).
    func applyTightListSpacing() {
        self.lineHeightMultiple = Tokens.Spacing.listLineHeightMultiple
        self.paragraphSpacing   = Tokens.Spacing.listItemSpacing
    }
}
