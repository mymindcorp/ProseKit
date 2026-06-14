#if canImport(UIKit)
import UIKit
import DocumentModel

extension UIColor {
    /// Create a color from a `#RRGGBB` (or `#RRGGBBAA`) hex string.
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        switch s.count {
        case 6:
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        case 8:
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

/// Visual styling for the editor: fonts, colors, and block spacing. The layout
/// engine reads this to build attributed strings and position blocks.
public struct TextTheme: Sendable {
    /// When true, fonts track the user's Dynamic Type content-size setting.
    public var dynamicType: Bool = true
    /// The base body point size used when `dynamicType` is off.
    public var fixedBodyFontSize: CGFloat = 17
    /// A custom font face name for body text (e.g. "Georgia", "Charter").
    /// When nil, the system font is used.
    public var fontName: String?
    /// A custom monospaced font face name for code (e.g. "Menlo", "Courier").
    /// When nil, the system monospaced font is used.
    public var monoFontName: String?
    /// Heading point sizes as multiples of the body size (levels 1…6); used both
    /// for custom fonts and (when `dynamicType` is off) for the system font.
    public var headingScale: [CGFloat] = [1.8, 1.5, 1.25, 1.1, 1.0, 0.9]
    /// The effective body point size (drives caret vertical movement).
    public var baseFontSize: CGFloat { bodyFont.pointSize }
    public var textColor: UIColor = .label
    public var linkColor: UIColor = .link
    public var codeColor: UIColor = .secondaryLabel
    public var quoteBarColor: UIColor = .separator
    public var caretColor: UIColor = .tintColor
    public var selectionColor: UIColor = UIColor.tintColor.withAlphaComponent(0.25)
    /// Highlight-mark background colors by name (the `color` attribute). The
    /// default (nil/unknown name) is the first entry. Tuned with alpha so dark
    /// text stays legible in light and dark mode.
    public var highlightColors: [String: UIColor] = [
        "yellow": UIColor.systemYellow.withAlphaComponent(0.40),
        "green": UIColor.systemGreen.withAlphaComponent(0.35),
        "blue": UIColor.systemBlue.withAlphaComponent(0.30),
        "pink": UIColor.systemPink.withAlphaComponent(0.30),
        "orange": UIColor.systemOrange.withAlphaComponent(0.35),
        "purple": UIColor.systemPurple.withAlphaComponent(0.30),
    ]
    public var defaultHighlightColorName = "yellow"

    /// The background color for a highlight mark with the given `color` name
    /// (falling back to the default highlight color).
    public func highlightColor(_ name: String?) -> UIColor {
        if let name, let color = highlightColors[name] { return color }
        return highlightColors[defaultHighlightColorName] ?? UIColor.systemYellow.withAlphaComponent(0.40)
    }
    /// Background of the suggestion popup (slash menu / wiki-link menu).
    public var popupBackground: UIColor = .secondarySystemBackground
    public var pageInsets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    public var paragraphSpacing: CGFloat = 10
    public var lineSpacing: CGFloat = 3
    public var listIndent: CGFloat = 24
    public var quoteIndent: CGFloat = 16

    public init() {}

    /// The body point size (Dynamic Type scaled, or fixed).
    private var bodyPointSize: CGFloat {
        dynamicType ? UIFont.preferredFont(forTextStyle: .body).pointSize : fixedBodyFontSize
    }

    /// The base (body) font — custom face if configured, else the system font.
    public var bodyFont: UIFont {
        if let fontName, let custom = UIFont(name: fontName, size: bodyPointSize) { return custom }
        return dynamicType ? UIFont.preferredFont(forTextStyle: .body) : UIFont.systemFont(ofSize: fixedBodyFontSize)
    }

    public var monoFont: UIFont {
        let size = bodyPointSize - 1
        if let monoFontName, let custom = UIFont(name: monoFontName, size: size) { return custom }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The font for a block node (heading sizes, code blocks, etc.).
    public func blockFont(_ node: Node) -> UIFont {
        switch node.type.name {
        case "heading":
            let level = min(max(node.attrs["level"]?.intValue ?? 1, 1), 6)
            // A custom face: scale the body size by the heading multiplier, bold.
            if let fontName, let custom = UIFont(name: fontName, size: bodyPointSize * headingScale[level - 1]) {
                let descriptor = custom.fontDescriptor.withSymbolicTraits(.traitBold) ?? custom.fontDescriptor
                return UIFont(descriptor: descriptor, size: custom.pointSize)
            }
            // System font: prefer the matching Dynamic Type text style.
            if dynamicType {
                let styles: [UIFont.TextStyle] = [.title1, .title2, .title3, .headline, .headline, .subheadline]
                let font = UIFont.preferredFont(forTextStyle: styles[level - 1])
                let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
                return UIFont(descriptor: descriptor, size: font.pointSize)
            }
            return UIFont.systemFont(ofSize: fixedBodyFontSize * headingScale[level - 1], weight: .bold)
        case "codeBlock":
            return monoFont
        default:
            return bodyFont
        }
    }

    /// Spacing above a block of the given type.
    public func spacingBefore(_ node: Node, isFirst: Bool) -> CGFloat {
        isFirst ? 0 : paragraphSpacing
    }

    /// Apply inline marks to a font + attribute dictionary.
    public func attributes(for marks: [Mark], baseFont: UIFont) -> [NSAttributedString.Key: Any] {
        var font = baseFont
        var traits = font.fontDescriptor.symbolicTraits
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: textColor]
        var sizeScale: CGFloat = 1
        var baselineOffset: CGFloat = 0

        for mark in marks {
            switch mark.type.name {
            case "bold": traits.insert(.traitBold)
            case "italic": traits.insert(.traitItalic)
            case "code":
                font = monoFont
                attrs[.foregroundColor] = codeColor
            case "strike":
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "underline":
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "link":
                attrs[.foregroundColor] = linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "textColor":
                if let color = TextTheme.parseColor(mark.attrs["color"]?.stringValue) {
                    attrs[.foregroundColor] = color
                }
            // backgroundColor is painted behind the run by DocumentLayout (CoreText
            // ignores .backgroundColor), so it's not applied here.
            case "subscript":
                sizeScale = 0.75; baselineOffset = -baseFont.pointSize * 0.2
            case "superscript":
                sizeScale = 0.75; baselineOffset = baseFont.pointSize * 0.35
            default: break
            }
        }
        if sizeScale != 1 { font = font.withSize(font.pointSize * sizeScale) }
        if baselineOffset != 0 { attrs[.baselineOffset] = baselineOffset }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        attrs[.font] = font
        return attrs
    }

    /// Parse a CSS color string — `#rgb`/`#rrggbb`/`#rrggbbaa` (with or without
    /// `#`) or a common named color — into a UIColor. Returns nil if unparseable.
    public static func parseColor(_ string: String?) -> UIColor? {
        guard var s = string?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if let named = namedColors[s] { return named }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() } // #rgb → #rrggbb
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    private static let namedColors: [String: UIColor] = [
        "black": .black, "white": .white, "red": .red, "green": .green, "blue": .blue,
        "yellow": .yellow, "orange": .orange, "purple": .purple, "gray": .gray, "grey": .gray,
        "brown": .brown, "cyan": .cyan, "magenta": .magenta, "clear": .clear,
    ]
}
#endif
