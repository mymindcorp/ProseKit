import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// RTF → document conversion, checked against the RTF that real producers write.
// Fixtures are spelled the way Word, TextEdit, Pages and `NSAttributedString`
// spell the same construct, since the reader's job is defined by what they emit
// rather than by what the specification permits.

private let pngHex =
    "89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de" +
    "0000000c49444154789c63f8cfc0000003010100c9fe92ef0000000049454e44ae426082"

/// The header every fixture shares: a Helvetica body font and a Courier one, so
/// the monospace heuristic has something to recognize.
private let pngBytes: [UInt8] = {
    var out: [UInt8] = []
    var high: UInt8?
    for c in pngHex.utf8 {
        let v: UInt8 = c >= 97 ? c - 87 : (c >= 65 ? c - 55 : c - 48)
        if let h = high { out.append(h * 16 + v); high = nil } else { high = v }
    }
    return out
}()

private let header = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Courier New;}}"#

private func rtf(_ body: String) -> String { header + body + "}" }

/// The `{\listtext …}` group a producer draws in front of a list paragraph,
/// tab-delimited the way TextEdit and Word write it.
private func marker(_ rtfText: String) -> String { "{\\listtext\t\(rtfText)\t}" }

/// A `\listtable` entry: one `\list` with the given id, whose levels are given
/// as raw `\listlevel` bodies.
private func listTable(_ lists: String...) -> String {
    #"{\*\listtable"# + lists.joined() + "}"
}

private func list(id: Int, _ levels: String...) -> String {
    #"{\list\listtemplateid\#(id)"# + levels.joined() + #"\listid\#(id)}"#
}

/// One `\listlevel`: a number-format code, an optional start, and the marker
/// template a reader would draw.
private func level(nfc: Int, startAt: Int? = nil, text: String = "") -> String {
    var body = #"{\listlevel\levelnfc\#(nfc)\levelnfcn\#(nfc)\leveljc0\levelfollow0"#
    if let startAt { body += #"\levelstartat\#(startAt)"# }
    return body + #"{\leveltext\#(text);}{\levelnumbers;}}"#
}

/// A `\listoverride` mapping the `\ls` a paragraph names to a list id.
private func override(ls: Int, id: Int, startAt: Int? = nil) -> String {
    var body = #"{\*\listoverridetable{\listoverride\listid\#(id)\listoverridecount0"#
    if let startAt { body += #"{\lfolevel\levelstartat\#(startAt)}"# }
    return body + #"\ls\#(ls)}}"#
}

private func mark(_ name: String, _ attrs: Attrs = [:]) -> Mark { schema.mark(name, attrs) }
private func marked(_ text: String, _ marks: Mark...) -> Node { schema.text(text, marks) }

func registerRTFTests() {
    test("RTF: paragraphs and character formatting") {
        let d = try RTFParser.parse(rtf(#"\pard Hello \b world\b0 .\par\pard Second \i line\i0 \par"#), schema: schema)
        try expectEqual(d, doc(
            p(t("Hello "), strong("world"), t(".")),
            p(t("Second "), em("line"))))
    }

    test("RTF: underline, strike, super/subscript, and hidden text") {
        let d = try RTFParser.parse(rtf(
            #"\pard \ul under\ulnone \strike out\strike0  x\super 2\nosupersub  y\sub 1\nosupersub \v secret\v0 !\par"#),
            schema: schema)
        try expectEqual(d, doc(p(
            marked("under", mark("underline")),
            marked("out", mark("strike")), t(" x"),
            marked("2", mark("superscript")), t(" y"),
            marked("1", mark("subscript")), t("!"))))
    }

    test("RTF: \\plain resets character formatting") {
        let d = try RTFParser.parse(rtf(#"\pard \b\i bold italic\plain  plain\par"#), schema: schema)
        try expectEqual(d, doc(p(
            marked("bold italic", mark("bold"), mark("italic")), t(" plain"))))
    }

    test("RTF: code page escapes, \\u, and the \\uc fallback count") {
        // `\'e9` is cp1252 é; `\u8212?` is an em dash with one fallback char to
        // swallow; `\'92` is cp1252's curly apostrophe, not Latin-1's control.
        let d = try RTFParser.parse(rtf(#"\pard \uc1 caf\'e9 \u8212? don\'92t\par"#), schema: schema)
        try expectEqual(d.textContent, "café \u{2014} don\u{2019}t")
    }

    test("RTF: \\uc0 swallows nothing, \\uc2 swallows two") {
        try expectEqual(try RTFParser.parse(rtf(#"\pard \uc0\u9731  !\par"#), schema: schema).textContent, "\u{2603} !")
        try expectEqual(try RTFParser.parse(rtf(#"\pard \uc2\u9731 ?? !\par"#), schema: schema).textContent, "\u{2603} !")
    }

    test("RTF: a surrogate pair is one character") {
        let d = try RTFParser.parse(rtf(#"\pard \uc0\u55357 \u56842 \par"#), schema: schema)
        try expectEqual(d.textContent, "\u{1F60A}")
    }

    test("RTF: \\ansicpg decides what an escaped byte means") {
        // The same byte, three code pages: cp1252 é, cp1251 Cyrillic й,
        // cp1250 Central European é.
        let cases: [(Int, String)] = [(1252, "\u{00E9}"), (1251, "\u{0439}"), (1250, "\u{00E9}")]
        for (page, expected) in cases {
            let source = #"{\rtf1\ansi\ansicpg\#(page)\pard \'e9\par}"#
            try expectEqual(try RTFParser.parse(source, schema: schema).textContent, expected, "cp\(page)")
        }
    }

    test("RTF: a font's \\fcharset overrides the document code page") {
        // A cp1252 document with a Cyrillic-charset font — exactly what Word
        // writes for a Russian run in an otherwise Western document.
        let source = #"{\rtf1\ansi\ansicpg1252{\fonttbl{\f0\fswiss\fcharset0 Helvetica;}"# +
            #"{\f1\fswiss\fcharset204 Arial Cyr;}}\pard \'e9\f1 \'e9\f0 \'e9\par}"#
        try expectEqual(try RTFParser.parse(source, schema: schema).textContent,
                        "\u{00E9}\u{0439}\u{00E9}")
    }

    test("RTF: a multi-byte code page decodes its bytes together") {
        // Shift-JIS: 0x93 0xFA is \u65e5, which reading a byte at a time cannot
        // produce.
        let source = #"{\rtf1\ansi\ansicpg932\pard \'93\'fa\'96\'7b\par}"#
        try expectEqual(try RTFParser.parse(source, schema: schema).textContent, "\u{65E5}\u{672C}")
    }

    test("RTF: MacRoman is read as MacRoman") {
        let source = #"{\rtf1\mac\ansicpg10000\pard \'8e\par}"#
        try expectEqual(try RTFParser.parse(source, schema: schema).textContent, "\u{00E9}")
    }

    test("RTF: a code page nobody knows falls back rather than failing") {
        for page in [99999, 1, 0] {
            let source = #"{\rtf1\ansi\ansicpg\#(page)\pard \'e9x\par}"#
            let d = try RTFParser.parse(source, schema: schema)
            try d.check()
            try expect(d.textContent.hasSuffix("x"), "cp\(page): \(d.textContent)")
        }
    }

    test("RTF: bytes written raw rather than escaped decode the same way") {
        // Some producers put the byte straight in the stream.
        let escaped = try RTFParser.parse(Data(#"{\rtf1\ansi\ansicpg1251\pard \'e9\par}"#.utf8), schema: schema)
        var raw = Array(#"{\rtf1\ansi\ansicpg1251\pard "#.utf8)
        raw.append(0xE9)
        raw.append(contentsOf: Array(#"\par}"#.utf8))
        try expectEqual(try RTFParser.parse(Data(raw), schema: schema), escaped)
    }

    test("RTF: escaped bytes still split around formatting") {
        let source = #"{\rtf1\ansi\ansicpg1252\pard \'e9\b\'e9\b0\par}"#
        let d = try RTFParser.parse(source, schema: schema)
        try expectEqual(d, doc(p(t("\u{00E9}"), strong("\u{00E9}"))))
    }

    test("RTF: named literals and escaped braces") {
        let d = try RTFParser.parse(rtf(#"\pard \lquote a\rquote  \ldblquote b\rdblquote  c\emdash d \{e\} 50\'25 \\ \~x\par"#),
                                    schema: schema)
        try expectEqual(d.textContent, "\u{2018}a\u{2019} \u{201C}b\u{201D} c\u{2014}d {e} 50% \\ \u{00A0}x")
    }

    test("RTF: \\line is a hard break, \\tab is a tab") {
        let d = try RTFParser.parse(rtf(#"\pard one\line two\tab three\par"#), schema: schema)
        try expectEqual(d, doc(p(t("one"), node("hardBreak"), t("two\tthree"))))
    }

    test("RTF: a HYPERLINK field becomes a link mark") {
        let d = try RTFParser.parse(rtf(
            #"\pard see {\field{\*\fldinst{HYPERLINK "https://example.com/a?b=1"}}{\fldrslt{\ul\cf1 the docs}}} now\par"#),
            schema: schema)
        try expectEqual(d, doc(p(
            t("see "),
            marked("the docs", mark("underline"), mark("link", ["href": .string("https://example.com/a?b=1")])),
            t(" now"))))
    }

    test("RTF: a javascript: field URL is dropped, its text kept") {
        let d = try RTFParser.parse(rtf(
            #"\pard {\field{\*\fldinst{HYPERLINK "javascript:alert(1)"}}{\fldrslt click}}\par"#), schema: schema)
        try expectEqual(d, doc(p("click")))
    }

    test("RTF: consecutive fields don't leak one URL into the next") {
        let d = try RTFParser.parse(rtf(
            #"\pard {\field{\*\fldinst{HYPERLINK "https://a.test"}}{\fldrslt a}} plain "# +
            #"{\field{\*\fldinst{HYPERLINK "https://b.test"}}{\fldrslt b}}\par"#), schema: schema)
        try expectEqual(d, doc(p(
            marked("a", mark("link", ["href": .string("https://a.test")])),
            t(" plain "),
            marked("b", mark("link", ["href": .string("https://b.test")])))))
    }

    test("RTF: TextEdit bullets nest by left indent") {
        let d = try RTFParser.parse(rtf(
            #"\pard\li720\fi-360"# + marker(#"\uc0\u8226 "#) + #"One\par"# +
            #"\pard\li1440\fi-360"# + marker(#"\uc0\u8226 "#) + #"Deep\par"# +
            #"\pard\li720\fi-360"# + marker(#"\uc0\u8226 "#) + #"Two\par"#), schema: schema)
        try expectEqual(d, doc(node("bulletList", [:], [
            node("listItem", [:], [p("One"), node("bulletList", [:], [node("listItem", [:], [p("Deep")])])]),
            node("listItem", [:], [p("Two")]),
        ])))
    }

    test("RTF: Word bullets nest by \\ilvl") {
        let d = try RTFParser.parse(rtf(
            #"\pard\ls1\ilvl0{\listtext\f3\'b7\tab}One\par"# +
            #"\pard\ls1\ilvl1{\listtext\f3\'b7\tab}Deep\par"#), schema: schema)
        try expectEqual(d, doc(node("bulletList", [:], [
            node("listItem", [:], [p("One"), node("bulletList", [:], [node("listItem", [:], [p("Deep")])])]),
        ])))
    }

    test("RTF: a numbered marker makes an ordered list") {
        let d = try RTFParser.parse(rtf(
            #"\pard\ls1\ilvl0"# + marker("1.") + #"First\par\pard\ls1\ilvl0"# + marker("2.") + #"Second\par"#), schema: schema)
        try expectEqual(d, doc(node("orderedList", [:], [
            node("listItem", [:], [p("First")]),
            node("listItem", [:], [p("Second")]),
        ])))
    }

    test("RTF: a list type switch at one level starts a new list") {
        let d = try RTFParser.parse(rtf(
            #"\pard\ls1\ilvl0"# + marker(#"\uc0\u8226 "#) + #"Bullet\par\pard\ls2\ilvl0"# + marker("1.") + #"Number\par"#),
            schema: schema)
        try expectEqual(d, doc(
            node("bulletList", [:], [node("listItem", [:], [p("Bullet")])]),
            node("orderedList", [:], [node("listItem", [:], [p("Number")])])))
    }

    test("RTF: checkbox markers become a task list with checked state") {
        let d = try RTFParser.parse(rtf(
            #"\pard\ls1\ilvl0"# + marker(#"\uc0\u9744 "#) + #"todo\par\pard\ls1\ilvl0"# + marker(#"\uc0\u9745 "#) + #"done\par"#),
            schema: schema)
        try expectEqual(d, doc(node("taskList", [:], [
            node("taskItem", ["checked": .bool(false)], [p("todo")]),
            node("taskItem", ["checked": .bool(true)], [p("done")]),
        ])))
    }

    test("RTF: a checkbox drawn into the item's text is still a marker") {
        // Apple's RTF sometimes writes the glyph as content rather than as a
        // `\listtext`, which used to leave "\u9745 milk" as the line's text.
        let d = try RTFParser.parse(rtf(
            #"\pard\ls1\ilvl0 \uc0\u9745 \tab milk\par\pard\ls1\ilvl0 \uc0\u9744 \tab eggs\par"#),
            schema: schema)
        try expectEqual(d, doc(node("taskList", [:], [
            node("taskItem", ["checked": .bool(true)], [p("milk")]),
            node("taskItem", ["checked": .bool(false)], [p("eggs")]),
        ])))
    }

    test("RTF: a checkbox glyph in ordinary prose is left alone") {
        let d = try RTFParser.parse(rtf(#"\pard \uc0\u9745 \tab not a list\par"#), schema: schema)
        try expectEqual(d.textContent, "\u{2611}\tnot a list")
    }

    test("RTF: \\ls with no marker is still a list") {
        let d = try RTFParser.parse(rtf(#"\pard\ls3\ilvl0 item\par"#), schema: schema)
        try expectEqual(d, doc(node("bulletList", [:], [node("listItem", [:], [p("item")])])))
    }

    test("RTF: a marker never becomes document text") {
        let d = try RTFParser.parse(rtf(#"\pard\ls1\ilvl0{\listtext\f3\'b7\tab}milk\par"#), schema: schema)
        try expectEqual(d.textContent, "milk")
    }

    test("RTF: stylesheet names make headings") {
        let d = try RTFParser.parse(
            header + #"{\stylesheet{\s0 Normal;}{\s2\sbasedon0 heading 1;}{\s3\sbasedon0 heading 3;}}"# +
            #"\pard\s2 Title\par\pard\s3 Deeper\par\pard\s0 Body\par}"#, schema: schema)
        try expectEqual(d, doc(h(1, "Title"), h(3, "Deeper"), p("Body")))
    }

    test("RTF: \\outlinelevel makes a heading") {
        let d = try RTFParser.parse(rtf(#"\pard\outlinelevel1 Sub\par\pard Body\par"#), schema: schema)
        try expectEqual(d, doc(h(2, "Sub"), p("Body")))
    }

    test("RTF: colour table drives text and background colour marks") {
        let d = try RTFParser.parse(
            header + #"{\colortbl;\red255\green0\blue0;\red0\green128\blue255;}"# +
            #"\pard \cf1 red\cf0  plain \highlight2 lit\highlight0 \par}"#, schema: schema)
        try expectEqual(d, doc(p(
            marked("red", mark("textColor", ["color": .string("#ff0000")])),
            t(" plain "),
            marked("lit", mark("backgroundColor", ["color": .string("#0080ff")])))))
    }

    test("RTF: a monospaced paragraph run becomes one code block") {
        let d = try RTFParser.parse(rtf(#"\pard\f1 let x = 1\par\pard\f1 let y = 2\par\pard\f0 prose\par"#),
                                    schema: schema)
        try expectEqual(d, doc(node("codeBlock", [:], [t("let x = 1\nlet y = 2")]), p("prose")))
    }

    test("RTF: a monospaced run inside prose is a code mark") {
        let d = try RTFParser.parse(rtf(#"\pard call \f1 print()\f0  twice\par"#), schema: schema)
        try expectEqual(d, doc(p(t("call "), marked("print()", mark("code")), t(" twice"))))
    }

    test("RTF: monospaceAsCode off keeps prose") {
        var config = RTFConfig.default
        config.monospaceAsCode = false
        let d = try RTFParser.parse(rtf(#"\pard\f1 let x = 1\par"#), schema: schema, config: config)
        try expectEqual(d, doc(p("let x = 1")))
    }

    test("RTF: a table becomes rows and cells, header rows included") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\trhdr\cellx2880\cellx5760\pard\intbl A\cell\pard\intbl B\cell\row"# +
            #"\trowd\cellx2880\cellx5760\pard\intbl C\cell\pard\intbl D\cell\row"# +
            #"\pard After\par"#), schema: schema)
        // `\cellx` boundaries are twips, so each column is 144 points wide.
        let w: Attrs = ["colwidth": .array([.int(144)])]
        try expectEqual(d, doc(
            node("table", [:], [
                node("tableRow", [:], [node("tableHeader", w, [p("A")]), node("tableHeader", w, [p("B")])]),
                node("tableRow", [:], [node("tableCell", w, [p("C")]), node("tableCell", w, [p("D")])]),
            ]),
            p("After")))
    }

    test("RTF: a multi-paragraph cell keeps both paragraphs") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\cellx2880\pard\intbl one\par\pard\intbl two\cell\row\pard end\par"#), schema: schema)
        try expectEqual(d, doc(
            node("table", [:], [node("tableRow", [:], [
                node("tableCell", ["colwidth": .array([.int(144)])], [p("one"), p("two")])])]),
            p("end")))
    }

    test("RTF: a horizontal merge is one cell with a colspan") {
        // Word writes the merged range as one cell per column: `\clmgf` starts
        // it and `\clmrg` continues it, and the continuation cells are empty.
        let d = try RTFParser.parse(rtf(
            #"\trowd\clmgf\cellx2880\clmrg\cellx5760\cellx8640"# +
            #"\pard\intbl wide\cell\pard\intbl\cell\pard\intbl third\cell\row\pard end\par"#),
            schema: schema)
        let row = d.child(0).child(0)
        try expectEqual(row.childCount, 2)
        try expectEqual(row.child(0).attrs["colspan"], .int(2))
        try expectEqual(row.child(0).attrs["colwidth"], .array([.int(144), .int(144)]))
        try expectEqual(row.child(0).textContent, "wide")
        try expectEqual(row.child(1).attrs["colspan"], .int(1))
        try expectEqual(row.child(1).textContent, "third")
    }

    test("RTF: a vertical merge raises the rowspan of the cell above") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\clvmgf\cellx2880\cellx5760\pard\intbl tall\cell\pard\intbl a\cell\row"# +
            #"\trowd\clvmrg\cellx2880\cellx5760\pard\intbl\cell\pard\intbl b\cell\row"# +
            #"\trowd\clvmrg\cellx2880\cellx5760\pard\intbl\cell\pard\intbl c\cell\row\pard end\par"#),
            schema: schema)
        let table = d.child(0)
        try expectEqual(table.childCount, 3)
        try expectEqual(table.child(0).child(0).attrs["rowspan"], .int(3))
        try expectEqual(table.child(0).child(0).textContent, "tall")
        // The rows the merge passes through hold only their own cells.
        try expectEqual(table.child(1).childCount, 1)
        try expectEqual(table.child(1).child(0).textContent, "b")
        try expectEqual(table.child(2).child(0).textContent, "c")
    }

    test("RTF: \\trleft is where the first column starts") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\trleft1440\cellx2880\pard\intbl x\cell\row\pard end\par"#), schema: schema)
        try expectEqual(d.child(0).child(0).child(0).attrs["colwidth"], .array([.int(72)]))
    }

    test("RTF: a table with no \\cellx widths still builds") {
        let d = try RTFParser.parse(rtf(#"\trowd\pard\intbl a\cell\pard\intbl b\cell\row\pard end\par"#),
                                    schema: schema)
        let row = d.child(0).child(0)
        try expectEqual(row.childCount, 2)
        try expectEqual(row.child(0).attrs["colwidth"], .null)
    }

    test("RTF: a nested table nests instead of flattening") {
        // Word writes the inner cells with `\nestcell` at `\itap2`, and the
        // inner row's definition afterwards, inside `\*\nesttableprops`.
        let d = try RTFParser.parse(rtf(
            #"\trowd\cellx8640"# +
            #"\pard\intbl\itap2 in1\nestcell\pard\intbl\itap2 in2\nestcell"# +
            #"{\*\nesttableprops\trowd\cellx2880\cellx5760\nestrow}"# +
            #"\pard\intbl\itap1 outer\cell\row\pard end\par"#), schema: schema)
        let outerCell = d.child(0).child(0).child(0)
        try expectEqual(outerCell.child(0).type.name, "table")
        try expectEqual(outerCell.child(0).child(0).childCount, 2)
        try expectEqual(outerCell.child(0).textContent, "in1in2")
        try expectEqual(outerCell.child(1).type.name, "paragraph")
        try expectEqual(outerCell.child(1).textContent, "outer")
        try expectEqual(d.child(1), p("end"))
    }

    test("RTF: a nested table's fallback copy isn't read twice") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\cellx8640\pard\intbl\itap2 inner\nestcell"# +
            #"{\*\nesttableprops\trowd\cellx2880\nestrow}"# +
            #"{\*\nonesttables\par inner}"# +
            #"\pard\intbl\itap1 outer\cell\row\pard end\par"#), schema: schema)
        try expectEqual(d.textContent, "innerouterend")
    }

    test("RTF: an unclosed table still reaches the document") {
        for body in [#"\trowd\cellx2880\pard\intbl a\cell"#,              // no \row
                     #"\trowd\cellx2880\pard\intbl a"#,                   // no \cell either
                     #"\pard\intbl\itap2 deep\nestcell"#,                 // nested, nothing closed
                     #"\trowd\cellx2880\pard\intbl a\cell\row"#] {        // no paragraph after
            let d = try RTFParser.parse(rtf(body), schema: schema)
            try d.check()
            try expect(d.textContent.contains("a") || d.textContent.contains("deep"), "body: \(body)")
        }
    }

    test("RTF: merge flags that name no cell above don't lose the cell") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\clvmrg\cellx2880\cellx5760\pard\intbl a\cell\pard\intbl b\cell\row\pard end\par"#),
            schema: schema)
        try expectEqual(d.child(0).child(0).childCount, 2)
        try expectEqual(d.textContent, "abend")
    }

    test("RTF: a cell holds real blocks, not a run of paragraphs") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\cellx8640\pard\intbl\outlinelevel0 Head\par"# +
            #"\pard\intbl\ls1\ilvl0"# + marker("1.") + #"one\par"# +
            #"\pard\intbl\ls1\ilvl0"# + marker("2.") + #"two\par"# +
            #"\pard\intbl tail\cell\row\pard end\par"#), schema: schema)
        let cell = d.child(0).child(0).child(0)
        try expectEqual(cell.childCount, 3)
        try expectEqual(cell.child(0), h(1, "Head"))
        try expectEqual(cell.child(1), node("orderedList", [:], [
            node("listItem", [:], [p("one")]),
            node("listItem", [:], [p("two")]),
        ]))
        try expectEqual(cell.child(2), p("tail"))
    }

    test("RTF: a monospaced run of lines in a cell is one code block") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\cellx8640\pard\intbl\f1 let x = 1\par\pard\intbl\f1 let y = 2\cell\row\pard end\par"#),
            schema: schema)
        let cell = d.child(0).child(0).child(0)
        try expectEqual(cell.childCount, 1)
        try expectEqual(cell.child(0), node("codeBlock", [:], [t("let x = 1\nlet y = 2")]))
    }

    test("RTF: a cell that ends with \\par gains no empty paragraph") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\cellx8640\pard\intbl only\par\cell\row\pard end\par"#), schema: schema)
        let cell = d.child(0).child(0).child(0)
        try expectEqual(cell.childCount, 1)
        try expectEqual(cell.child(0), p("only"))
    }

    test("RTF: an empty cell is still a cell") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\cellx2880\cellx5760\pard\intbl\cell\pard\intbl b\cell\row\pard end\par"#), schema: schema)
        let row = d.child(0).child(0)
        try expectEqual(row.childCount, 2)
        try expectEqual(row.child(0).child(0), p(""))
        try expectEqual(row.child(1).textContent, "b")
    }

    test("RTF: a cell keeps the alignment of its content") {
        let d = try RTFParser.parse(rtf(
            #"\trowd\cellx2880\cellx5760\cellx8640"# +
            #"\pard\intbl\qc mid\cell\pard\intbl\qr end\cell\pard\intbl plain\cell\row\pard after\par"#),
            schema: schema)
        let row = d.child(0).child(0)
        try expectEqual(row.child(0).attrs["align"], .string("center"))
        try expectEqual(row.child(1).attrs["align"], .string("right"))
        try expectEqual(row.child(2).attrs["align"], .null)
    }

    test("RTF: a footnote survives on out into Markdown and HTML") {
        // The reference/definition pair the RTF reader builds is the same shape
        // Markdown writes as `[^1]` / `[^1]:` and HTML as a data-typed sup/div,
        // so a note pasted from Word comes back out in either.
        let d = try RTFParser.parse(rtf(
            #"\pard body{\footnote\pard the note\par}.\par"#), schema: schema)
        let markdown = MarkdownSerializer.serialize(d)
        try expect(markdown.contains("body[^1]."), markdown)
        try expect(markdown.contains("[^1]: the note"), markdown)
        // …and back again, to the same document.
        try expectEqual(try MarkdownParser.parse(markdown, schema: schema), d)
        let html = HTMLSerializer.serialize(d)
        try expect(html.contains("data-type=\"footnoteReference\""), html)
        try expect(html.contains("data-type=\"footnoteDefinition\""), html)
    }

    test("RTF: a picture becomes an image with a data URL") {
        let d = try RTFParser.parse(rtf(
            #"\pard {\*\shppict{\pict\pngblip\picw1\pich1\picwgoal1440\pichgoal720 "# + pngHex + "}}\\par"),
            schema: schema)
        let image = d.child(0).child(0)
        try expectEqual(image.type.name, "image")
        try expect(image.attrs["src"]?.stringValue?.hasPrefix("data:image/png;base64,iVBORw0KGgo") == true,
                   "src was \(String(describing: image.attrs["src"]))")
        try expectEqual(image.attrs["width"], .int(72))
        try expectEqual(image.attrs["height"], .int(36))
    }

    test("RTF: a picture in a format we can't name is dropped, not inlined") {
        let d = try RTFParser.parse(rtf(#"\pard {\pict\wmetafile8\picw1\pich1 0102030405}x\par"#), schema: schema)
        try expectEqual(d, doc(p("x")))
    }

    test("RTF: embedImages off drops pictures") {
        var config = RTFConfig.default
        config.embedImages = false
        let d = try RTFParser.parse(rtf(#"\pard {\pict\pngblip\picw1\pich1 "# + pngHex + "}x\\par"),
                                    schema: schema, config: config)
        try expectEqual(d, doc(p("x")))
    }

    test("RTF: metadata and unknown destinations are dropped whole") {
        let d = try RTFParser.parse(rtf(
            #"{\info{\author Somebody}{\title Not the document}}"# +
            #"{\*\generator Word;}{\*\bkmkstart mark}{\*\someunknowndest hidden\par junk}"# +
            #"\pard real\par"#), schema: schema)
        try expectEqual(d, doc(p("real")))
    }

    test("RTF: a footnote becomes a reference and a definition") {
        let d = try RTFParser.parse(rtf(
            #"\pard body{\super\chftn}{\footnote\pard the note\par}. more\par"#), schema: schema)
        try expectEqual(d, doc(
            p(t("body"), node("footnoteReference", ["label": .string("1")]), t(". more")),
            node("footnoteDefinition", ["label": .string("1")], [p("the note")])))
    }

    test("RTF: footnotes are numbered in the order they appear") {
        let d = try RTFParser.parse(rtf(
            #"\pard a{\footnote\pard first\par} b{\footnote\pard second\par}\par"#), schema: schema)
        try expectEqual(d.childCount, 3)
        try expectEqual(d.child(0).textContent, "a[^1] b[^2]")
        try expectEqual(d.child(1).attrs["label"], .string("1"))
        try expectEqual(d.child(1).textContent, "first")
        try expectEqual(d.child(2).attrs["label"], .string("2"))
        try expectEqual(d.child(2).textContent, "second")
    }

    test("RTF: a note with several blocks keeps them all") {
        let d = try RTFParser.parse(rtf(
            #"\pard x{\footnote\pard one\par\pard\ls1\ilvl0"# + marker(#"\u8226 "#) + #"item\par}\par"#), schema: schema)
        let definition = d.child(1)
        try expectEqual(definition.type.name, "footnoteDefinition")
        try expectEqual(definition.child(0), p("one"))
        try expectEqual(definition.child(1).type.name, "bulletList")
    }

    test("RTF: a schema without footnotes drops the note, not the paragraph") {
        let plain = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "inline*", group: "block")),
            ("text", NodeSpec(group: "inline")),
        ], marks: [], topNode: "doc")
        let d = try RTFParser.parse(rtf(#"\pard body{\footnote\pard the note\par}!\par"#), schema: plain)
        try expectEqual(d.textContent, "body!")
    }

    test("RTF: \\bin skips exactly its byte count") {
        // The binary payload spells `\par junk` — read as text it would produce
        // a second paragraph.
        let payload = #"\par junk"#
        let d = try RTFParser.parse(rtf(
            #"\pard a{\*\unknown\bin\#(payload.count) \#(payload)}b\par"#), schema: schema)
        try expectEqual(d, doc(p("ab")))
    }

    test("RTF: the list table says a list is numbered, and where it starts") {
        let d = try RTFParser.parse(rtf(
            listTable(list(id: 101, level(nfc: 0, startAt: 3))) + override(ls: 1, id: 101) +
            #"\pard\ls1\ilvl0 First\par\pard\ls1\ilvl0 Second\par"#), schema: schema)
        try expectEqual(d, doc(node("orderedList", ["order": .int(3)], [
            node("listItem", [:], [p("First")]),
            node("listItem", [:], [p("Second")]),
        ])))
    }

    test("RTF: a numbered list with no marker is no longer read as a bullet") {
        let d = try RTFParser.parse(rtf(
            listTable(list(id: 7, level(nfc: 0))) + override(ls: 1, id: 7) +
            #"\pard\ls1\ilvl0 only\par"#), schema: schema)
        try expectEqual(d, doc(node("orderedList", [:], [node("listItem", [:], [p("only")])])))
    }

    test("RTF: every numbering format is an ordered list, bullets stay bullets") {
        // Roman, lettered and ordinal levels are all one ordered list here —
        // the document model has no per-level format — but `\levelnfc23` is a
        // genuine bullet and has to stay one.
        for (nfc, name) in [(0, "orderedList"), (1, "orderedList"), (2, "orderedList"),
                            (3, "orderedList"), (4, "orderedList"), (5, "orderedList"),
                            (22, "orderedList"), (23, "bulletList"), (255, "bulletList")] {
            let d = try RTFParser.parse(rtf(
                listTable(list(id: 9, level(nfc: nfc))) + override(ls: 1, id: 9) +
                #"\pard\ls1\ilvl0 x\par"#), schema: schema)
            try expectEqual(d.child(0).type.name, name, "levelnfc\(nfc)")
        }
    }

    test("RTF: the level a paragraph sits at picks its own format") {
        let d = try RTFParser.parse(rtf(
            listTable(list(id: 5, level(nfc: 0, startAt: 2), level(nfc: 23))) + override(ls: 1, id: 5) +
            #"\pard\ls1\ilvl0 outer\par\pard\ls1\ilvl1 inner\par"#), schema: schema)
        try expectEqual(d, doc(node("orderedList", ["order": .int(2)], [
            node("listItem", [:], [p("outer"), node("bulletList", [:], [node("listItem", [:], [p("inner")])])]),
        ])))
    }

    test("RTF: a \\lfolevel start beats the definition's own") {
        let d = try RTFParser.parse(rtf(
            listTable(list(id: 3, level(nfc: 0, startAt: 2))) + override(ls: 1, id: 3, startAt: 7) +
            #"\pard\ls1\ilvl0 x\par"#), schema: schema)
        try expectEqual(d.child(0).attrs["order"], .int(7))
    }

    test("RTF: with no override table, \\ls names the list id directly") {
        let d = try RTFParser.parse(rtf(
            listTable(list(id: 4, level(nfc: 0, startAt: 5))) +
            #"\pard\ls4\ilvl0 x\par"#), schema: schema)
        try expectEqual(d, doc(node("orderedList", ["order": .int(5)], [node("listItem", [:], [p("x")])])))
    }

    test("RTF: a checkbox in the level template makes a task list") {
        let d = try RTFParser.parse(rtf(
            listTable(list(id: 2, level(nfc: 23, text: #"\uc0\u9744 "#))) + override(ls: 1, id: 2) +
            #"\pard\ls1\ilvl0 todo\par\pard\ls1\ilvl0"# + marker(#"\uc0\u9745 "#) + #"done\par"#),
            schema: schema)
        try expectEqual(d, doc(node("taskList", [:], [
            node("taskItem", ["checked": .bool(false)], [p("todo")]),
            node("taskItem", ["checked": .bool(true)], [p("done")]),
        ])))
    }

    test("RTF: the list table outranks a marker that disagrees with it") {
        // Word draws the marker it drew; the table states the format. When they
        // conflict the table is the one that knows.
        let d = try RTFParser.parse(rtf(
            listTable(list(id: 8, level(nfc: 23))) + override(ls: 1, id: 8) +
            #"\pard\ls1\ilvl0"# + marker("1.") + #"x\par"#), schema: schema)
        try expectEqual(d.child(0).type.name, "bulletList")
    }

    test("RTF: a list table naming a list that isn't defined still parses") {
        for body in [override(ls: 1, id: 99) + #"\pard\ls1\ilvl0 x\par"#,
                     listTable(list(id: 1)) + #"\pard\ls1\ilvl9 x\par"#,
                     #"{\*\listtable{\list{\listlevel\levelnfc0}}}\pard\ls1 x\par"#,
                     #"{\*\listoverridetable{\listoverride\ls1}}\pard\ls1 x\par"#] {
            let d = try RTFParser.parse(rtf(body), schema: schema)
            try d.check()
            try expectEqual(d.textContent, "x")
        }
    }

    test("RTF: the list tables are never document text") {
        let d = try RTFParser.parse(rtf(
            listTable(list(id: 1, level(nfc: 0, text: #"\uc0\u8226 "#))) + override(ls: 1, id: 1) +
            #"\pard body\par"#), schema: schema)
        try expectEqual(d, doc(p("body")))
    }

    test("RTF: a tracked deletion isn't document text") {
        let d = try RTFParser.parse(rtf(#"\pard keep \deleted\strike gone\deleted0\strike0  it\par"#), schema: schema)
        try expectEqual(d.textContent, "keep  it")
    }

    test("RTF: a picture written as binary rather than hex still arrives") {
        var bytes = Array(#"{\rtf1\ansi\pard {\pict\pngblip\picw1\pich1\bin69 "#.utf8)
        bytes += pngBytes
        bytes += Array(#"}x\par}"#.utf8)
        let d = try RTFParser.parse(Data(bytes), schema: schema)
        let image = d.child(0).child(0)
        try expectEqual(image.type.name, "image")
        try expect(image.attrs["src"]?.stringValue?.hasPrefix("data:image/png;base64,iVBORw0KGgo") == true,
                   "src was \(String(describing: image.attrs["src"]))")
        try expectEqual(d.child(0).textContent, "x")
    }

    test("RTF: a \\bin payload outside a picture is still skipped whole") {
        let payload = #"\par junk"#
        let d = try RTFParser.parse(rtf(
            #"\pard a{\*\unknown\bin\#(payload.count) \#(payload)}b\par"#), schema: schema)
        try expectEqual(d, doc(p("ab")))
    }

    test("RTF: a HYPERLINK to a bookmark links within the document") {
        let d = try RTFParser.parse(rtf(
            #"\pard {\field{\*\fldinst{HYPERLINK \\l "section2"}}{\fldrslt jump}}\par"#), schema: schema)
        try expectEqual(d, doc(p(marked("jump", mark("link", ["href": .string("#section2")])))))
    }

    test("RTF: a field switch that isn't a link leaves the text unmarked") {
        let d = try RTFParser.parse(rtf(
            #"\pard {\field{\*\fldinst{PAGE \* MERGEFORMAT}}{\fldrslt 7}}\par"#), schema: schema)
        try expectEqual(d, doc(p("7")))
    }

    test("RTF: old-style \\pn numbering says what kind of list it is") {
        let bullet = try RTFParser.parse(rtf(
            #"\pard{\*\pn\pnlvlblt\pnf3\pnindent0{\pntxtb\'b7}}{\pntext\'b7\tab}item\par"#), schema: schema)
        try expectEqual(bullet, doc(node("bulletList", [:], [node("listItem", [:], [p("item")])])))

        let numbered = try RTFParser.parse(rtf(
            #"\pard{\*\pn\pnlvlbody\pndec\pnstart3\pnindent0{\pntxta.}}{\pntext 3.\tab}item\par"#),
            schema: schema)
        try expectEqual(numbered, doc(node("orderedList", ["order": .int(3)],
                                           [node("listItem", [:], [p("item")])])))
    }

    test("RTF: \\pn applies to its own paragraph only") {
        let d = try RTFParser.parse(rtf(
            #"\pard{\*\pn\pnlvlblt}{\pntext\'b7\tab}item\par\pard after\par"#), schema: schema)
        try expectEqual(d, doc(
            node("bulletList", [:], [node("listItem", [:], [p("item")])]),
            p("after")))
    }

    test("RTF: Node.fromRTF matches the parser") {
        let source = rtf(#"\pard hello \b world\b0 \par"#)
        try expectEqual(try Node.fromRTF(source, schema: schema),
                        try RTFParser.parse(source, schema: schema))
        try expectEqual(try Node.fromRTF(Data(source.utf8), schema: schema),
                        try RTFParser.parse(source, schema: schema))
    }

    test("RTF: input that isn't RTF is refused") {
        try expectThrows { _ = try RTFParser.parse("hello", schema: schema) }
        try expectThrows { _ = try RTFParser.parse("<p>hi</p>", schema: schema) }
        try expectThrows { _ = try RTFParser.parse("", schema: schema) }
        try expectThrows { _ = try RTFParser.parse("{\\rtx1}", schema: schema) }
    }

    test("RTF: excessive group nesting throws rather than recursing") {
        let deep = #"{\rtf1\ansi"# + String(repeating: "{", count: 400) + "x"
        do {
            _ = try RTFParser.parse(deep, schema: schema)
            try expect(false, "expected nestingTooDeep")
        } catch let error as RTFParseError {
            guard case .nestingTooDeep = error else {
                try expect(false, "expected nestingTooDeep, got \(error)")
                return
            }
        }
    }

    test("RTF: truncated and unbalanced input still parses") {
        for body in ["{\\rtf1", "{\\rtf1\\ansi", #"{\rtf1\ansi\pard unterminated"#,
                     #"{\rtf1\ansi\pard a}}}}\par b"#, #"{\rtf1\ansi{{{\pard nested"#,
                     #"{\rtf1\ansi\pard \u"#, #"{\rtf1\ansi\pard \'"#, #"{\rtf1\ansi\pard \'z"#,
                     #"{\rtf1\ansi{\pict\pngblip 0"#, #"{\rtf1\ansi\pard \bin999 "#,
                     #"{\rtf1\ansi\pard \li99999999999999999999 x\par"#] {
            let d = try RTFParser.parse(body, schema: schema)
            try d.check()
        }
    }

    test("RTF: arbitrary bytes after the header never trap") {
        // A cheap deterministic sweep: the reader has to survive anything a
        // corrupt clipboard hands it, and every case here has run through the
        // control-word, escape, and group paths.
        var state: UInt64 = 0x5eed
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((state >> 33) & 0xFF)
        }
        let alphabet = Array(#"\{}'bipuc0189 par\'ftablcelrowfldinstpict;"#.unicodeScalars)
        for _ in 0..<300 {
            var body = ""
            for _ in 0..<200 { body.unicodeScalars.append(alphabet[Int(next()) % alphabet.count]) }
            let d = try RTFParser.parse(#"{\rtf1\ansi"# + body, schema: schema)
            try d.check()
        }
    }

    test("RTF: an empty document is one empty paragraph") {
        try expectEqual(try RTFParser.parse(#"{\rtf1\ansi\pard\par}"#, schema: schema), doc(p("")))
    }

    test("RTF: Data and String inputs agree") {
        let source = rtf(#"\pard caf\'e9 \b bold\b0 \par"#)
        let fromString = try RTFParser.parse(source, schema: schema)
        let fromData = try RTFParser.parse(Data(source.utf8), schema: schema)
        try expectEqual(fromString, fromData)
    }

    test("RTF: a schema without lists, tables or code still gets the content") {
        let plain = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "inline*", group: "block")),
            ("text", NodeSpec(group: "inline")),
        ], marks: [], topNode: "doc")
        let d = try RTFParser.parse(rtf(
            #"\pard\ls1\ilvl0"# + marker(#"\uc0\u8226 "#) + #"item\par"# +
            #"\trowd\cellx2880\pard\intbl cell\cell\row"# +
            #"\pard\f1 code\par\pard\b bold\b0 \par"#), schema: plain)
        try d.check()
        try expectEqual(d.textContent, "itemcellcodebold")
    }
}
