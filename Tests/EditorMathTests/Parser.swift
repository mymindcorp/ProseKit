import Foundation
import EditorMath
import TestHarness

// What the parser accepts and — just as importantly — what it rejects, since a
// rejected formula is what makes the renderer fall back to showing its source
// instead of drawing something wrong.

func registerParserTests() {
    test("parser: accepts the common constructs") {
        let valid = [
            "x", "xy", "42", "3.14", "x + y", "a - b", "x = y", "x \\neq y",
            "x^2", "a_i", "x^2_i", "x_i^2", "{ab}^2", "f'(x)", "f''",
            "\\frac{a}{b}", "\\dfrac{a}{b}", "\\tfrac{a}{b}", "\\frac12",
            "\\binom{n}{k}", "\\sqrt{2}", "\\sqrt[3]{x}", "\\sqrt{\\frac{a}{b}}",
            "\\left(\\frac{a}{b}\\right)", "\\left[x\\right]", "\\left\\{x\\right\\}",
            "\\left| x \\right|", "\\left. x \\right)", "\\big( x \\big)", "\\Bigg[y\\Bigg]",
            "\\sum_{i=1}^{n} i", "\\prod_{k}a_k", "\\int_0^1 x\\,dx", "\\oint f",
            "\\lim_{x \\to \\infty} f(x)", "\\max_{x} f", "\\sin x", "\\log_2 n",
            "\\sin^2\\theta + \\cos^2\\theta = 1",
            "\\alpha\\beta\\gamma\\Omega", "\\infty", "\\partial x", "\\nabla f",
            "\\mathbb{R}", "\\mathbf{v}", "\\mathrm{d}x", "\\mathcal{L}", "\\mathfrak{g}",
            "\\text{if } x > 0", "\\textbf{bold}", "\\operatorname{tr} A",
            "\\vec{v}", "\\hat{x}", "\\bar{z}", "\\tilde{a}", "\\widehat{abc}",
            "\\overline{AB}", "\\underline{x}",
            "\\begin{matrix} a & b \\\\ c & d \\end{matrix}",
            "\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}",
            "\\begin{bmatrix} x \\end{bmatrix}",
            "\\begin{cases} 1 & x > 0 \\\\ 0 & x \\le 0 \\end{cases}",
            "\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}",
            "a \\quad b", "a\\,b", "a\\;b", "a\\!b",
            "\\displaystyle \\frac{a}{b}", "\\scriptstyle x",
            "x \\in \\mathbb{N}", "A \\subseteq B", "p \\Rightarrow q",
            "e^{i\\pi} + 1 = 0", "\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}",
            "\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}",
        ]
        for latex in valid {
            let result = typesetter().layout(latex, display: false)
            try expect(!result.isError, "expected \(latex) to parse, got: \(result.error ?? "")")
        }
    }

    test("parser: rejects malformed source") {
        let invalid = [
            "\\frac{a}",         // missing second argument
            "{a",                // unclosed group
            "a}",                // stray close
            "\\left(a",          // no \right
            "a \\right)",        // no \left
            "\\unknowncommand",
            "\\begin{matrix} a", // unterminated environment
            "\\end{matrix}",
            "\\begin{nope} x \\end{nope}",
            "\\begin{matrix} a \\end{pmatrix}",
            "\\sqrt",            // missing argument
            "\\left( x \\right", // missing closing delimiter
            "x^",                // missing script
            "\\limits",          // no operator to attach to
        ]
        for latex in invalid {
            try expect(parseError(latex) != nil, "expected \(latex) to be rejected")
        }
    }

    test("parser: a rejected formula still produces a drawable box of its source") {
        let result = typesetter().layout("\\frac{a}", display: false)
        try expect(result.isError)
        try expect(result.box.width > 0, "the verbatim fallback should have width")
        try expect(result.box.height > 0, "the verbatim fallback should have height")
    }

    test("parser: whitespace between tokens is insignificant") {
        let tight = try layout("\\frac{a}{b}")
        let loose = try layout("  \\frac { a } { b }  ")
        try expect(abs(tight.width - loose.width) < 0.01, "\(tight.width) vs \(loose.width)")
    }

    test("parser: an unbraced argument takes exactly one token") {
        // \frac12 is \frac{1}{2}, not \frac{12}{…}.
        let shorthand = try layout("\\frac12")
        let explicit = try layout("\\frac{1}{2}")
        try expect(abs(shorthand.width - explicit.width) < 0.01, "\(shorthand.width) vs \(explicit.width)")
    }

    test("parser: nesting depth is bounded") {
        let deep = String(repeating: "{", count: 200) + "x" + String(repeating: "}", count: 200)
        try expect(parseError(deep) != nil, "runaway nesting should be rejected, not recursed into")
    }
}
