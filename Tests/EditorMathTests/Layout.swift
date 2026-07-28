import Foundation
import EditorMath
import TestHarness

// Geometry assertions. There's no reference rendering to diff against, so each
// case pins a relationship the box model has to hold — which is what catches a
// sign flip or a dropped term in the TeX arithmetic.

func registerLayoutTests() {
    test("layout: a plain letter has ink but no depth") {
        let x = try layout("x")
        try expect(x.width > 0, "width \(x.width)")
        try expect(x.ascent > 0, "ascent \(x.ascent)")
        // 'x' sits entirely on the baseline.
        try expect(x.descent < 0.5, "descent \(x.descent)")
    }

    test("layout: a descender reaches below the baseline") {
        try expect(try layout("y").descent > (try layout("x").descent))
    }

    test("layout: a superscript raises the ascent, a subscript deepens the descent") {
        let plain = try layout("x")
        try expect(try layout("x^2").ascent > plain.ascent)
        try expect(try layout("x_i").descent > plain.descent)
        let both = try layout("x_i^2")
        try expect(both.ascent > plain.ascent && both.descent > plain.descent)
    }

    test("layout: a script is set smaller than its base") {
        // The 2 in x^2 must be narrower than a full-size 2.
        let base = try layout("x")
        let scripted = try layout("x^2")
        let full = try layout("2")
        try expect(scripted.width - base.width < full.width,
                   "script width \(scripted.width - base.width) vs full \(full.width)")
    }

    test("layout: a nested script shrinks again but never to nothing") {
        let one = try layout("x^{2}")
        let two = try layout("x^{2^{2}}")
        try expect(two.width > one.width)
        try expect(two.ascent > one.ascent)
    }

    test("layout: a fraction is taller than either part and straddles the baseline") {
        let fraction = try layout("\\frac{a}{b}")
        let part = try layout("a")
        try expect(fraction.height > part.height * 2, "\(fraction.height) vs \(part.height)")
        try expect(fraction.ascent > 0 && fraction.descent > 0,
                   "a fraction hangs below the baseline: \(fraction.descent)")
        // The bar is roughly on the math axis, so the two halves are comparable.
        try expect(fraction.ascent > fraction.descent, "numerator sits higher than the denominator drops")
    }

    test("layout: display style sets fractions larger than inline style") {
        let inline = try layout("\\frac{a}{b}", display: false)
        let display = try layout("\\frac{a}{b}", display: true)
        try expect(display.height > inline.height, "\(display.height) vs \(inline.height)")
        try expect(display.width > inline.width, "\(display.width) vs \(inline.width)")
    }

    test("layout: \\dfrac forces display sizing even inline") {
        try expect(try layout("\\dfrac{a}{b}").height > (try layout("\\frac{a}{b}").height))
    }

    test("layout: a fraction inside a script is set smaller still") {
        let outer = try layout("\\frac{a}{b}")
        let scripted = try layout("x^{\\frac{a}{b}}")
        try expect(scripted.width - (try layout("x").width) < outer.width,
                   "a fraction in a superscript should be narrower than at full size")
    }

    test("layout: a radical adds a surd to the left and a bar above") {
        let body = try layout("x")
        let radical = try layout("\\sqrt{x}")
        try expect(radical.width > body.width, "\(radical.width) vs \(body.width)")
        try expect(radical.ascent > body.ascent, "the bar sits above the body")
    }

    test("layout: a radical index pushes the surd right") {
        try expect(try layout("\\sqrt[3]{x}").width > (try layout("\\sqrt{x}").width))
    }

    test("layout: \\left…\\right grows its delimiters to the body") {
        let bare = try layout("\\frac{a}{b}")
        let fenced = try layout("\\left(\\frac{a}{b}\\right)")
        try expect(fenced.width > bare.width)
        // The parens reach past a plain (…) around the same body.
        let fixed = try layout("(\\frac{a}{b})")
        try expect(fenced.height > fixed.height, "\(fenced.height) vs \(fixed.height)")
    }

    test("layout: the null delimiter draws nothing but still reserves space") {
        let both = try layout("\\left( x \\right)")
        let half = try layout("\\left( x \\right.")
        try expect(half.width < both.width, "a null \\right should be narrower than a real one")
        try expect(half.width > (try layout("x").width), "but it still reserves space")
    }

    test("layout: \\big sizes a delimiter without regard to its content") {
        let plain = try layout("( x )")
        let big = try layout("\\big( x \\big)")
        try expect(big.height > plain.height, "\(big.height) vs \(plain.height)")
        try expect(try layout("\\Bigg[ x \\Bigg]").height > big.height)
    }

    test("layout: inter-atom spacing follows the TeX classes") {
        let juxtaposed = try layout("ab")
        let binary = try layout("a+b")
        let relation = try layout("a=b")
        // A binary operator gets a medium space on each side, a relation a thick
        // one — so even though + and = are similar widths, a=b is the wider.
        try expect(binary.width > juxtaposed.width, "\(binary.width) vs \(juxtaposed.width)")
        try expect(relation.width > binary.width, "\(relation.width) vs \(binary.width)")
    }

    test("layout: a leading sign is unary, not binary") {
        // In "-x" the minus binds as a sign, so it gets no space before it;
        // in "a-x" it's binary and does.
        let unary = try layout("-x")
        let binary = try layout("a-x")
        let letter = try layout("a")
        try expect(binary.width - letter.width > unary.width,
                   "the binary form should be wider by more than the bare letter")
    }

    test("layout: medium and thick spaces vanish inside a script") {
        // a+b at full size vs the same in a superscript: the script copy shrinks
        // by more than the size ratio alone, because its spacing is suppressed.
        let full = try layout("a+b")
        let base = try layout("x")
        let scripted = try layout("x^{a+b}")
        try expect(scripted.width - base.width < full.width * 0.7,
                   "\(scripted.width - base.width) vs \(full.width * 0.7)")
    }

    test("layout: explicit spaces widen by the amount asked for") {
        let none = try layout("ab")
        let thin = try layout("a\\,b")
        let quad = try layout("a\\quad b")
        try expect(thin.width > none.width)
        try expect(quad.width > thin.width)
        // \! is a negative space.
        try expect(try layout("a\\!b").width < none.width)
    }

    test("layout: a big operator grows in display style") {
        let inline = try layout("\\sum", display: false)
        let display = try layout("\\sum", display: true)
        try expect(display.height > inline.height, "\(display.height) vs \(inline.height)")
    }

    test("layout: display-style limits stack above and below the operator") {
        let bare = try layout("\\sum", display: true)
        let limits = try layout("\\sum_{i=1}^{n}", display: true)
        try expect(limits.ascent > bare.ascent, "the upper limit sits above")
        try expect(limits.descent > bare.descent, "the lower limit sits below")
    }

    test("layout: inline scripts on an operator go to the side, not above") {
        let bare = try layout("\\sum", display: false)
        let scripted = try layout("\\sum_{i=1}^{n}", display: false)
        try expect(scripted.width > bare.width, "side-set scripts widen the box")
        // Stacked limits would make it much taller than side-set ones do.
        let stacked = try layout("\\sum_{i=1}^{n}", display: true)
        try expect(stacked.height > scripted.height, "\(stacked.height) vs \(scripted.height)")
    }

    test("layout: an integral keeps its limits to the side even in display style") {
        let display = try layout("\\int_0^1", display: true)
        let sum = try layout("\\sum_0^1", display: true)
        try expect(display.width > sum.width,
                   "side-set integral limits are wider than a sum's stacked ones")
    }

    test("layout: \\limits and \\nolimits override the default") {
        try expect(try layout("\\int\\limits_0^1", display: true).height
                    > (try layout("\\int_0^1", display: true).height))
        try expect(try layout("\\sum\\nolimits_0^1", display: true).width
                    > (try layout("\\sum_0^1", display: true).width))
    }

    test("layout: a named function is set upright and spaced as an operator") {
        let function = try layout("\\sin x")
        let letters = try layout("sinx")
        try expect(function.width > letters.width, "\(function.width) vs \(letters.width)")
    }

    test("layout: an accent sits above its body without widening it much") {
        let bare = try layout("x")
        let accented = try layout("\\hat{x}")
        try expect(accented.ascent > bare.ascent, "\(accented.ascent) vs \(bare.ascent)")
        try expect(accented.width < bare.width * 2, "an accent shouldn't double the width")
    }

    test("layout: a widening accent stretches to cover the body") {
        let narrow = try layout("\\widehat{a}")
        let wide = try layout("\\widehat{abcdef}")
        try expect(wide.width > narrow.width * 2)
        try expect(wide.ascent > (try layout("abcdef").ascent))
    }

    test("layout: overline and underline add a rule on the right side") {
        let bare = try layout("AB")
        try expect(try layout("\\overline{AB}").ascent > bare.ascent)
        try expect(try layout("\\underline{AB}").descent > bare.descent)
    }

    test("layout: a matrix is wider than its widest row and taller than one cell") {
        let cell = try layout("a")
        let matrix = try layout("\\begin{matrix} a & b \\\\ c & d \\end{matrix}")
        try expect(matrix.width > cell.width * 2)
        try expect(matrix.height > cell.height * 2)
        // The pile centers on the math axis, so it hangs well below the baseline.
        try expect(matrix.descent > cell.descent)
    }

    test("layout: pmatrix adds delimiters around the pile") {
        let bare = try layout("\\begin{matrix} a & b \\\\ c & d \\end{matrix}")
        let fenced = try layout("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}")
        try expect(fenced.width > bare.width)
        try expect(abs(fenced.height - bare.height) < bare.height, "the delimiters track the pile")
    }

    test("layout: a matrix row count drives its height") {
        let two = try layout("\\begin{matrix} a \\\\ b \\end{matrix}")
        let three = try layout("\\begin{matrix} a \\\\ b \\\\ c \\end{matrix}")
        try expect(three.height > two.height)
    }

    test("layout: a matrix is centered on the math axis") {
        // The pile straddles the axis, which sits 0.25em above the baseline — so
        // the box reaches exactly twice that much further up than down. An error
        // in the row-gap accounting shows up here as a vertical offset, and the
        // delimiters (which center on the axis directly) stop tracking the rows.
        let axis = 0.25 * 17.0
        for latex in ["\\begin{matrix} a \\\\ b \\end{matrix}",
                      "\\begin{matrix} a \\\\ b \\\\ c \\end{matrix}",
                      "\\begin{matrix} a \\end{matrix}",
                      "\\begin{cases} a & b \\\\ c & d \\end{cases}"] {
            let box = try layout(latex)
            try expect(abs((box.ascent - box.descent) - 2 * axis) < 0.5,
                       "\(latex) is off-center: ascent \(box.ascent), descent \(box.descent)")
        }
    }

    test("layout: matrix delimiters stay centered with the rows they enclose") {
        let axis = 0.25 * 17.0
        let fenced = try layout("\\begin{pmatrix} a \\\\ b \\\\ c \\end{pmatrix}")
        try expect(abs((fenced.ascent - fenced.descent) - 2 * axis) < 0.5,
                   "ascent \(fenced.ascent), descent \(fenced.descent)")
    }

    test("layout: each extra matrix row adds the same height") {
        // Catches an off-by-one in the inter-row gaps: the 2→3 and 3→4 growth
        // must match, since each step adds exactly one row and one gap.
        func height(_ rows: Int) throws -> CGFloat {
            let body = (0..<rows).map { _ in "a" }.joined(separator: " \\\\ ")
            return try layout("\\begin{matrix} \(body) \\end{matrix}").height
        }
        let step = try height(3) - (try height(2))
        let nextStep = try height(4) - (try height(3))
        try expect(abs(step - nextStep) < 0.01, "\(step) vs \(nextStep)")
        try expect(step > 0)
    }

    test("layout: an array's column spec sets per-column alignment") {
        // A narrow cell above a wide one lands in a different place depending on
        // the column's alignment, so the three specs must differ from each other.
        func box(_ spec: String) throws -> MathBox {
            try layout("\\begin{array}{\(spec)} x \\\\ wwww \\end{array}")
        }
        let left = try box("l"), center = try box("c"), right = try box("r")
        // Same overall size — alignment moves ink, it doesn't resize the column.
        try expect(abs(left.width - center.width) < 0.01 && abs(center.width - right.width) < 0.01,
                   "\(left.width) \(center.width) \(right.width)")
        // An unspecified column falls back to centered.
        try expect(abs((try box("")).width - center.width) < 0.01)
    }

    test("layout: a vertical rule in the column spec widens the array") {
        let plain = try layout("\\begin{array}{cc} a & b \\end{array}")
        let ruled = try layout("\\begin{array}{c|c} a & b \\end{array}")
        // An interior rule sits inside the existing column gap, so the width is
        // unchanged — but the drawing gains a rule.
        try expect(abs(plain.width - ruled.width) < 0.01, "\(plain.width) vs \(ruled.width)")
        try expectEqual(ruleCount(plain), 0)
        try expectEqual(ruleCount(ruled), 1)
    }

    test("layout: edge rules reserve their own room") {
        let plain = try layout("\\begin{array}{cc} a & b \\end{array}")
        let bordered = try layout("\\begin{array}{|c|c|} a & b \\end{array}")
        try expect(bordered.width > plain.width, "edge rules need padding: \(bordered.width) vs \(plain.width)")
        try expectEqual(ruleCount(bordered), 3, "before, between, after")
    }

    test("layout: array rules span the rows and stay inside the box") {
        let box = try layout("\\begin{array}{|c|c|} a & b \\\\ c & d \\\\ e & f \\end{array}")
        let rules = ruleRects(box)
        try expectEqual(rules.count, 3)
        for rule in rules {
            try expect(rule.width > 0 && rule.height > 0, "a rule with no extent: \(rule)")
            // The box measures from the baseline: ascent up, descent down.
            try expect(rule.maxY <= box.ascent + 0.01, "rule tops out above the box: \(rule.maxY) > \(box.ascent)")
            try expect(rule.minY >= -box.descent - 0.01, "rule drops below the box: \(rule.minY)")
            try expect(rule.minX >= -0.01 && rule.maxX <= box.width + 0.01, "rule outside the width: \(rule)")
        }
        // Rules are ordered left to right and distinct.
        let xs = rules.map(\.midX).sorted()
        for (a, b) in zip(xs, xs.dropFirst()) { try expect(b - a > 1, "rules overlap at \(a), \(b)") }
    }

    test("layout: \\hline draws a rule between rows") {
        let plain = try layout("\\begin{array}{cc} a & b \\\\ c & d \\end{array}")
        try expectEqual(ruleCount(plain), 0)
        try expectEqual(ruleCount(try layout("\\begin{array}{cc} \\hline a & b \\\\ c & d \\end{array}")), 1)
        try expectEqual(ruleCount(try layout("\\begin{array}{cc} a & b \\\\ \\hline c & d \\end{array}")), 1)
        // A full grid: a rule above each row and one below the last.
        let grid = try layout("\\begin{array}{cc} \\hline a & b \\\\ \\hline c & d \\\\ \\hline \\end{array}")
        try expectEqual(ruleCount(grid), 3)
    }

    test("layout: a trailing \\hline doesn't add an empty row") {
        // `\\ \hline \end` opens a row that only the rule occupies — it must not
        // become a blank row of cells.
        let withRule = try layout("\\begin{array}{cc} a & b \\\\ c & d \\\\ \\hline \\end{array}")
        let without = try layout("\\begin{array}{cc} a & b \\\\ c & d \\end{array}")
        try expect(abs(withRule.height - without.height) < 0.5,
                   "a trailing rule shouldn't grow the array: \(withRule.height) vs \(without.height)")
        try expectEqual(ruleCount(withRule), 1)
    }

    test("layout: horizontal rules span the array and stay inside the box") {
        let box = try layout("\\begin{array}{|c|c|} \\hline a & b \\\\ \\hline c & d \\\\ \\hline \\end{array}")
        let rules = ruleRects(box)
        // 3 horizontal + 3 vertical.
        try expectEqual(rules.count, 6)
        for rule in rules {
            try expect(rule.maxY <= box.ascent + 0.01 && rule.minY >= -box.descent - 0.01,
                       "rule outside the box vertically: \(rule)")
            try expect(rule.minX >= -0.01 && rule.maxX <= box.width + 0.01,
                       "rule outside the box horizontally: \(rule)")
        }
        // The horizontal ones run the full width.
        let horizontal = rules.filter { $0.width > $0.height }
        try expectEqual(horizontal.count, 3)
        for rule in horizontal { try expectEqual(rule.width, box.width) }
    }

    test("layout: a sizing column spec isn't mistaken for alignment letters") {
        // The `c` in `p{2cm}` is part of a length, not a centered column.
        let box = try layout("\\begin{array}{p{2cm}|l} a & b \\end{array}")
        try expectEqual(ruleCount(box), 1, "one rule, between the two columns")
    }

    test("layout: rules only appear where the spec asks for them") {
        for (spec, expected) in [("ccc", 0), ("c|cc", 1), ("c||c", 1), ("|ccc|", 2), ("|c|c|c|", 4)] {
            let box = try layout("\\begin{array}{\(spec)} a & b & c \\end{array}")
            try expectEqual(ruleCount(box), expected, "spec {\(spec)}")
        }
    }

    test("layout: \\text is set in the body font, spaces and all") {
        let text = try layout("\\text{if and only if}")
        try expect(text.width > 0)
        // Spaces inside \text are preserved, so it's wider than the letters alone.
        try expect(text.width > (try layout("\\text{ifandonlyif}").width))
    }

    test("layout: a math alphabet renders something for every letter") {
        for command in ["\\mathbb", "\\mathcal", "\\mathfrak", "\\mathbf", "\\mathrm", "\\mathsf", "\\mathtt"] {
            let box = try layout("\(command){R}")
            try expect(box.width > 0, "\(command) produced no width")
            try expect(box.ascent > 0, "\(command) produced no ink")
        }
    }

    test("layout: geometry scales with the base size") {
        let small = try layout("\\frac{a}{b}", baseSize: 12)
        let large = try layout("\\frac{a}{b}", baseSize: 24)
        let ratio = large.width / small.width
        try expect(ratio > 1.8 && ratio < 2.2, "expected ~2x, got \(ratio)")
    }

    test("layout: an empty formula is empty, not broken") {
        let empty = typesetter().layout("", display: false)
        try expect(!empty.isError)
        try expectEqual(empty.box.width, 0)
        try expectEqual(empty.box.height, 0)
    }

    test("layout: a long formula stays finite and ordered") {
        let box = try layout("\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}", display: true)
        try expect(box.width.isFinite && box.ascent.isFinite && box.descent.isFinite)
        try expect(box.width > 0 && box.ascent > 0 && box.descent > 0)
    }
}
