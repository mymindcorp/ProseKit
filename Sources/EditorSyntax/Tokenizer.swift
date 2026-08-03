#if canImport(UIKit)
import Foundation
import UIKit
import EditorUIKit

/// One regex rule: every (non-overlapping) match of `pattern` is colored.
struct SyntaxRule {
    let regex: NSRegularExpression
    let color: UIColor
}

func rule(_ pattern: String, _ color: UIColor) -> SyntaxRule {
    // Patterns are authored carefully; a bad one is a programmer error.
    SyntaxRule(regex: try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
               color: color)
}

/// Apply rules in order, emitting a `SyntaxToken` for each match that doesn't
/// overlap an already-claimed range. Order matters: put comments and strings
/// first so keywords/numbers inside them aren't recolored. Token ranges are
/// grapheme offsets (what the renderer expects).
func scan(_ code: String, _ rules: [SyntaxRule]) -> [SyntaxToken] {
    let ns = code as NSString
    guard ns.length > 0 else { return [] }
    var taken = [Bool](repeating: false, count: ns.length)
    var claimed: [(range: NSRange, color: UIColor)] = []
    let whole = NSRange(location: 0, length: ns.length)
    for rule in rules {
        for match in rule.regex.matches(in: code, range: whole) {
            let r = match.range
            guard r.location != NSNotFound, r.length > 0 else { continue }
            var overlaps = false
            for i in r.location ..< (r.location + r.length) where taken[i] { overlaps = true; break }
            if overlaps { continue }
            for i in r.location ..< (r.location + r.length) { taken[i] = true }
            claimed.append((r, rule.color))
        }
    }

    // Matches are non-overlapping (`taken` guarantees it), so ordering them by
    // UTF-16 location makes every bound monotonic and one cursor can walk the
    // string a single time. Converting each match on its own instead meant
    // `String.distance` re-walking from `startIndex` per token, which made
    // highlighting quadratic in the size of the block.
    claimed.sort { $0.range.location < $1.range.location }
    var cursor = code.startIndex
    var cursorUTF16 = 0
    var cursorGrapheme = 0
    /// The offset of the grapheme *containing* `utf16Offset` — the same rounding
    /// `String.distance` applied to a bound landing inside one.
    func graphemeOffset(_ utf16Offset: Int) -> Int {
        while cursor < code.endIndex {
            let width = code[cursor].utf16.count
            if cursorUTF16 + width > utf16Offset { break }
            cursorUTF16 += width
            cursor = code.index(after: cursor)
            cursorGrapheme += 1
        }
        return cursorGrapheme
    }

    var tokens: [SyntaxToken] = []
    tokens.reserveCapacity(claimed.count)
    for (r, color) in claimed {
        let lo = graphemeOffset(r.location)
        let hi = graphemeOffset(r.location + r.length)
        tokens.append(SyntaxToken(range: lo ..< hi, color: color))
    }
    return tokens
}
#endif
