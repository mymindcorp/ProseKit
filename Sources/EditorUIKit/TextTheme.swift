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
    /// The effective body point size (drives caret vertical movement).
    public var baseFontSize: CGFloat { bodyFont.pointSize }
    public var textColor: UIColor = .label
    public var linkColor: UIColor = .link
    public var codeColor: UIColor = .secondaryLabel
    public var quoteBarColor: UIColor = .separator
    public var caretColor: UIColor = .tintColor
    public var selectionColor: UIColor = UIColor.tintColor.withAlphaComponent(0.25)
    /// Background of the suggestion popup (slash menu / wiki-link menu).
    public var popupBackground: UIColor = .secondarySystemBackground
    public var pageInsets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    public var paragraphSpacing: CGFloat = 10
    public var lineSpacing: CGFloat = 3
    public var listIndent: CGFloat = 24
    public var quoteIndent: CGFloat = 16

    public init() {}

    /// The base (body) font — preferred (Dynamic Type) or fixed.
    public var bodyFont: UIFont {
        dynamicType ? UIFont.preferredFont(forTextStyle: .body) : UIFont.systemFont(ofSize: fixedBodyFontSize)
    }
    public var monoFont: UIFont {
        let base = UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular)
        return dynamicType ? UIFontMetrics(forTextStyle: .body).scaledFont(for: base) : base
    }

    /// The font for a block node (heading sizes, code blocks, etc.).
    public func blockFont(_ node: Node) -> UIFont {
        switch node.type.name {
        case "heading":
            let level = node.attrs["level"]?.intValue ?? 1
            if dynamicType {
                let styles: [UIFont.TextStyle] = [.title1, .title2, .title3, .headline, .headline, .subheadline]
                let style = styles[min(max(level, 1), 6) - 1]
                let font = UIFont.preferredFont(forTextStyle: style)
                let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
                return UIFont(descriptor: descriptor, size: font.pointSize)
            }
            let sizes: [CGFloat] = [28, 24, 20, 18, 17, 16]
            return UIFont.systemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: .bold)
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

        for mark in marks {
            switch mark.type.name {
            case "bold": traits.insert(.traitBold)
            case "italic": traits.insert(.traitItalic)
            case "code":
                font = monoFont
                attrs[.foregroundColor] = codeColor
            case "strike":
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "link":
                attrs[.foregroundColor] = linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            default: break
            }
        }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        attrs[.font] = font
        return attrs
    }
}
#endif
