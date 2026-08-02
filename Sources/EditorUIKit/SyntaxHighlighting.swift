#if canImport(UIKit)
public import UIKit

/// One styled span produced by a `SyntaxHighlighter`, addressing a range of the
/// code block's text by **grapheme offset** (0-based, half-open).
public struct SyntaxToken: Sendable {
    public let range: Range<Int>
    public let color: UIColor?
    public let bold: Bool
    public let italic: Bool
    public init(range: Range<Int>, color: UIColor? = nil, bold: Bool = false, italic: Bool = false) {
        self.range = range
        self.color = color
        self.bold = bold
        self.italic = italic
    }
}

/// A hook for syntax-highlighting code blocks. Given the block's full text and
/// its `language` attribute (nil when unset), return the styled token spans; the
/// renderer applies them over the monospaced base style. Set it via
/// `EditorTextView.syntaxHighlighter`.
///
/// No highlighter ships by default — code blocks render as plain monospaced
/// text until a host provides one. The implementation (a tokenizer / a wrapper
/// around a highlighting library) is intentionally out of scope here.
public typealias SyntaxHighlighter = @Sendable (_ code: String, _ language: String?) -> [SyntaxToken]
#endif
