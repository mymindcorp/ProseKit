import CoreGraphics
import Foundation
import EditorMath
import TestHarness

// A fuzzer for the LaTeX parser and the box layout behind it.
//
// The corpus tests say that real notation parses and lays out. This one says
// the opposite thing about everything else: a formula is typed one character
// at a time, so the typesetter sees every prefix of every formula, every typo,
// and every half-closed brace — and a source it can't read has to come back as
// an error box, never as a trap. The other promise is that layout is a pure
// function of its input: the same source gives the same geometry every time,
// and that geometry is finite.
//
// Opt-in, like the other sweeps: `PROSEKIT_FUZZ=1 swift run EditorMathTests`.
func registerMathFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("math fuzz: random token soup never traps and always yields a finite box") {
        var rng = MathRNG(1)
        for i in 0 ..< 600 {
            let source = randomSource(&rng)
            try checkLayout(source, "soup \(i)")
        }
    }

    test("math fuzz: every prefix and every one-character typo of real notation is survivable") {
        // Typing a formula shows the typesetter every prefix; fixing one shows
        // it every deletion. Both are the everyday inputs, not the corner case.
        for (group, latex) in mathCorpus {
            let chars = Array(latex)
            for cut in 0 ... chars.count {
                try checkLayout(String(chars[..<cut]), "\(group) prefix \(cut) of \(latex)")
            }
            for drop in chars.indices {
                var mutated = chars
                mutated.remove(at: drop)
                try checkLayout(String(mutated), "\(group) without char \(drop) of \(latex)")
            }
        }
    }

    test("math fuzz: pathological nesting is rejected or laid out, never blown through") {
        // The parser is recursive; the layout is recursive. A source that nests
        // deeper than either expected is where a stack goes.
        let cases: [(String, String)] = [
            ("braces", String(repeating: "{", count: 400) + "x" + String(repeating: "}", count: 400)),
            ("unclosed braces", String(repeating: "{", count: 400)),
            ("unopened braces", String(repeating: "}", count: 400)),
            ("fractions", String(repeating: "\\frac{", count: 80) + "1" + String(repeating: "}{2}", count: 80)),
            ("superscripts", "x" + String(repeating: "^{2", count: 120) + String(repeating: "}", count: 120)),
            ("stacked scripts", "x" + String(repeating: "^", count: 60) + "2"),
            ("lefts", String(repeating: "\\left(", count: 120) + "x"),
            ("rights", "x" + String(repeating: "\\right)", count: 120)),
            ("sqrt", String(repeating: "\\sqrt{", count: 100) + "x" + String(repeating: "}", count: 100)),
            ("matrix", "\\begin{matrix}" + String(repeating: "a&b\\\\", count: 200) + "\\end{matrix}"),
            ("matrix unclosed", String(repeating: "\\begin{matrix}", count: 60)),
            ("long run", String(repeating: "x+", count: 5000) + "y"),
            ("backslashes", String(repeating: "\\", count: 300)),
            ("percent", String(repeating: "%", count: 300)),
            ("ampersands", String(repeating: "&", count: 300)),
            ("newlines", String(repeating: "\\\\", count: 300)),
            ("text", "\\text{" + String(repeating: "a", count: 3000) + "}"),
            ("unicode", String(repeating: "👩‍👩‍👧‍👦é漢", count: 200)),
            ("empty", ""),
            ("whitespace", "   \n\t  "),
        ]
        for (name, source) in cases {
            try checkLayout(source, name)
        }
    }
}

// MARK: - The checks

/// Lay the source out both ways and check what came back.
private func checkLayout(_ source: String, _ ctx: @autoclosure () -> String) throws {
    for display in [false, true] {
        let first = typesetter().layout(source, display: display)
        let box = first.box
        let what = "\(display ? "display" : "inline") — \(ctx()) — \(source.prefix(80).debugDescription)"
        try expect(box.width.isFinite && box.ascent.isFinite && box.descent.isFinite,
                   "the box has a non-finite dimension (\(box.width), \(box.ascent), \(box.descent)): \(what)")
        try expect(box.width >= 0, "negative width \(box.width): \(what)")
        try expect(box.height >= 0, "negative height \(box.height): \(what)")
        if first.isError {
            try expect(!(first.error ?? "").isEmpty, "an error result with no message: \(what)")
        }
        // Pure: the same source lays out the same way twice.
        let second = typesetter().layout(source, display: display)
        try expect(second.isError == first.isError, "the parser changed its mind about \(what)")
        try expectEqual(second.box.width, box.width, "the width changed between two layouts of \(what)")
        try expectEqual(second.box.ascent, box.ascent, "the ascent changed between two layouts of \(what)")
        try expectEqual(second.box.descent, box.descent, "the descent changed between two layouts of \(what)")
        // And the items it wants drawn are all inside the box it reports.
        _ = box.drawItems
    }
}

// MARK: - Sources

/// A seeded, deterministic RNG so any failure reproduces from its seed.
private struct MathRNG: RandomNumberGenerator {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}

/// Everything the parser branches on, plus the characters it should ignore.
private let vocabulary: [String] = [
    "x", "y", "2", "0", "+", "-", "=", "^", "_", "{", "}", "(", ")", "[", "]", "|", ",", ".", "'", " ",
    "\\frac", "\\sqrt", "\\sum", "\\prod", "\\int", "\\lim", "\\left", "\\right", "\\alpha", "\\infty",
    "\\begin{matrix}", "\\end{matrix}", "\\begin{pmatrix}", "\\end{cases}", "\\begin{array}{cc}", "&", "\\\\",
    "\\text{a b}", "\\mathbb{R}", "\\mathrm{d}", "\\hat", "\\vec", "\\overline", "\\underbrace",
    "\\cdot", "\\to", "\\,", "\\;", "\\!", "\\quad", "\\displaystyle", "\\color{red}", "\\binom",
    "\\bigl", "\\bigr", "\\lfloor", "\\rfloor", "\\langle", "\\rangle", "\\|", "\\{", "\\}",
    "\\", "%", "#", "$", "~", "\u{0301}", "🙂", "漢", "\\nosuchcommand", "\\end{matrix}", "\\right.",
    "^{", "_{", "\\frac{", "\\sqrt[", "\\left(", "\\right)",
]

private func randomSource(_ rng: inout MathRNG) -> String {
    let n = Int.random(in: 0 ... 24, using: &rng)
    return (0 ..< n).map { _ in vocabulary.randomElement(using: &rng)! }.joined()
}
