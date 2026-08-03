#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorSyntax
@testable import EditorUIKit

/// The cost of turning tokenizer matches into styled ranges.
///
/// Both ends of the highlighting path convert between UTF-16 and grapheme
/// offsets. Doing that per token with `String.distance` / `String.index(offsetBy:)`
/// walks from `startIndex` every time, so highlighting cost grew with
/// (block size x token count); both now walk the string once per block.
@MainActor
final class SyntaxOffsetPerfTests: XCTestCase {
    /// JavaScript-shaped source of roughly `chars` bytes. `exotic` sprinkles
    /// non-ASCII through the comments so the string isn't fast-ASCII.
    private func source(chars: Int, exotic: Bool) -> String {
        var out = ""
        var i = 0
        while out.utf8.count < chars {
            let note = exotic ? "número \(i) — coño ✅" : "number \(i) - plain"
            out += """
                // \(note)
                const value\(i) = function(alpha, beta) {
                    if (alpha > \(i)) { return "text \(i)" + beta; }
                    return null;
                }

                """
            i += 1
        }
        return out
    }

    /// Best of `runs`, in milliseconds — best-of resists scheduler noise better
    /// than a mean on a shared machine.
    private func bestMs(_ runs: Int = 7, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0 ..< runs {
            let t = CFAbsoluteTimeGetCurrent()
            body()
            best = min(best, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        return best
    }

    /// How `scan` used to convert a match: `Range(_:in:)` plus a `distance` walk
    /// from `startIndex`, once per token. The oracle for the cursor that
    /// replaced it — the two must agree on every grapheme boundary, including
    /// the ones that aren't one UTF-16 unit wide.
    private func referenceScan(_ code: String, _ rules: [SyntaxRule]) -> [Range<Int>] {
        let ns = code as NSString
        guard ns.length > 0 else { return [] }
        var taken = [Bool](repeating: false, count: ns.length)
        var ranges: [Range<Int>] = []
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
                ranges.append(lo ..< hi)
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Graphemes wider than one UTF-16 unit are where a cursor can drift from a
    /// `distance` walk: astral emoji, ZWJ sequences, regional-indicator flags,
    /// and combining marks all have to advance the offset by the same amount.
    func testOffsetsMatchStringDistanceAcrossGraphemeShapes() {
        let ruleSet = rules(for: .javascript, .default)
        let samples = [
            "const a = 1 // plain ascii",
            "// 👩‍👩‍👧‍👦 family\nconst b = \"🇯🇵 flag\"; // e\u{0301} combining",
            "const c = \"🎉\"; /* 🧑🏽‍🚀 astral */ const d = 42",
            "// e\u{0301}\u{0323} stacked marks\nfunction f() { return \"\u{1F1FA}\u{1F1F8}\" }",
            "\u{1F600}const g = 0.5 // trailing \u{1F600}",
        ]
        for code in samples {
            let tokens = scan(code, ruleSet).map(\.range)
            XCTAssertEqual(tokens, referenceScan(code, ruleSet),
                           "offsets diverged from the String.distance walk for: \(code)")
        }
        // And on a large exotic block, where the cursor is reused across many
        // tokens rather than restarted.
        let big = source(chars: 8_000, exotic: true)
        XCTAssertEqual(scan(big, ruleSet).map(\.range), referenceScan(big, ruleSet))
    }

    /// The tokenizer half. Matching is fixed cost, so what changes with block
    /// size is the offset conversion; rules are built once, outside the timer.
    func testScanScaling() {
        let ruleSet = rules(for: .javascript, .default)
        var perCharacter: [Double] = []
        for exotic in [false, true] {
            for n in [2_000, 8_000, 32_000] {
                let code = source(chars: n, exotic: exotic)
                let tokens = scan(code, ruleSet).count
                let ms = bestMs { _ = scan(code, ruleSet) }
                if !exotic { perCharacter.append(ms / Double(code.count)) }
                print(unsafe "SCAN exotic=\(exotic) chars=\(code.count) tokens=\(tokens) "
                    + "best=\(String(format: "%.2f", ms))ms")
            }
        }
        // Cost per character must stay roughly flat. When each token re-walked
        // the string this ratio was ~7x; linear conversion holds it near 1x, so
        // 3x fails a regression well before it fails CI noise.
        let ratio = perCharacter[2] / perCharacter[0]
        XCTAssertLessThan(ratio, 3.0, "scan is scaling super-linearly in block size")
    }

    /// The renderer half: the delta between laying a code block out with and
    /// without a highlighter is the tokenize + apply cost.
    func testLayoutHighlightScaling() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let hl = makeSyntaxHighlighter()
        let theme = DocumentTheme()
        for exotic in [false, true] {
            for n in [2_000, 8_000, 32_000] {
                let code = source(chars: n, exotic: exotic)
                let block = try s.node("codeBlock", ["language": .string("javascript")],
                                       content: Fragment.from([s.text(code)]))
                let doc = try s.node("doc", [:], content: Fragment.from([block]))
                let plain = bestMs(5) { _ = DocumentLayout(doc: doc, width: 390, theme: theme) }
                let lit = bestMs(5) {
                    _ = DocumentLayout(doc: doc, width: 390, theme: theme, syntaxHighlighter: hl)
                }
                print(unsafe "LAYOUT exotic=\(exotic) chars=\(code.count) "
                    + "plain=\(String(format: "%.1f", plain))ms lit=\(String(format: "%.1f", lit))ms "
                    + "delta=\(String(format: "%.1f", lit - plain))ms")
            }
        }
    }
}
#endif
