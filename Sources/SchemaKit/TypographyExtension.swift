import DocumentModel
import EditorStateKit
import EditorInputRules

/// Smart typography: curly quotes, em-dashes, and ellipses, applied as input
/// rules while typing (matching Tiptap's Typography extension).
public final class TypographyExtension: Extension {
    public let name = "typography"
    public init() {}

    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        [
            emDashRule,                                            // -- → —
            ellipsisRule,                                          // ... → …
            smartQuoteRule("\"", open: "\u{201C}", close: "\u{201D}"),  // " → “ / ”
            smartQuoteRule("'", open: "\u{2018}", close: "\u{2019}"),   // ' → ‘ / ’
        ]
    }
}

/// A rule that replaces a straight quote with the opening or closing curly
/// variant, chosen by the preceding character.
func smartQuoteRule(_ quote: Character, open: String, close: String) -> InputRule {
    InputRule("\(quote)$") { state, _, start, end in
        let before = start > 0 ? state.doc.textBetween(start - 1, start) : ""
        let opensHere = before.isEmpty || before == " " || "([{\u{201C}\u{2018}\n\t".contains(before)
        let tr = state.tr
        try? tr.insertText(opensHere ? open : close, start, end)
        return tr
    }
}
