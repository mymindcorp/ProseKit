import Foundation
import CoreText
import DocumentModel
import EditorSerialization
import EditorMath
import SchemaKit
import TestHarness

// Pasting MathML.
//
// The samples are the shapes the real sources emit, not invented markup:
// Wikipedia's `alttext`, MathJax's and KaTeX's `<annotation>`, and bare
// presentation MathML of the kind a word processor produces.

private func mathEditor() throws -> Editor { try Editor(extensions: fullKit()) }

/// The first math node's LaTeX and whether it's the block form.
private func math(_ doc: Node) -> (latex: String, block: Bool)? {
    var found: (String, Bool)?
    doc.descendants { node, _, _, _ in
        if found == nil, node.type.name == "inlineMath" || node.type.name == "blockMath" {
            found = (node.attrs["latex"]?.stringValue ?? "", node.type.name == "blockMath")
        }
        return found == nil
    }
    return found
}

/// Parse HTML and read the formula out of it.
private func pasted(_ html: String) throws -> (latex: String, block: Bool)? {
    let editor = try mathEditor()
    let doc = try HTMLParser.parse(html, schema: editor.schema)
    try doc.check()
    return math(doc)
}

func registerMathMLPasteTests() {
    test("mathml: MathJax/KaTeX output uses its TeX annotation verbatim") {
        // The annotation is the original source, so nothing is approximated.
        let html = """
        <math><semantics><mrow><msup><mi>x</mi><mn>2</mn></msup></mrow>\
        <annotation encoding="application/x-tex">x^2 + 1</annotation></semantics></math>
        """
        try expectEqual(try pasted(html)?.latex, "x^2 + 1")
    }

    test("mathml: Wikipedia's alttext is used, without its display wrapper") {
        let html = """
        <math alttext="{\\displaystyle x^{2}+1}"><semantics><mrow><msup><mi>x</mi><mn>2</mn></msup>\
        </mrow></semantics></math>
        """
        try expectEqual(try pasted(html)?.latex, "x^{2}+1")
    }

    test("mathml: the display attribute picks the block node") {
        let inline = try pasted("<math><mi>x</mi></math>")
        try expectEqual(inline?.block, false)
        let block = try pasted("<math display=\"block\"><mi>x</mi></math>")
        try expectEqual(block?.block, true)
        try expectEqual(try pasted("<math mode=\"display\"><mi>x</mi></math>")?.block, true)
    }

    test("mathml: presentation markup with no annotation is converted") {
        let cases: [(String, String)] = [
            ("<math><mi>x</mi><mo>+</mo><mn>1</mn></math>", "x+1"),
            ("<math><mfrac><mi>a</mi><mi>b</mi></mfrac></math>", "\\frac{a}{b}"),
            ("<math><msqrt><mn>2</mn></msqrt></math>", "\\sqrt{2}"),
            ("<math><mroot><mi>x</mi><mn>3</mn></mroot></math>", "\\sqrt[3]{x}"),
            ("<math><msup><mi>x</mi><mn>2</mn></msup></math>", "x^{2}"),
            ("<math><msub><mi>a</mi><mi>i</mi></msub></math>", "a_{i}"),
            ("<math><msubsup><mo>&#x2211;</mo><mi>i</mi><mi>n</mi></msubsup></math>", "\\sum_{i}^{n}"),
            ("<math><mi>&#x03B1;</mi><mo>&#x2264;</mo><mi>&#x03B2;</mi></math>", "\\alpha\\leq\\beta"),
            ("<math><mi>sin</mi><mi>x</mi></math>", "\\sin x"),
            ("<math><mtext>if</mtext></math>", "\\text{if}"),
        ]
        for (html, expected) in cases {
            try expectEqual(try pasted(html)?.latex, expected, html)
        }
    }

    test("mathml: converted markup produces LaTeX the renderer can parse") {
        // The property that matters — output the math parser rejects would
        // render as an error instead of a formula.
        let samples = [
            "<math><mi>x</mi><mo>+</mo><mn>1</mn></math>",
            "<math><mfrac><mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow><mn>2</mn></mfrac></math>",
            "<math><msqrt><mrow><msup><mi>x</mi><mn>2</mn></msup><mo>+</mo><mn>1</mn></mrow></msqrt></math>",
            "<math><munderover><mo>&#x2211;</mo><mrow><mi>i</mi><mo>=</mo><mn>1</mn></mrow><mi>n</mi></munderover><mi>i</mi></math>",
            "<math><mfenced open=\"[\" close=\"]\"><mi>x</mi></mfenced></math>",
            "<math><mtable><mtr><mtd><mn>1</mn></mtd><mtd><mn>2</mn></mtd></mtr></mtable></math>",
            "<math><mover><mi>v</mi><mo>&#x2192;</mo></mover></math>",
            "<math><mi>&#x222B;</mi><mi>f</mi></math>",
        ]
        let typesetter = MathTypesetter(baseSize: 17, bodyFont: bodyFontForTests())
        for html in samples {
            let latex = try expectSome(try pasted(html)?.latex, html)
            let result = typesetter.layout(latex, display: false)
            try expect(!result.isError, "\(html)\n  produced \(latex.debugDescription)\n  → \(result.error ?? "")")
        }
    }

    test("mathml: invisible operators leave no trace") {
        // MathML marks implied multiplication and function application with
        // invisible characters; rendering them would be nonsense.
        try expectEqual(try pasted("<math><mn>2</mn><mo>&#x2062;</mo><mi>x</mi></math>")?.latex, "2x")
        try expectEqual(try pasted("<math><mi>f</mi><mo>&#x2061;</mo><mi>x</mi></math>")?.latex, "fx")
    }

    test("mathml: the visual half of a KaTeX paste doesn't duplicate the formula") {
        // KaTeX emits the formula twice — MathML plus aria-hidden glyphs. Both
        // would land as one formula and a wall of duplicated text.
        let html = """
        <span class="katex"><span class="katex-mathml"><math><semantics>\
        <annotation encoding="application/x-tex">a+b</annotation></semantics></math></span>\
        <span class="katex-html" aria-hidden="true"><span class="mord">a</span>\
        <span class="mbin">+</span><span class="mord">b</span></span></span>
        """
        let editor = try mathEditor()
        let doc = try HTMLParser.parse(html, schema: editor.schema)
        try doc.check()
        try expectEqual(math(doc)?.latex, "a+b")
        try expectEqual(doc.textContent, "$a+b$", "only the formula's own text, not the glyph copy")
    }

    test("mathml: an empty or unreadable formula is dropped, not scraped") {
        for html in ["<math></math>", "<math><mrow></mrow></math>"] {
            let editor = try mathEditor()
            let doc = try HTMLParser.parse(html, schema: editor.schema)
            try doc.check()
            try expectNil(math(doc))
        }
    }

    test("mathml: a formula pasted mid-sentence stays inline") {
        let editor = try mathEditor()
        let doc = try HTMLParser.parse(
            "<p>when <math><semantics><annotation encoding=\"application/x-tex\">x&gt;0</annotation>"
            + "</semantics></math> holds</p>", schema: editor.schema)
        try doc.check()
        try expectEqual(math(doc)?.block, false)
        try expectEqual(doc.child(0).childCount, 3, "text, formula, text")
        try expectEqual(doc.textContent, "when $x>0$ holds")
    }

    test("mathml: a pasted formula round-trips as our own markup") {
        // Once imported it's an ordinary math node, so it serializes as
        // `data-latex` like any other — Tiptap's shape.
        let editor = try mathEditor()
        let doc = try HTMLParser.parse(
            "<math display=\"block\"><semantics><annotation encoding=\"application/x-tex\">"
            + "\\frac{a}{b}</annotation></semantics></math>", schema: editor.schema)
        editor.setContent(doc)
        let html = editor.getHTML()
        try expect(html.contains("data-latex=\"\\frac{a}{b}\""), html)
        try expectEqual(try HTMLParser.parse(html, schema: editor.schema), doc)
    }

    test("mathml: a schema without math nodes keeps the text rather than crashing") {
        let plain = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "inline*", group: "block")),
            ("text", NodeSpec(group: "inline")),
        ], marks: [], topNode: "doc")
        let doc = try HTMLParser.parse("<p>a <math><mi>x</mi></math> b</p>", schema: plain)
        try doc.check()
    }
}

/// A body font for the typesetter, matching what the renderer would pass.
private func bodyFontForTests() -> CTFont {
    CTFontCreateWithName("Helvetica" as CFString, 17, nil)
}

/// `expectNotNil` returns nothing; this unwraps through the harness's own check.
private func expectSome<T>(_ value: T?, _ message: @autoclosure () -> String = "",
                           file: StaticString = #file, line: UInt = #line) throws -> T {
    try expect(value != nil, "expected a value — \(message())", file: file, line: line)
    return value!
}
