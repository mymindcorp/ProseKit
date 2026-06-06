#if canImport(UIKit)
import UIKit
import DocumentModel
import EditorStateKit

/// Produces spelling-error decorations for a document using `UITextChecker`.
/// Lives in the renderer because `UITextChecker` is a UIKit facility; the
/// decorations it returns are drawn as dotted red underlines.
enum SpellCheck {
    /// Spelling decorations for the textblocks overlapping `range` (or the whole
    /// document when nil). Bounding to the visible range keeps the cost
    /// independent of document size. `@MainActor` because `UITextChecker` is
    /// main-actor isolated — callers debounce + bound the range so the pass is
    /// cheap enough to run on the main actor.
    @MainActor
    static func decorations(for doc: Node, in range: ClosedRange<Int>? = nil, language: String = "en") -> [Decoration] {
        let checker = UITextChecker()
        var result: [Decoration] = []
        doc.descendants { node, pos, _, _ in
            guard node.isTextblock else { return true }
            if node.type.spec.code { return false } // don't spell-check code
            let contentStart = pos + 1
            if let range, contentStart + node.content.size < range.lowerBound || contentStart > range.upperBound {
                return false // textblock outside the requested range
            }
            let text = String(TextNavigation.inlineCharacters(of: node))
            let ns = text as NSString
            var offset = 0
            while offset < ns.length {
                let range = checker.rangeOfMisspelledWord(
                    in: text,
                    range: NSRange(location: offset, length: ns.length - offset),
                    startingAt: offset, wrap: false, language: language)
                if range.location == NSNotFound { break }
                // UTF-16 offsets → grapheme offsets → document positions.
                let fromGrapheme = ns.substring(to: range.location).count
                let toGrapheme = ns.substring(to: range.location + range.length).count
                result.append(.inline(contentStart + fromGrapheme, contentStart + toGrapheme, ["spelling": "1"]))
                offset = range.location + range.length
            }
            return false
        }
        return result
    }
}
#endif
