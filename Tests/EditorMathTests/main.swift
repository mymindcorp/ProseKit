import Foundation
import CoreText
import EditorMath
import TestHarness

// The typesetter has no golden-image reference to compare against, so these
// tests assert on what the box model *guarantees*: that valid LaTeX parses and
// invalid LaTeX doesn't, and that each construct moves the formula's geometry in
// the direction it must (a fraction is taller than its parts, a superscript
// raises the ascent, display style is bigger than inline, …).

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) { collector.test(name, body) }

/// A fresh typesetter per call — the expensive part (font resolution) is cached
/// inside `EditorMath`, and this keeps the helpers usable from the harness's
/// `@Sendable` test bodies.
func typesetter(baseSize: CGFloat = 17) -> MathTypesetter {
    MathTypesetter(baseSize: baseSize, bodyFont: CTFontCreateWithName("Helvetica" as CFString, baseSize, nil))
}

/// Lay out a formula, failing the test if it didn't parse.
func layout(_ latex: String, display: Bool = false, baseSize: CGFloat = 17) throws -> MathBox {
    let result = typesetter(baseSize: baseSize).layout(latex, display: display)
    try expect(!result.isError, "\(latex) failed to parse: \(result.error ?? "")")
    return result.box
}

/// The parse error for a formula the typesetter should reject.
func parseError(_ latex: String) -> String? {
    typesetter().layout(latex, display: false).error
}

registerParserTests()
registerLayoutTests()
registerCorpusTests()

TestSuite.main("EditorMathTests", collector.all)
