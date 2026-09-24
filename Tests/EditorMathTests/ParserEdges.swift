import Foundation
import CoreText
import EditorMath
import TestHarness

// Corners of the parser and the box model the corpus doesn't reach: a stray
// closing brace, array column specs with fixed-width columns, a null
// delimiter, a delimiter around nothing, font switches over nested groups and
// constructs, and side-scripts on an ordinary atom in display style.

func registerParserEdgeTests() {
    test("parser: a closing brace with nothing open is an error") {
        try expectNotNil(parseError("a}"))
        try expectNotNil(parseError("}"))
    }

    test("parser: array column specs accept fixed-width columns and rules") {
        for spec in ["p{3cm}c", "m{2em}|r", "b{1in}", "pc", "|l|c|", "{c}c"] {
            let latex = "\\begin{array}{\(spec)} a & b \\\\ c & d \\end{array}"
            let result = typesetter().layout(latex, display: false)
            try expect(!result.isError, "\(spec): \(result.error ?? "")")
        }
        let ruled = try layout("\\begin{array}{|c|} a \\end{array}")
        try expect(ruleCount(ruled) >= 2, "column rules are drawn")
    }

    test("layout: a null delimiter takes up a little space and draws nothing") {
        let bare = try layout("x")
        let nulled = try layout("\\left. x \\right.")
        try expect(nulled.width > bare.width, "the null delimiters still leave their gap")
        try expectEqual(ruleCount(nulled), 0)
    }

    test("layout: a delimiter around nothing keeps its natural size") {
        let empty = try layout("\\left( {} \\right)")
        let plain = try layout("()")
        try expect(abs(empty.height - plain.height) < 0.5, "nothing to grow around: \(empty.height) vs \(plain.height)")
    }

    test("layout: a font switch reaches into nested groups and leaves constructs alone") {
        let nested = try layout("\\mathbf{{ab}c}")
        let flat = try layout("\\mathbf{abc}")
        try expect(abs(nested.width - flat.width) < 0.5, "the inner group is bold too: \(nested.width) vs \(flat.width)")
        let construct = try layout("\\mathbf{\\frac{a}{b}}")
        try expectEqual(ruleCount(construct), 1, "the fraction survives the switch")
    }

    test("layout: display style puts limits on an operator but keeps scripts beside an ordinary atom") {
        let opText = try layout("\\sum_{a}^{b}", display: false)
        let opDisplay = try layout("\\sum_{a}^{b}", display: true)
        try expect(opDisplay.height > opText.height, "limits stack above and below")
        let atomDisplay = try layout("x_{a}^{b}", display: true)
        let atomText = try layout("x_{a}^{b}", display: false)
        try expect(atomDisplay.width > 0 && atomText.width > 0)
        // The scripts stay at the side: display style adds no stacking height
        // beyond the size change the style itself brings.
        try expect(atomDisplay.height < opDisplay.height)
    }

    test("parser: an array spec's unclosed width argument runs to the end") {
        // Reached only through the public initializer — inside `\begin{array}`
        // the braces have already been balanced by the group that holds them.
        try expectEqual(ArrayColumns(spec: "p{3cm").alignments, [.left])
        try expectEqual(ArrayColumns(spec: "c|p{3cm c").alignments, [.center, .left],
                        "everything after the open brace is its argument")
        try expectEqual(ArrayColumns(spec: "c|p{3cm c").rules, [1])
    }

    test("parser: an array spec skips what it doesn't know") {
        // `@{…}` inserts material between columns; it is neither a column nor a
        // rule, and neither is stray whitespace or an unknown letter.
        let spec = ArrayColumns(spec: "@{\\,} l x r @{}")
        try expectEqual(spec.alignments, [.left, .right])
        try expect(spec.rules.isEmpty)
    }

    test("parser: an escape inside \\text passes its character through") {
        // `\%` in text mode is a literal percent: the backslash goes, the
        // character stays, and an escaped brace doesn't open or close a group.
        let escaped = try layout("\\text{50\\%}")
        let literal = try layout("\\text{50%}")
        try expect(abs(escaped.width - literal.width) < 0.01, "\(escaped.width) vs \(literal.width)")
        let braces = try layout("\\text{\\{x\\}}")
        try expect(braces.width > (try layout("\\text{x}")).width, "the braces are drawn")
        // A backslash before a letter is not an escape; it stays in the text.
        try expectNil(parseError("\\text{a\\b}"))
    }

    test("parser: a \\text group left open is an error") {
        try expectNotNil(parseError("\\text{abc"))
        // The inner group closes; the outer one never does.
        try expectNotNil(parseError("\\text{a{b}"))
        try expectNotNil(parseError("\\begin{matrix"))
    }

    test("parser: a command that isn't a delimiter can't follow \\left") {
        try expectNotNil(parseError("\\left\\alpha x \\right)"))
        try expectNotNil(parseError("\\left( x \\right\\foo"))
        try expectNotNil(parseError("\\bigl\\sum"))
        try expectNil(parseError("\\left\\langle x \\right\\rangle"))
    }

    test("layout: an unbarred stack pushes its parts apart to clear each other") {
        // `\binom` stacks without a bar, so the only thing keeping a tall
        // numerator off a tall denominator is the minimum gap between them.
        // Two stacked fractions are each taller than the default shifts allow
        // for, so the parts have to be pushed apart.
        let stacked = try layout("\\binom{\\frac{a}{b}}{\\frac{a}{b}}")
        let bars = ruleRects(stacked)
        try expectEqual(bars.count, 2)
        guard bars.count == 2 else { return }
        let part = try layout("{\\scriptstyle\\frac{a}{b}}")
        let distance = abs(bars[0].midY - bars[1].midY)
        // Each bar sits at its fraction's axis, so the parts clear each other
        // exactly when the bars are at least one part's height apart.
        try expect(distance >= part.height, "the parts overlap: \(distance) vs \(part.height)")
        // And that is further apart than the unpushed shifts would put them.
        try expect(distance > (0.443 + 0.344) * 17, "not pushed: \(distance)")
    }
}
