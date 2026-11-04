import Foundation
import CoreText
import CoreGraphics
import EditorMath
import TestHarness

// Exact-geometry tests written against mutants of the parser and typesetter
// that the directional tests ("a fraction is taller than its parts") let
// through. Each one derives the expected number from the pieces it is built
// of — a script laid out on its own at the script size, TeX's Appendix G
// constants — so a flipped sign, a swapped constant or a dropped statement in
// the box arithmetic moves a value the test pins.

private let em: CGFloat = 17
/// The sizes the script styles are set at, computed the way the typesetter
/// computes them so the font cache hands back the very same fonts.
private let scriptSize = em * 0.7
private let scriptScriptSize = em * 0.5
/// TeX's default rule thickness and axis height at the base size.
private let rule = 0.04 * em
private let axis = 0.25 * em

private struct PlacedGlyph {
    let font: String
    let glyph: CGGlyph
    let at: CGPoint
}

/// Every glyph a box draws, in drawing order, with its pen position.
private func placedGlyphs(_ box: MathBox) -> [PlacedGlyph] {
    box.drawItems.flatMap { item -> [PlacedGlyph] in
        guard case let .glyphs(font, glyphs, positions) = item else { return [] }
        let name = CTFontCopyPostScriptName(font) as String
        return zip(glyphs, positions).map { PlacedGlyph(font: name, glyph: $0, at: $1) }
    }
}

/// How many separate glyph runs a box draws.
private func glyphRunCount(_ box: MathBox) -> Int {
    box.drawItems.filter { if case .glyphs = $0 { return true } else { return false } }.count
}

/// The bounds of every filled outline — the stretched delimiters and braces.
private func filledPathBounds(_ box: MathBox) -> [CGRect] {
    box.drawItems.compactMap { if case let .filledPath(path) = $0 { return path.boundingBox } else { return nil } }
}

/// The math font's x-height at a size. A run with no ink (`\operatorname{ }`
/// sets a roman space) reports the x-height of its font as its ascent, which
/// is the only way to read the roman face's metrics from outside.
private func xHeight(_ size: CGFloat = em) throws -> CGFloat {
    try layout("\\operatorname{ }", baseSize: size).ascent
}

private func expectClose(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.01,
                         _ what: String) throws {
    try expect(abs(actual - expected) <= tolerance, "\(what): \(actual), expected \(expected)")
}

/// The italic correction of a lone italic `V`, whose ink overhangs its
/// advance: a superscript is set past the advance by exactly that much.
private func italicCorrectionOfV() throws -> CGFloat {
    let v = try layout("V")
    let scripted = placedGlyphs(try layout("V^2"))
    try expectEqual(scripted.count, 2)
    let correction = scripted[1].at.x - v.width
    try expect(correction > 0.5, "an italic V overhangs its advance: \(correction)")
    return correction
}

func registerMathMutationKillTests() {
    // MARK: - Parser

    test("math kills: a line break in the source is whitespace like any other") {
        let spread = try layout("\\frac\n{a}\n{b}")
        let tight = try layout("\\frac{a}{b}")
        try expectClose(spread.width, tight.width, "width")
        try expectClose(spread.ascent, tight.ascent, "ascent")
        try expectClose(spread.descent, tight.descent, "descent")
        // A newline between a relation and a sign leaves the sign unary.
        try expectClose(try layout("x=\n-1").width, try layout("x= -1").width, "unary sign after a newline")
    }

    test("math kills: a decimal point joins a number only when a digit follows it") {
        try expectEqual(glyphRunCount(try layout("3.14")), 1)
        try expectEqual(placedGlyphs(try layout("3.14")).count, 4)
        // A full stop after a number is its own atom, not the number's tail.
        try expectEqual(glyphRunCount(try layout("3.")), 2)
        try expectEqual(glyphRunCount(try layout("3.x")), 3)
    }

    test("math kills: every prime typed is drawn") {
        try expectEqual(placedGlyphs(try layout("f'")).count, 2)
        try expectEqual(placedGlyphs(try layout("f''")).count, 3)
        try expectEqual(placedGlyphs(try layout("f'''")).count, 4)
    }

    test("math kills: \\cfrac and \\dbinom are display-style constructs even inline") {
        let cfrac = try layout("\\cfrac{a}{b}")
        let dfrac = try layout("\\dfrac{a}{b}")
        try expectClose(cfrac.width, dfrac.width, "\\cfrac width")
        try expectClose(cfrac.height, dfrac.height, "\\cfrac height")
        try expect(cfrac.height > (try layout("\\frac{a}{b}")).height + 1)

        let dbinom = try layout("\\dbinom{n}{k}")
        let displayBinom = try layout("\\binom{n}{k}", display: true)
        try expectClose(dbinom.width, displayBinom.width, "\\dbinom width")
        try expectClose(dbinom.height, displayBinom.height, "\\dbinom height")
        try expect(dbinom.height > (try layout("\\binom{n}{k}")).height + 1)
    }

    test("math kills: \\pmod, \\pod and \\mod each draw exactly their own pieces") {
        // (mod n) — both parentheses, the word, the argument.
        try expectEqual(placedGlyphs(try layout("\\pmod{n}")).count, 6)
        // (n) — no word.
        try expectEqual(placedGlyphs(try layout("\\pod{n}")).count, 3)
        // mod n — no parentheses.
        try expectEqual(placedGlyphs(try layout("\\mod{n}")).count, 4)
    }

    test("math kills: \\operatorname* stacks its scripts as limits in display style") {
        let word = try layout("\\operatorname{argmax}", display: true)
        let starred = try layout("\\operatorname*{argmax}_{x}", display: true)
        let plain = try layout("\\operatorname{argmax}_{x}", display: true)
        // Stacked, the narrow limit sits under the word and adds no width.
        try expectClose(starred.width, word.width, "starred width")
        try expect(plain.width > word.width + 1, "unstarred scripts go to the side: \(plain.width)")
        try expect(starred.descent > plain.descent, "the limit hangs below the word")
    }

    test("math kills: a trailing \\\\ before \\end adds no row") {
        let trailing = try layout("\\begin{matrix}a\\\\b\\\\\\end{matrix}")
        let bare = try layout("\\begin{matrix}a\\\\b\\end{matrix}")
        try expectClose(trailing.height, bare.height, "height")
        try expectClose(trailing.ascent, bare.ascent, "ascent")
    }

    // MARK: - Spacing

    test("math kills: the thin space beside an operator survives in a script") {
        // TeX never suppresses the operator's thin space, so a superscript
        // holding `\sin b` is exactly as much wider than one holding `b` as the
        // two are apart when set on their own at the script size.
        let difference = try layout("x^{\\sin b}").width - (try layout("x^{b}")).width
        let expected = try layout("\\sin b", baseSize: scriptSize).width
            - (try layout("b", baseSize: scriptSize)).width
        try expectClose(difference, expected, "\\sin b in a script")
    }

    test("math kills: punctuation is followed by a thin space") {
        let parts = try layout("a").width + (try layout(",")).width + (try layout("b")).width
        try expectClose(try layout("a,b").width, parts + 3.0 / 18 * em, "a,b")
    }

    test("math kills: a sign after punctuation is unary") {
        // `a,-b` — the minus has nothing to bind on its left, so it takes no
        // medium spaces: a, then a thin space, then the signed -b.
        let expected = try layout("a,").width + 3.0 / 18 * em + (try layout("-b")).width
        try expectClose(try layout("a,-b").width, expected, "a,-b")
    }

    // MARK: - Operators and scripts

    test("math kills: an inline big operator sets its scripts to the side") {
        let sum = try layout("\\sum")
        let scripted = try layout("\\sum_{k}^{n}")
        let k = try layout("k", baseSize: scriptSize)
        try expect(scripted.width >= sum.width + k.width,
                   "side-set scripts widen the operator: \(scripted.width) vs \(sum.width) + \(k.width)")
    }

    test("math kills: a big operator is centered on the math axis") {
        for display in [false, true] {
            let sum = try layout("\\sum", display: display)
            try expectClose((sum.ascent - sum.descent) / 2, axis, "\\sum center, display \(display)")
        }
    }

    test("math kills: a multi-letter nucleus hangs its subscript off its own depth") {
        // `\text{gy}` is one composite nucleus: the subscript drops below its
        // descender, not merely to the fixed minimum a single letter gets.
        let body = try layout("\\text{gy}")
        let x = try layout("x", baseSize: scriptSize)
        let shiftDown = max(body.descent + 0.05 * em, 0.15 * em, x.ascent - 0.8 * (try xHeight()))
        let scripted = try layout("\\text{gy}_x")
        try expectClose(scripted.descent, max(body.descent, shiftDown + x.descent), "descent")
        try expect(shiftDown > 0.15 * em, "the case has to exercise the composite rule")
    }

    test("math kills: limits pile a padding above and below the operator") {
        let sum = try layout("\\sum", display: true)
        let n = try layout("n", baseSize: scriptSize)
        let k = try layout("k", baseSize: scriptSize)

        let above = try layout("\\sum^{n}", display: true)
        let upGap = max(0.111 * em, 0.2 * em - n.descent)
        try expectClose(above.ascent, sum.ascent + upGap + n.descent + n.ascent + 0.1 * em, "ascent")

        let below = try layout("\\sum_{k}", display: true)
        let downGap = max(0.166 * em, 0.6 * em - k.ascent)
        try expectClose(below.descent, sum.descent + downGap + k.ascent + k.descent + 0.1 * em, "descent")
    }

    test("math kills: limits lean with the nucleus's italic correction") {
        // No big operator in this face slants, but a horizontal brace takes its
        // labels as limits and inherits its body's italic correction. Each
        // limit moves half of it — the upper right, the lower left — so the
        // upper ends up the whole correction right of the lower.
        let italicCorrection = try italicCorrectionOfV()
        let stacked = placedGlyphs(try layout("\\underbrace{V}^{1}_{1}"))
        try expectEqual(stacked.count, 3)
        try expectClose(stacked[1].at.x - stacked[2].at.x, italicCorrection, "upper vs lower label")
    }

    test("math kills: a superscript rises by the style's minimum shift") {
        let two = try layout("2", baseSize: scriptSize)
        let xh = try xHeight()
        for (display, minimum) in [(false, 0.363), (true, 0.413)] {
            let glyphs = placedGlyphs(try layout("x^2", display: display))
            let shiftUp = max(minimum * em, two.descent + 0.25 * xh)
            try expectClose(glyphs[1].at.y, shiftUp, "x^2 superscript, display \(display)")
        }
    }

    test("math kills: a superscript and subscript together keep four rules apart") {
        let two = try layout("2", baseSize: scriptSize)
        let xh = try xHeight()
        var shiftUp = max(0.363 * em, two.descent + 0.25 * xh)
        var shiftDown = 0.247 * em
        let clearance = 4 * rule
        let gap = (shiftUp - two.descent) - (two.ascent - shiftDown)
        try expect(gap < clearance, "the case has to need the push apart: \(gap)")
        shiftDown += clearance - gap
        let bottomOfSup = 0.8 * xh - (shiftUp - two.descent)
        if bottomOfSup > 0 { shiftUp += bottomOfSup; shiftDown -= bottomOfSup }

        let glyphs = placedGlyphs(try layout("x^2_2"))
        try expectClose(glyphs[1].at.y, shiftUp, "superscript")
        try expectClose(glyphs[2].at.y, -shiftDown, "subscript")
        let clear = (glyphs[1].at.y - two.descent) - (two.ascent + glyphs[2].at.y)
        try expectClose(clear, clearance, "clear air between the scripts")
    }

    test("math kills: a script pair's width counts the nucleus's italic correction") {
        let two = try layout("2", baseSize: scriptSize)
        let italicCorrection = try italicCorrectionOfV()
        let both = try layout("V^2_2")
        let v = try layout("V")
        try expectClose(both.width, v.width + italicCorrection + two.width + 0.05 * em, "V^2_2 width")
    }

    test("math kills: a group passes its last glyph's italic correction to its script") {
        let bare = placedGlyphs(try layout("V^2"))
        let grouped = placedGlyphs(try layout("{V}^2"))
        try expectClose(grouped[1].at.x, bare[1].at.x, "superscript x")
        try expect(bare[1].at.x > (try layout("V")).width + 0.5, "the correction has to matter")
    }

    test("math kills: an upright glyph has no negative italic correction") {
        // The digit's ink stops short of its advance; the superscript still
        // starts at the advance rather than being pulled back over the ink.
        let one = try layout("1")
        let glyphs = placedGlyphs(try layout("1^2"))
        try expectClose(glyphs[1].at.x, one.width, "superscript x")
    }

    // MARK: - Fractions

    test("math kills: a fraction keeps three rules of air above the bar in display, one inline") {
        for (display, rules) in [(true, 3.0), (false, 1.0)] {
            let box = try layout("\\frac{\\big(}{x}", display: display)
            guard let bar = ruleRects(box).first, let numerator = filledPathBounds(box).first else {
                try expect(false, "expected a bar and a stretched delimiter"); return
            }
            try expectClose(numerator.minY - bar.maxY, CGFloat(rules) * rule, tolerance: 0.05,
                            "numerator clearance, display \(display)")
        }
    }

    test("math kills: an unbarred stack keeps seven rules apart in display, three inline") {
        for (display, rules) in [(true, 7.0), (false, 3.0)] {
            let box = try layout("\\binom{\\big(}{\\big(}", display: display)
            // The binomial's own parentheses come first and last.
            let outlines = filledPathBounds(box)
            try expectEqual(outlines.count, 4)
            let (numerator, denominator) = (outlines[1], outlines[2])
            try expectClose(numerator.minY - denominator.maxY, CGFloat(rules) * rule, tolerance: 0.05,
                            "stack clearance, display \(display)")
        }
    }

    test("math kills: a fraction with nothing below the bar has no depth") {
        let box = try layout("\\frac{a}{}")
        try expectClose(box.descent, 0, "descent")
        let empty = try layout("\\frac{}{}")
        try expectClose(empty.ascent, axis + rule / 2, "the bar's top")
        try expectClose(empty.descent, 0, "empty descent")
    }

    test("math kills: an inkless numerator doesn't raise the fraction") {
        // `\quad` is pure space; the fraction's top is the bar's.
        try expectClose(try layout("\\frac{\\quad}{x}").ascent, axis + rule / 2, "ascent")
    }

    // MARK: - Radicals

    test("math kills: a radical's bar clears the body by the style's gap") {
        let x = try layout("x")
        let inline = try layout("\\sqrt{x}")
        try expectClose(inline.ascent, x.ascent + (rule + rule / 4) + rule, "inline surd top")
        let display = try layout("\\sqrt{x}", display: true)
        try expectClose(display.ascent, x.ascent + (rule + (try xHeight()) / 4) + rule, "display surd top")
    }

    test("math kills: a radical's index tucks a quarter of the surd into the crook") {
        let x = try layout("x")
        let plain = try layout("\\sqrt{x}")
        let surdWidth = plain.width - x.width
        let index = try layout("3", baseSize: scriptScriptSize)
        let kern = max(0, index.width - 0.25 * surdWidth)
        try expect(kern < index.width, "the overlap must matter")
        try expectClose(try layout("\\sqrt[3]{x}").width - plain.width, kern, "index kern")
    }

    // MARK: - Delimiters

    test("math kills: \\left…\\right covers the body's reach about the axis") {
        let body = try layout("\\frac{a}{b}")
        let reach = max(body.ascent - axis, body.descent + axis)
        let expected = max(reach / 0.901, reach - 0.35 * em) * 2
        let outlines = filledPathBounds(try layout("\\left(\\frac{a}{b}\\right)"))
        try expectEqual(outlines.count, 2)
        try expectClose(outlines[0].height, expected, tolerance: 0.5, "delimiter height")
    }

    test("math kills: a tall delimiter widens with its height up to 1.8×") {
        let paren = try layout("(")
        for (command, factor) in [("\\Big", 1.8), ("\\Bigg", 3.0)] {
            let scale = CGFloat(factor) * em / paren.height
            try expect(scale > 1, "\(command) must stretch the glyph")
            try expectClose(try layout("\(command)(").width, paren.width * min(scale, 1.8), "\(command)( width")
        }
    }

    // MARK: - Accents and rules

    test("math kills: an accent over a tall letter nestles onto its ascender") {
        let xh = try xHeight()
        let d = try layout("d"), x = try layout("x")
        let targetD = max(xh, d.ascent - 0.1 * em)
        let targetX = max(xh, x.ascent - 0.1 * em)
        try expect(targetD > xh, "d has to be taller than the x-height")
        let overD = placedGlyphs(try layout("\\hat{d}"))
        let overX = placedGlyphs(try layout("\\hat{x}"))
        try expectClose(overD[1].at.y - overX[1].at.y, targetD - targetX, "accent height")
    }

    test("math kills: an accent leans right by half an italic letter's slant") {
        let italicCorrection = try italicCorrectionOfV()
        let v = try layout("V")
        let alone = placedGlyphs(try layout("\\hat{}"))
        let overV = placedGlyphs(try layout("\\hat{V}"))
        try expectClose(overV[1].at.x - alone[0].at.x, v.width / 2 + italicCorrection / 2, "accent x")
    }

    test("math kills: an overline sits three rules above the body") {
        let x = try layout("x")
        let box = try layout("\\overline{x}")
        guard let bar = ruleRects(box).first else { try expect(false, "no overline"); return }
        try expectClose(bar.minY, x.ascent + 3 * rule, "overline y")
        try expectClose(box.ascent, x.ascent + 4 * rule, "ascent")
    }

    // MARK: - Matrices

    test("math kills: a display matrix sets its cells in text style") {
        let cell = try layout("\\begin{matrix}\\sum\\end{matrix}", display: true)
        try expectClose(cell.width, try layout("\\sum").width, "cell width")
    }

    test("math kills: cases columns sit a full em apart") {
        let two = try layout("\\begin{cases}a & b\\end{cases}")
        let one = try layout("\\begin{cases}ab\\end{cases}")
        try expectClose(two.width - one.width, em, "column gap")
    }

    test("math kills: aligned sets its first column flush right") {
        let box = try layout("\\begin{aligned}a &= b \\\\ aaa &= b\\end{aligned}")
        let first = placedGlyphs(box)[0]
        let wide = try layout("aaa").width, narrow = try layout("a").width
        try expectClose(first.at.x, wide - narrow, "first cell x")
    }

    test("math kills: an inner array rule sits midway between its columns") {
        let box = try layout("\\begin{array}{c|c}a&b\\end{array}")
        guard let line = ruleRects(box).first else { try expect(false, "no rule"); return }
        try expectClose(line.midX, (try layout("a")).width + 0.45 * em, "rule x")
    }

    test("math kills: matrix delimiters overshoot the pile by a fifth of an em") {
        let rows = "a\\\\b\\\\c\\\\d"
        let pile = try layout("\\begin{matrix}\(rows)\\end{matrix}")
        let reach = max(pile.ascent - axis, pile.descent + axis)
        let outlines = filledPathBounds(try layout("\\begin{pmatrix}\(rows)\\end{pmatrix}"))
        try expectEqual(outlines.count, 2)
        try expectClose(outlines[0].height, reach * 2 + 0.2 * em, tolerance: 0.5, "delimiter height")
    }

    // MARK: - Fonts

    test("math kills: \\mathit reaches the last capital Greek letter") {
        let omega = placedGlyphs(try layout("\\mathit{\\Omega}"))
        let psi = placedGlyphs(try layout("\\mathit{\\Psi}"))
        let upright = placedGlyphs(try layout("\\Omega"))
        try expectEqual(omega.first?.font, psi.first?.font)
        try expect(omega.first?.glyph != upright.first?.glyph, "an italic Omega is a different glyph")
    }

    test("math kills: an inkless run still stands an x-height tall") {
        let body = CTFontCreateWithName("Helvetica" as CFString, em, nil)
        try expectClose(try layout("\\text{ }").ascent, CTFontGetXHeight(body), "\\text{ } ascent")
        try expect(try xHeight() > 0)
    }
}
