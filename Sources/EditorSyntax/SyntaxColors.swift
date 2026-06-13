#if canImport(UIKit)
import UIKit

/// The color for each token category a grammar can emit. Pass a custom instance
/// to `makeSyntaxHighlighter(colors:)` to theme the output; the defaults use
/// system colors so they adapt to light/dark mode.
public struct SyntaxColors: Sendable {
    public var keyword: UIColor
    public var string: UIColor
    public var comment: UIColor
    public var number: UIColor
    /// CSS property names (and similar member-ish identifiers).
    public var property: UIColor
    /// CSS at-rules (`@media`) / other annotations.
    public var atRule: UIColor

    public init(keyword: UIColor, string: UIColor, comment: UIColor,
                number: UIColor, property: UIColor, atRule: UIColor) {
        self.keyword = keyword
        self.string = string
        self.comment = comment
        self.number = number
        self.property = property
        self.atRule = atRule
    }

    public static let `default` = SyntaxColors(
        keyword: .systemPurple,
        string: .systemRed,
        comment: .systemGray,
        number: .systemBlue,
        property: .systemTeal,
        atRule: .systemPink)
}
#endif
