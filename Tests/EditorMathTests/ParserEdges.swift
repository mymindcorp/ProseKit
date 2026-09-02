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
}
