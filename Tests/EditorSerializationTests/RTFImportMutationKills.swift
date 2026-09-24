import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// Tests that kill mutants of `RTF.swift` and `MathML.swift` the rest of the
// suite let through. Each pins one decision the reader makes — a boundary, a
// reset, a fallback — with the exact document or LaTeX it should produce, so
// flipping that decision changes the answer. The mutant each one was written
// against is named in its comment.

private let killHeader = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Courier New;}}"#
private func killRTF(_ body: String) -> String { killHeader + body + "}" }
private func parseKill(_ body: String, config: RTFConfig = .default) throws -> Node {
    try RTFParser.parse(killRTF(body), schema: schema, config: config)
}
private func killMark(_ name: String, _ attrs: Attrs = [:]) -> Mark { schema.mark(name, attrs) }
private func killText(_ text: String, _ marks: Mark...) -> Node { schema.text(text, marks) }
private func item(_ c: Node...) -> Node { node("listItem", [:], c) }

/// A one-level list definition and the override that maps `\ls1` to it.
private func killList(nfc: Int, startAt: Int? = nil, levels: Int = 1, id: Int = 1) -> String {
    var level = #"{\listlevel\levelnfc\#(nfc)\levelnfcn\#(nfc)\leveljc0\levelfollow0"#
    if let startAt { level += #"\levelstartat\#(startAt)"# }
    level += #"{\leveltext\'01x;}{\levelnumbers;}}"#
    return #"{\*\listtable{\list\listtemplateid\#(id)"# + String(repeating: level, count: levels) + #"\listid\#(id)}}"#
}

/// The formulas an HTML paste produced, as (LaTeX, is it a block).
private func killMath(_ html: String) throws -> [(String, Bool)] {
    let d = try HTMLParser.parse(html, schema: schema)
    try d.check()
    var out: [(String, Bool)] = []
    d.descendants { n, _, _, _ in
        if n.type.name == "inlineMath" || n.type.name == "blockMath" {
            out.append((n.attrs["latex"]?.stringValue ?? "", n.type.name == "blockMath"))
        }
        return true
    }
    return out
}
private func latexOf(_ mathml: String) throws -> String? {
    try killMath("<p>" + mathml + "</p>").first?.0
}

/// A table whose cells hold exactly one paragraph, with the span and width
/// attributes a cell needs to say it was merged.
private let singleParagraphCells: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("paragraph", NodeSpec(content: "inline*", group: "block")),
    ("table", NodeSpec(content: "tableRow+", group: "block")),
    ("tableRow", NodeSpec(content: "tableCell+")),
    ("tableCell", NodeSpec(content: "paragraph", attrs: cellAttrs)),
    ("text", NodeSpec(group: "inline")),
])

private func rowTexts(_ table: Node) -> [[String]] {
    (0 ..< table.childCount).map { r in (0 ..< table.child(r).childCount).map { table.child(r).child($0).textContent } }
}

func registerRTFImportMutationKillTests() {
    // MARK: Groups and control words

    test("RTF mut: the group limit counts the deepest group, inclusive") {
        // R01 (`>` → `>=`): the root group plus three nested ones is depth 4,
        // which a limit of 4 allows and a limit of 3 refuses.
        let source = killRTF(#"\pard {{{x}}}\par"#)
        let d = try RTFParser.parse(source, schema: schema, config: RTFConfig(maxGroupDepth: 4))
        try expectEqual(d, doc(p("x")))
        do {
            _ = try RTFParser.parse(source, schema: schema, config: RTFConfig(maxGroupDepth: 3))
            try expect(false, "a limit of 3 should refuse depth 4")
        } catch let error as RTFParseError {
            try expectEqual(error, .nestingTooDeep(depth: 4, limit: 3))
        }
    }

    test("RTF mut: a line break between the opening brace and \\rtf is allowed") {
        // R03: a producer that wraps its output after the first brace still
        // wrote an RTF header.
        let d = try RTFParser.parse("{\r\n\\rtf1\\ansi \\pard hi\\par}", schema: schema)
        try expectEqual(d, doc(p("hi")))
    }

    test("RTF mut: a toggle whose parameter is a bare minus sign turns it off") {
        // R04: `\b-` has a sign and no digits, which reads as 0 — off — not as
        // a parameterless `\b`.
        let d = try parseKill(#"\pard a\b- b\par"#)
        try expectEqual(d, doc(p("ab")))
    }

    test("RTF mut: a hex escape with one digit is dropped, not read as a byte") {
        // R05: `\'e` followed by a non-hex character is incomplete.
        let d = try parseKill(#"\pard x\'e y\par"#)
        try expectEqual(d, doc(p("x y")))
    }

    test("RTF mut: an escaped brace can be the fallback a \\u swallows") {
        // R06: with `\uc1`, the character after `\u8364` is its fallback, even
        // when that character is written `\}`.
        let d = try parseKill(#"\pard\uc1 a\u8364\}b\par"#)
        try expectEqual(d, doc(p("a\u{20AC}b")))
    }

    test("RTF mut: a raw 0x80 byte is code-page text, the euro sign") {
        // R07: the lowest byte above ASCII goes through the code page too.
        var data = Data(killHeader.utf8)
        data.append(contentsOf: Array(#"\pard a"#.utf8) + [0x80] + Array(#"b\par}"#.utf8))
        let d = try RTFParser.parse(data, schema: schema)
        try expectEqual(d, doc(p("a\u{20AC}b")))
    }

    test("RTF mut: \\uc with no parameter means one fallback character") {
        // R15.
        let d = try parseKill(#"\pard\uc\u8364?x\par"#)
        try expectEqual(d, doc(p("\u{20AC}x")))
    }

    test("RTF mut: each \\u starts its own fallback count rather than adding to one") {
        // R16: two `\u`s back to back, then one fallback: the second `\u`
        // replaces the first's count, so only the `?` is swallowed.
        let d = try parseKill(#"\pard\uc1 \u8364\u8364?x\par"#)
        try expectEqual(d, doc(p("\u{20AC}\u{20AC}x")))
    }

    test("RTF mut: a high surrogate interrupted by another character is forgotten") {
        // R17: the low half that turns up after an ordinary `\u` has nothing to
        // pair with.
        let d = try parseKill(#"\pard\uc1 \u55357?\u65?\u56832?.\par"#)
        try expectEqual(d, doc(p("A.")))
    }

    test("RTF mut: a Symbol-font byte reads as cp1252 whatever the document code page") {
        // R18: `\'b7` in the Symbol charset is Word's bullet; in a MacRoman
        // document the code page would make it `∑`.
        let d = try RTFParser.parse(
            #"{\rtf1\mac\ansicpg10000{\fonttbl{\f0 Helvetica;}{\f3\fnil\fcharset2 Symbol;}}\pard\f3\'b7\f0 x\par}"#,
            schema: schema)
        try expectEqual(d, doc(p("\u{00B7}x")))
    }

    test("RTF mut: \\tab can be the fallback a \\u swallows") {
        // R19.
        let d = try parseKill(#"\pard\uc1 \u8364\tab x\par"#)
        try expectEqual(d, doc(p("\u{20AC}x")))
    }

    // MARK: Character state

    test("RTF mut: \\plain inside a hyperlink's result keeps the link") {
        // R09: the link belongs to the field, not to the character formatting
        // `\plain` resets.
        let d = try parseKill(#"\pard {\field{\*\fldinst HYPERLINK "https://e.test/"}{\fldrslt \b bold \plain plain}}\par"#)
        let link = killMark("link", ["href": .string("https://e.test/")])
        try expectEqual(d, doc(p(killText("bold ", killMark("bold"), link), killText("plain", link))))
    }

    test("RTF mut: \\super turns subscript off") {
        // R10.
        let d = try parseKill(#"\pard {\sub a\super b}\par"#)
        try expectEqual(d, doc(p(killText("a", killMark("subscript")), killText("b", killMark("superscript")))))
    }

    test("RTF mut: an empty colour-table entry is auto, not the entry before it") {
        // R14: `;;` after a red entry defines entry 2 with no components.
        let d = try parseKill(#"{\colortbl;\red255\green0\blue0;;}\pard\cf2 x\cf1 y\par"#)
        try expectEqual(d, doc(p(killText("x"), killText("y", killMark("textColor", ["color": .string("#ff0000")])))))
    }

    test("RTF mut: \\li and \\lin both state the indent, and the larger wins") {
        // R13: the second item is a level deeper whichever order the two
        // indent words come in.
        let d = try parseKill(#"\pard\li720 {\listtext \'95\tab}one\par\pard\li1440\lin720 {\listtext \'95\tab}two\par"#)
        try expectEqual(d, doc(node("bulletList", [:], [
            item(p("one"), node("bulletList", [:], [item(p("two"))])),
        ])))
    }

    test("RTF mut: a destination word starts its destination's text afresh") {
        // R11: a second `\fldinst` inside an instruction replaces what the
        // first one collected, so the URL is the one written last.
        let d = try parseKill(#"\pard {\field{\*\fldinst HYPERLINK "https://a.test/" \*\fldinst HYPERLINK "https://b.test/"}{\fldrslt x}}\par"#)
        try expectEqual(d, doc(p(killText("x", killMark("link", ["href": .string("https://b.test/")])))))
    }

    // MARK: Lists

    test("RTF mut: \\pard clears an old-style \\pn written before it") {
        // R12: `\pn` describes the paragraph it is written in; `\pard` starts
        // a new set of paragraph properties.
        let d = try parseKill(#"{\*\pn\pnlvlblt\pnf0}\pard plain\par"#)
        try expectEqual(d, doc(p("plain")))
    }

    test("RTF mut: \\ls0 is not a list, even when an override maps it") {
        // R21.
        let d = try parseKill(killList(nfc: 0) + #"{\*\listoverridetable{\listoverride\listid1\listoverridecount0\ls0}}\pard\ls0 x\par"#)
        try expectEqual(d, doc(p("x")))
    }

    test("RTF mut: a list definition outranks an old-style \\pn on the same paragraph") {
        // R22: the list table says numbered; `\pnlvlblt` says bullet.
        let d = try parseKill(killList(nfc: 0) + #"\pard{\*\pn\pnlvlblt}\ls1\ilvl0 x\par"#)
        try expectEqual(d, doc(node("orderedList", [:], [item(p("x"))])))
    }

    test("RTF mut: a marker like 1) is numbered") {
        // R23.
        let d = try parseKill(#"\pard\ls1 {\listtext 1)\tab}x\par"#)
        try expectEqual(d, doc(node("orderedList", [:], [item(p("x"))])))
    }

    test("RTF mut: a checkbox drawn into the text is stripped with the space after it") {
        // R24.
        let d = try parseKill(#"\pard\ls1 {\listtext \'95\tab}\u9744? milk\par"#)
        try expectEqual(d, doc(node("taskList", [:], [node("taskItem", ["checked": .bool(false)], [p("milk")])])))
    }

    test("RTF mut: a negative \\ilvl reads as the first level, not out of range") {
        // R26.
        let d = try parseKill(killList(nfc: 0, levels: 2) + #"\pard\ls1\ilvl-1 x\par"#)
        try expectEqual(d, doc(node("orderedList", [:], [item(p("x"))])))
    }

    test("RTF mut: each \\lfolevel overrides the next level, in order") {
        // R27: the first override is level 0's start, the second level 1's.
        let d = try parseKill(killList(nfc: 0, levels: 2) +
            #"{\*\listoverridetable{\listoverride\listid1\listoverridecount2{\lfolevel\levelstartat5}{\lfolevel\levelstartat7}\ls1}}"# +
            #"\pard\ls1\ilvl0 x\par"#)
        try expectEqual(d, doc(node("orderedList", ["order": .int(5)], [item(p("x"))])))
    }

    // MARK: Headings

    test("RTF mut: outline levels 6 to 8 are still headings, clamped to 6") {
        // R28.
        let d = try parseKill(#"\pard\outlinelevel6 deep\par\pard\outlinelevel9 body\par"#)
        try expectEqual(d, doc(h(6, "deep"), p("body")))
    }

    test("RTF mut: a style named Title is a level-one heading") {
        // R29.
        let d = try parseKill(#"{\stylesheet{\s0 Normal;}{\s5 Title;}}\pard\s5 Big\par"#)
        try expectEqual(d, doc(h(1, "Big")))
    }

    test("RTF mut: a style named heading 7 is not a heading") {
        // R30: the document model's headings stop at 6.
        let d = try parseKill(#"{\stylesheet{\s0 Normal;}{\s7 heading 7;}}\pard\s7 Deep\par"#)
        try expectEqual(d, doc(p("Deep")))
    }

    // MARK: Tables

    test("RTF mut: a table three deep nests three deep") {
        // R31/R32: `\nestcell` and `\nestrow` at `\itap3` belong to the third
        // table, not the second.
        let d = try parseKill(
            #"\trowd\cellx6000"# +
            #"\pard\intbl\itap2 mid\par"# +
            #"\pard\intbl\itap3 deepest\nestcell{\*\nesttableprops\trowd\cellx2000\nestrow}"# +
            #"\pard\intbl\itap2 \nestcell{\*\nesttableprops\trowd\cellx4000\nestrow}"# +
            #"\pard\intbl\itap1 outer\cell\row\pard end\par"#)
        let outerCell = d.child(0).child(0).child(0)
        let middle = outerCell.child(0)
        try expectEqual(middle.type.name, "table")
        try expectEqual(middle.childCount, 1, "the inner row's end doesn't close the middle row early")
        let middleCell = middle.child(0).child(0)
        try expectEqual(middleCell.child(0), p("mid"))
        try expectEqual(middleCell.child(1).type.name, "table", "the innermost table sits in the middle one's cell")
        try expectEqual(middleCell.child(1).textContent, "deepest")
        try expectEqual(middleCell.childCount, 2)
        try expectEqual(outerCell.child(1), p("outer"))
        try expectEqual(d.child(1), p("end"))
    }

    test("RTF mut: text in a horizontally merged continuation cell is kept") {
        // R33.
        let d = try parseKill(#"\trowd\clmgf\cellx2000\clmrg\cellx4000\pard\intbl a\cell b\cell\row"#)
        let cell = d.child(0).child(0).child(0)
        try expectEqual(cell.attrs["colspan"], .int(2))
        try expectEqual(cell.content, Fragment.from([p("a"), p("b")]))
    }

    test("RTF mut: text in a vertically merged continuation cell is kept") {
        // R34.
        let d = try parseKill(#"\trowd\clvmgf\cellx2000\pard\intbl a\cell\row\trowd\clvmrg\cellx2000\pard\intbl b\cell\row"#)
        let cell = d.child(0).child(0).child(0)
        try expectEqual(cell.attrs["rowspan"], .int(2))
        try expectEqual(cell.content, Fragment.from([p("a"), p("b")]))
    }

    test("RTF mut: a cell of three paragraphs spills into three one-paragraph cells") {
        // R35: after a spill, the next block is matched against the new cell.
        let d = try RTFParser.parse(killRTF(#"\trowd\cellx2000\pard\intbl a\par b\par c\cell\row"#), schema: singleParagraphCells)
        try d.check()
        try expectEqual(rowTexts(d.child(0)), [["a", "b", "c"]])
    }

    test("RTF mut: only the first of the cells a spill makes keeps the width") {
        // R36.
        let d = try RTFParser.parse(killRTF(#"\trowd\cellx2000\pard\intbl a\par b\cell\row"#),
                                    schema: singleParagraphCells)
        let row = d.child(0).child(0)
        try expectEqual(row.childCount, 2)
        try expectEqual(row.child(0).attrs["colwidth"], .array([.int(100)]))
        try expectEqual(row.child(1).attrs["colwidth"], .null)
        try expectEqual(row.child(1).textContent, "b")
    }

    test("RTF mut: a merged cell with a column of no width gets no colwidth") {
        // R37: two boundaries at the same place give the second column no
        // width, so the widths can't describe both columns.
        let d = try parseKill(#"\trowd\clmgf\cellx2000\clmrg\cellx2000\pard\intbl a\cell\cell\row"#)
        let cell = d.child(0).child(0).child(0)
        try expectEqual(cell.attrs["colspan"], .int(2))
        try expectEqual(cell.attrs["colwidth"], .null)
    }

    test("RTF mut: an unclosed cell takes the alignment of its first aligned paragraph") {
        // R38: the cell never reaches `\cell`, so the row is closed at the end.
        let d = try parseKill(#"\trowd\cellx2000\pard\intbl\qc a\par\pard\intbl\qr b\par"#)
        let cell = d.child(0).child(0).child(0)
        try expectEqual(cell.content, Fragment.from([p("a"), p("b")]))
        try expectEqual(cell.attrs["align"], .string("center"))
    }

    test("RTF mut: \\intbl puts a paragraph in a table even beside \\itap0") {
        // R39: `\intbl` means at least one table deep, whatever `\itap` says,
        // so both paragraphs belong to the cell.
        let d = try parseKill(#"\trowd\cellx2000\pard\intbl\itap0 a\par b\cell\row\pard end\par"#)
        try expectEqual(d.childCount, 2)
        try expectEqual(d.child(0).type.name, "table")
        try expectEqual(d.child(0).child(0).child(0).content, Fragment.from([p("a"), p("b")]))
        try expectEqual(d.child(1), p("end"))
    }

    test("RTF mut: a bogus \\itap opens one table, not several") {
        // R40.
        let d = try parseKill(#"\pard\intbl\itap3 deep\cell\row\pard end\par"#)
        try expectEqual(d.child(0).child(0).child(0).content, Fragment.from([p("deep")]))
        try expectEqual(d.child(1), p("end"))
    }

    test("RTF mut: \\trhdr0 is not a header row") {
        // R41.
        let d = try parseKill(#"\trowd\trhdr0\cellx2000\pard\intbl a\cell\row"#)
        try expectEqual(d.child(0).child(0).child(0).type.name, "tableCell")
    }

    // MARK: Fields, pictures, footnotes

    test("RTF mut: a lowercase hyperlink field is still a link") {
        // R42: field codes are case-insensitive.
        let d = try parseKill(#"\pard {\field{\*\fldinst hyperlink "https://e.test/"}{\fldrslt x}}\par"#)
        try expectEqual(d, doc(p(killText("x", killMark("link", ["href": .string("https://e.test/")])))))
    }

    test("RTF mut: a bookmark link with no bookmark name links nowhere") {
        // R43.
        let d = try parseKill(#"\pard {\field{\*\fldinst HYPERLINK \\l ""}{\fldrslt x}}\par"#)
        try expectEqual(d, doc(p("x")))
    }

    test("RTF mut: a picture exactly at the size limit is kept") {
        // R44.
        let d = try parseKill(#"\pard a{\pict\pngblip 89504e47}b\par"#, config: RTFConfig(maxImageBytes: 4))
        try expectEqual(d, doc(p(t("a"), node("image", ["src": .string("data:image/png;base64,iVBORw==")]), t("b"))))
    }

    test("RTF mut: a picture inside a footnote belongs to the note") {
        // R45.
        let d = try parseKill(#"\pard x{\footnote\pard n{\pict\pngblip 89504e47}\par}\par"#)
        try expectEqual(d, doc(
            p(t("x"), node("footnoteReference", ["label": .string("1")])),
            node("footnoteDefinition", ["label": .string("1")], [
                p(t("n"), node("image", ["src": .string("data:image/png;base64,iVBORw==")])),
            ])))
    }

    test("RTF mut: a note's trailing empty paragraphs are not part of it") {
        // R46.
        let d = try parseKill(#"\pard x{\footnote\pard note\par\par\par}\par"#)
        try expectEqual(d.child(1), node("footnoteDefinition", ["label": .string("1")], [p("note")]))
    }

    test("RTF mut: every trailing empty paragraph is dropped, not just the last") {
        // R47.
        let d = try parseKill(#"\pard x\par\par\par"#)
        try expectEqual(d, doc(p("x")))
    }

    test("RTF mut: an empty paragraph between monospaced lines is not a code line") {
        // R48: with nothing in it, the paragraph says nothing about its font.
        let d = try parseKill(#"\pard\f1 a\par\pard\f1\par\pard\f1 b\par"#)
        try expectEqual(d, doc(node("codeBlock", [:], [t("a")]), p(""), node("codeBlock", [:], [t("b")])))
    }

    test("RTF mut: monospaceAsCode off leaves a monospaced run unmarked") {
        // R49.
        let d = try parseKill(#"\pard x \f1 y\f0\par"#, config: RTFConfig(monospaceAsCode: false))
        try expectEqual(d, doc(p("x y")))
    }

    // MARK: MathML

    test("MathML mut: mode=display is display maths") {
        // M01.
        let got = try killMath(#"<p><math mode="display"><mi>x</mi></math></p>"#)
        try expectEqual(got.map(\.1), [true])
    }

    test("MathML mut: an annotation whose encoding is just TeX is the source") {
        // M02.
        let latex = try latexOf(#"<math><semantics><msup><mi>x</mi><mn>2</mn></msup><annotation encoding="TeX">x^2</annotation></semantics></math>"#)
        try expectEqual(latex, "x^2")
    }

    test("MathML mut: an alttext that isn't wrapped whole in \\textstyle is kept as it is") {
        // M03: the wrapper has to close at the very end to be a wrapper.
        let latex = try latexOf(#"<math alttext="{\textstyle a}+b"><mi>q</mi></math>"#)
        try expectEqual(latex, "{\\textstyle a}+b")
    }

    test("MathML mut: linethickness 0pt is a binomial") {
        // M04.
        try expectEqual(try latexOf(#"<math><mfrac linethickness="0pt"><mi>n</mi><mi>k</mi></mfrac></math>"#), "\\binom{n}{k}")
    }

    test("MathML mut: mfenced separates with commas by default") {
        // M05.
        try expectEqual(try latexOf("<math><mfenced><mi>a</mi><mi>b</mi></mfenced></math>"), "\\left(a,b\\right)")
    }

    test("MathML mut: an empty mfenced delimiter is the null delimiter") {
        // M06.
        try expectEqual(try latexOf(#"<math><mfenced open="" close="|" separators=""><mi>c</mi><mi>d</mi></mfenced></math>"#),
                        "\\left.cd\\right|")
    }

    test("MathML mut: a one-character base takes its script without braces") {
        // M07.
        try expectEqual(try latexOf("<math><msup><mi>x</mi><mn>2</mn></msup></math>"), "x^{2}")
    }

    test("MathML mut: a command base with an argument after it is braced") {
        // M08: `\sin x` raised to a power is `{\sin x}^{2}`, not `\sin x^{2}`.
        try expectEqual(try latexOf("<math><msup><mrow><mi>sin</mi><mi>x</mi></mrow><mn>2</mn></msup></math>"), "{\\sin x}^{2}")
    }

    test("MathML mut: only a control word needs a space before a following letter") {
        // M09: `2a` then `b` is `2ab`.
        try expectEqual(try latexOf("<math><mn>2</mn><mi>a</mi><mi>b</mi></math>"), "2ab")
    }

    test("MathML mut: a two-letter identifier is a name, and a known one a function") {
        // M11.
        try expectEqual(try latexOf("<math><mi>ab</mi><mo>+</mo><mi>ln</mi><mi>x</mi></math>"), "\\mathrm{ab}+\\ln x")
    }

    test("MathML mut: loose text inside a formula is escaped") {
        // M12.
        try expectEqual(try latexOf("<math><mrow>a{b}</mrow></math>"), "a\\{b\\}")
    }

    test("MathML mut: a formula with nothing in it is dropped, not kept empty") {
        // M13.
        let d = try HTMLParser.parse("<p>a<math><mrow></mrow></math>b</p>", schema: schema)
        try expectEqual(d, doc(p("ab")))
    }
}
