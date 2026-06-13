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
    var tokens: [SyntaxToken] = []
    let whole = NSRange(location: 0, length: ns.length)
    for rule in rules {
        for match in rule.regex.matches(in: code, range: whole) {
            let r = match.range
            guard r.location != NSNotFound, r.length > 0 else { continue }
            var overlaps = false
            for i in r.location ..< (r.location + r.length) where taken[i] { overlaps = true; break }
            if overlaps { continue }
            for i in r.location ..< (r.location + r.length) { taken[i] = true }
            guard let swift = Range(r, in: code) else { continue }
            let lo = code.distance(from: code.startIndex, to: swift.lowerBound)
            let hi = code.distance(from: code.startIndex, to: swift.upperBound)
            tokens.append(SyntaxToken(range: lo ..< hi, color: rule.color))
        }
    }
    return tokens.sorted { $0.range.lowerBound < $1.range.lowerBound }
}
#endif
