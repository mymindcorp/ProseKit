import Foundation
import DocumentModel
import CoreText
import EditorMath
import EditorSerialization
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for the parsers on markup we did not write.
//
// The serialization sweep round-trips our own output, which is well-formed by
// construction. What arrives on the clipboard is not: another app's HTML with
// tags closed in the wrong order or never, Markdown with a fence that never
// ends, RTF with a control word the writer invented. Each parser is allowed to
// refuse such input with an error. What none of them may do is trap, or return
// a document the schema rejects — the paste path applies the result without
// looking, so an invalid document here is an invalid note.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerForeignMarkupFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("foreign markup fuzz: HTML tag soup and mutated HTML parse into valid documents or errors") {
        let schema = try fuzzSchema()
        var rng = SelRNG(103)
        for i in 0 ..< 300 {
            try checkParse("HTML soup \(i)", randomHTML(&rng)) { try HTMLParser.parse($0, schema: schema) }
        }
        for (seed, doc) in fuzzCorpus(schema, count: 25) {
            let html = HTMLSerializer.serialize(doc)
            for (what, mutated) in mutations(of: html, &rng) {
                try checkParse("HTML from \(seed), \(what)", mutated) { try HTMLParser.parse($0, schema: schema) }
            }
        }
    }

    test("foreign markup fuzz: Markdown line soup and mutated Markdown parse into valid documents or errors") {
        let schema = try fuzzSchema()
        var rng = SelRNG(107)
        for i in 0 ..< 300 {
            try checkParse("Markdown soup \(i)", randomMarkdown(&rng)) { try MarkdownParser.parse($0, schema: schema) }
        }
        for (seed, doc) in fuzzCorpus(schema, count: 25) {
            let markdown = MarkdownSerializer.serialize(doc)
            for (what, mutated) in mutations(of: markdown, &rng) {
                try checkParse("Markdown from \(seed), \(what)", mutated) { try MarkdownParser.parse($0, schema: schema) }
            }
        }
    }

    test("foreign markup fuzz: MathML soup converts to LaTeX the typesetter can take") {
        // `<math>` from a browser, a Word export or MathJax: the converter
        // turns it into LaTeX and the typesetter lays that out. Neither may
        // trap, whatever the nesting, and whatever the converter produces has
        // to be something the parser either reads or rejects — a converter
        // that emits an unbalanced brace turns every pasted formula into an
        // error box.
        let schema = try fuzzSchema()
        var rng = SelRNG(111)
        let typesetter = MathTypesetter(baseSize: 17, bodyFont: CTFontCreateWithName("Helvetica" as CFString, 17, nil))
        // Well-formed MathML first: what the converter makes of it has to
        // *parse*, or every formula pasted from a browser is an error box.
        let wellFormed = [
            "<math><mi>x</mi><mo>+</mo><mn>2</mn></math>",
            "<math><mfrac><mi>a</mi><mi>b</mi></mfrac></math>",
            "<math><msup><mi>x</mi><mn>2</mn></msup><msub><mi>y</mi><mi>i</mi></msub></math>",
            "<math><msqrt><mi>x</mi></msqrt><mroot><mi>x</mi><mn>3</mn></mroot></math>",
            "<math><mrow><mo>(</mo><mi>a</mi><mo>)</mo></mrow></math>",
            "<math><munderover><mo>∑</mo><mi>i</mi><mi>n</mi></munderover><mi>x</mi></math>",
            "<math><mtable><mtr><mtd><mn>1</mn></mtd><mtd><mn>2</mn></mtd></mtr></mtable></math>",
            "<math><mover><mi>x</mi><mo>^</mo></mover><mtext>and</mtext></math>",
        ]
        for (i, mathml) in wellFormed.enumerated() {
            let doc = try HTMLParser.parse("<p>\(mathml)</p>", schema: schema)
            var latexes: [String] = []
            doc.descendants { node, _, _, _ in if let l = node.attrs["latex"]?.stringValue { latexes.append(l) }; return true }
            try expect(!latexes.isEmpty, "well-formed MathML \(i) produced no formula: \(mathml)")
            for latex in latexes {
                let result = typesetter.layout(latex, display: false)
                try expect(!result.isError, "the converter's LaTeX for well-formed MathML \(i) doesn't parse: \(latex.debugDescription) — \(result.error ?? "")")
            }
        }
        for i in 0 ..< 300 {
            let html = "<p>a " + randomMathML(&rng) + " b</p>"
            let doc: Node
            do { doc = try HTMLParser.parse(html, schema: schema) } catch { continue }
            var invalid: (any Error)?
            do { try doc.check() } catch { invalid = error }
            try expect(invalid == nil, "MathML soup \(i) parsed into an invalid document: \(invalid.map { "\($0)" } ?? "")\n  \(html.debugDescription)")
            doc.descendants { node, _, _, _ in
                guard let latex = node.attrs["latex"]?.stringValue else { return true }
                let result = typesetter.layout(latex, display: node.type.name == "blockMath")
                let box = result.box
                if !(box.width.isFinite && box.ascent.isFinite && box.descent.isFinite) {
                    invalid = ModelError.invalidContent("non-finite box for \(latex.debugDescription) from MathML soup \(i)")
                }
                return true
            }
            try expect(invalid == nil, "\(invalid.map { "\($0)" } ?? "")\n  \(html.debugDescription)")
        }
    }

    test("foreign markup fuzz: RTF control-word soup parses into valid documents or errors") {
        let schema = try fuzzSchema()
        var rng = SelRNG(109)
        for i in 0 ..< 300 {
            try checkParse("RTF soup \(i)", randomRTF(&rng)) { try RTFParser.parse($0, schema: schema) }
        }
    }
}

// MARK: - The check

private func checkParse(_ ctx: @autoclosure () -> String, _ source: String,
                        _ parse: (String) throws -> Node) throws {
    let doc: Node
    do {
        doc = try parse(source)
    } catch {
        return // refusing is allowed; trapping is not, and that already didn't happen
    }
    var invalid: (any Error)?
    do { try doc.check() } catch { invalid = error }
    try expect(invalid == nil,
               "the parser returned an invalid document — \(ctx()): \(invalid.map { "\($0)" } ?? "")\n  \(source.prefix(300).debugDescription)\n\(fuzzOutline(doc))")
    for pos in 0 ... doc.content.size { _ = doc.resolve(pos) }
    // The model now refuses an empty text node, so a parser that builds one
    // hands the editor something the next `check` throws on.
    var emptyTextAt: Int?
    doc.descendants { node, pos, _, _ in
        if node.isText, (node.text ?? "").isEmpty { emptyTextAt = pos }
        return true
    }
    try expect(emptyTextAt == nil, "an empty text node at \(emptyTextAt ?? -1) — \(ctx())\n  \(source.prefix(300).debugDescription)")
}

// MARK: - Sources

/// Delete, duplicate, truncate, or scramble a piece of a real serialization —
/// the shapes a hand-edited or half-copied document arrives in.
private func mutations(of source: String, _ rng: inout SelRNG) -> [(String, String)] {
    let chars = Array(source)
    guard chars.count > 2 else { return [] }
    var out: [(String, String)] = []
    for _ in 0 ..< 4 {
        let i = Int.random(in: 0 ..< chars.count, using: &rng)
        var m = chars; m.remove(at: i); out.append(("without char \(i)", String(m)))
    }
    for _ in 0 ..< 2 {
        let i = Int.random(in: 0 ..< chars.count, using: &rng)
        let j = Int.random(in: i ..< chars.count, using: &rng)
        var m = chars; m.insert(contentsOf: chars[i ... j], at: j); out.append(("with \(i)...\(j) doubled", String(m)))
    }
    out.append(("truncated", String(chars[..<(chars.count / 2)])))
    let a = Int.random(in: 0 ..< chars.count, using: &rng), b = Int.random(in: 0 ..< chars.count, using: &rng)
    var s = chars; s.swapAt(a, b); out.append(("chars \(a) and \(b) swapped", String(s)))
    return out
}

private let htmlTags = ["p", "div", "span", "ul", "ol", "li", "table", "tr", "td", "th", "thead", "tbody",
                        "h1", "h2", "h6", "blockquote", "pre", "code", "strong", "em", "a", "img", "br", "hr",
                        "details", "summary", "figure", "figcaption", "input", "math", "script", "style",
                        "sup", "sub", "u", "s", "mark", "font", "b", "i", "ruby", "template", "html", "body"]
private let htmlAttrs = ["", " href=\"https://x\"", " src=\"i.png\"", " data-type=\"taskList\"", " data-type=\"taskItem\"",
                         " data-checked=\"true\"", " type=\"checkbox\"", " colspan=\"2\"", " rowspan=\"0\"",
                         " colspan=\"-1\"", " data-type=\"footnoteDefinition\" data-label=\"\"", " data-latex=\"\\frac{\"",
                         " style=\"color:red\"", " class=\"language-swift\"", " data-type=\"block-math\"",
                         " colwidth=\"1,2\"", " open", " href=\"javascript:alert(1)\""]
private let htmlText = ["a", " ", "&amp;", "&", "<", "🙂", "漢", "\n", "&#x1F642;", "&nosuch;", "\u{0301}", "b c"]

private func randomHTML(_ rng: inout SelRNG) -> String {
    var out = ""
    let n = Int.random(in: 1 ... 30, using: &rng)
    var open: [String] = []
    for _ in 0 ..< n {
        switch Int.random(in: 0 ..< 5, using: &rng) {
        case 0, 1:
            let tag = htmlTags.randomElement(using: &rng)!
            out += "<\(tag)\(htmlAttrs.randomElement(using: &rng)!)>"
            open.append(tag)
        case 2:
            // Close something — the right one, the wrong one, or nothing open.
            let tag = Bool.random(using: &rng) ? (open.popLast() ?? "p") : htmlTags.randomElement(using: &rng)!
            out += "</\(tag)>"
        case 3:
            out += "<\(htmlTags.randomElement(using: &rng)!)/>"
        default:
            out += htmlText.randomElement(using: &rng)!
        }
    }
    return out
}

private let mathmlTags = ["mi", "mo", "mn", "mrow", "mfrac", "msup", "msub", "msubsup", "msqrt", "mroot", "mtable", "mtr", "mtd",
                          "mover", "munder", "munderover", "mtext", "mspace", "mfenced", "mstyle", "semantics", "annotation",
                          "mpadded", "mphantom", "menclose", "mmultiscripts", "none", "mprescripts", "mglyph", "maligngroup"]
private let mathmlText = ["x", "2", "+", "=", "(", ")", "∑", "∫", "α", "&alpha;", "&#x3B1;", "&InvisibleTimes;", " ", "\\frac", "{", "}", "^", "_", "🙂"]

private func randomMathML(_ rng: inout SelRNG) -> String {
    var out = "<math" + ["", " display=\"block\"", " xmlns=\"http://www.w3.org/1998/Math/MathML\""].randomElement(using: &rng)! + ">"
    var open: [String] = []
    for _ in 0 ..< Int.random(in: 1 ... 24, using: &rng) {
        switch Int.random(in: 0 ..< 4, using: &rng) {
        case 0, 1:
            let tag = mathmlTags.randomElement(using: &rng)!
            out += "<\(tag)" + ["", " mathvariant=\"bold\"", " stretchy=\"false\"", " encoding=\"application/x-tex\"", " linethickness=\"0\""].randomElement(using: &rng)! + ">"
            open.append(tag)
        case 2:
            out += "</\(Bool.random(using: &rng) ? (open.popLast() ?? "mi") : mathmlTags.randomElement(using: &rng)!)>"
        default:
            out += mathmlText.randomElement(using: &rng)!
        }
    }
    if Bool.random(using: &rng) { for tag in open.reversed() { out += "</\(tag)>" } }
    return out + (Bool.random(using: &rng) ? "</math>" : "")
}

private let markdownPieces = ["# ", "## ", "- ", "* ", "1. ", "> ", "```", "```swift", "---", "***", "| a | b |", "|---|---|",
                              "[^1]: ", "[^1]", "[[Page]]", "![](i.png)", "[a](b)", "**", "__", "~~", "==", "`", "$", "$$",
                              "\\", "<details>", "<summary>", "</details>", "<br>", "^^^", "    ", "\t", "\n", "\n\n",
                              "a", "b c", "🙂", "漢", "\u{200B}", "- [ ] ", "- [x] ", "1)", "+ ", "&amp;", "<b>", "</b>", "\\n"]

private func randomMarkdown(_ rng: inout SelRNG) -> String {
    let n = Int.random(in: 1 ... 40, using: &rng)
    return (0 ..< n).map { _ in markdownPieces.randomElement(using: &rng)! }.joined()
}

private let rtfWords = ["\\rtf1", "\\ansi", "\\ansicpg1252", "\\deff0", "{\\fonttbl{\\f0\\fswiss Helvetica;}}", "{\\colortbl;\\red255\\green0\\blue0;}",
                        "\\pard", "\\par", "\\b", "\\b0", "\\i", "\\i0", "\\ul", "\\ulnone", "\\fs24", "\\fs-1", "\\f0", "\\f9", "\\cf1", "\\cf99",
                        "\\'e9", "\\'", "\\u9786?", "\\u-1?", "\\uc0", "\\uc2", "\\line", "\\tab", "\\trowd", "\\cell", "\\row", "\\intbl",
                        "{\\*\\listtable}", "\\ls1", "\\ilvl0", "{\\pntext\\'95\\tab}", "\\'93", "\\ansicpg932", "\\mac", "\\bin5 abcde",
                        "{", "}", "}}", "{{", "\\", "a", "b c", " ", "\n", "🙂", "漢", "{\\*\\nosuch 1}", "\\nosuchword", "\\'zz", "\\-", "\\~", "\\_"]

private func randomRTF(_ rng: inout SelRNG) -> String {
    var out = Bool.random(using: &rng) ? "{\\rtf1\\ansi" : "{"
    let n = Int.random(in: 1 ... 40, using: &rng)
    for _ in 0 ..< n { out += rtfWords.randomElement(using: &rng)! }
    if Bool.random(using: &rng) { out += "}" }
    return out
}
