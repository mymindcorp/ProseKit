#if canImport(UIKit)
import UIKit
import DocumentModel
import EditorStateKit

/// Produces spelling-error decorations for a document using `UITextChecker`.
/// Lives in the renderer because `UITextChecker` is a UIKit facility; the
/// decorations it returns are drawn as dotted red underlines.
enum SpellCheck {
    /// One checker for every pass. Constructing one isn't free, and a
    /// keystroke shouldn't pay for it.
    @MainActor private static let checker = UITextChecker()

    /// Spelling decorations for the textblocks overlapping `range` (or the whole
    /// document when nil). Bounding to the visible range keeps the cost
    /// independent of document size. `@MainActor` because `UITextChecker` is
    /// main-actor isolated — callers debounce + bound the range so the pass is
    /// cheap enough to run on the main actor.
    @MainActor
    static func decorations(for doc: Node, in range: ClosedRange<Int>? = nil, language: String = "en") -> [Decoration] {
        var result: [Decoration] = []
        let from = max(range?.lowerBound ?? 0, 0)
        let to = min(range?.upperBound ?? doc.content.size, doc.content.size)
        // `nodesBetween` skips the blocks before `from` and stops at `to`;
        // walking every descendant to find the few in range made a bounded
        // pass cost the whole document anyway.
        doc.nodesBetween(from, to) { node, pos, _, _ in
            guard node.isTextblock else { return true }
            if node.type.spec.code { return false } // don't spell-check code
            let chars = TextNavigation.inlineCharacters(of: node)
            result.append(contentsOf: check(chars[...], at: pos + 1, language: language))
            return false
        }
        return result
    }

    /// Re-check only the words an edit touched.
    ///
    /// `focus` is the edited range, in current-document positions. Within each
    /// textblock it reaches, the span checked is widened to whole words — from
    /// the start of the word the edit began in (or ended just after) to the end
    /// of the word it finished in — so a keystroke costs the word under the
    /// caret, not the paragraph around it. Returns the spans actually checked
    /// so the caller can splice the result into a cache and keep the rest.
    ///
    /// A space typed into the middle of a word, or a backspace joining two,
    /// changes the words on both sides of the edit; widening from the character
    /// before the edit to the one after it covers both.
    @MainActor
    static func recheck(_ doc: Node, around focus: ClosedRange<Int>, language: String = "en") -> (checked: [ClosedRange<Int>], decorations: [Decoration]) {
        var checked: [ClosedRange<Int>] = []
        var decorations: [Decoration] = []
        let from = max(focus.lowerBound, 0)
        let to = min(focus.upperBound, doc.content.size)
        doc.nodesBetween(from, to) { node, pos, _, _ in
            guard node.isTextblock else { return true }
            if node.type.spec.code { return false }
            let contentStart = pos + 1
            let chars = TextNavigation.inlineCharacters(of: node)
            var a = min(max(from - contentStart, 0), chars.count)
            var b = min(max(to - contentStart, 0), chars.count)
            while a > 0, !isWordBoundary(chars[a - 1]) { a -= 1 }
            while b < chars.count, !isWordBoundary(chars[b]) { b += 1 }
            guard a < b else { return false } // the edit touched only whitespace
            checked.append(contentStart + a ... contentStart + b)
            decorations.append(contentsOf: check(chars[a ..< b], at: contentStart + a, language: language))
            return false
        }
        return (checked, decorations)
    }

    /// Whitespace, or the placeholder `inlineCharacters` uses for an inline
    /// atom (an image, a mention): either ends a word.
    private static func isWordBoundary(_ c: Character) -> Bool {
        c.isWhitespace || c == "\u{fffc}"
    }

    /// Run the checker over `chars`, which begin at document position `base`.
    @MainActor
    private static func check(_ chars: ArraySlice<Character>, at base: Int, language: String) -> [Decoration] {
        let text = String(chars)
        let ns = text as NSString
        var result: [Decoration] = []
        // The checker reports UTF-16 offsets; document positions count
        // characters. Its results come back in order, so one cursor over
        // `chars` converts them all in a single pass.
        var index = chars.startIndex
        var utf16Offset = 0
        func position(atUTF16 target: Int) -> Int {
            while utf16Offset < target, index < chars.endIndex {
                utf16Offset += chars[index].utf16.count
                index += 1
            }
            return base + (index - chars.startIndex)
        }
        var offset = 0
        while offset < ns.length {
            let range = checker.rangeOfMisspelledWord(
                in: text,
                range: NSRange(location: offset, length: ns.length - offset),
                startingAt: offset, wrap: false, language: language)
            if range.location == NSNotFound { break }
            let from = position(atUTF16: range.location)
            let to = position(atUTF16: range.location + range.length)
            result.append(.inline(from, to, ["spelling": "1"]))
            offset = range.location + range.length
        }
        return result
    }
}
#endif
