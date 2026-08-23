import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// CommonMark will not open a delimiter run that is followed by whitespace, or
// close one that is preceded by it. A serializer that writes `**foo **bar`
// therefore doesn't write bold text — it writes eleven literal characters, and
// the mark is gone the next time the document is read. The whitespace has to
// move outside the delimiters.
//
// Same shape as the fixes in prosemirror-markdown 1.13.3/1.13.4/1.13.6, though
// this serializer is hand-written rather than a port of theirs.

private func brk() -> Node { node("hardBreak", [:]) }
private func strike(_ s: String) -> Node { schema.text(s, [schema.mark("strike")]) }
private func highlight(_ s: String) -> Node { schema.text(s, [schema.mark("highlight")]) }
private func boldBrk() -> Node {
    try! schema.nodes["hardBreak"]!.create(marks: [schema.mark("bold")])
}

/// Every non-whitespace character of a document paired with the marks on it.
/// Whitespace is left out because moving it across a delimiter is exactly what
/// the serializer is allowed to do.
private func markedText(_ node: Node) -> String {
    var out: [String] = []
    func walk(_ n: Node) {
        if n.isText, let text = n.text {
            let marks = n.marks.map(\.type.name).sorted().joined(separator: "+")
            for ch in text where !ch.isWhitespace { out.append("\(ch)[\(marks)]") }
            return
        }
        for i in 0..<n.childCount { walk(n.child(i)) }
    }
    walk(node)
    return out.joined(separator: " ")
}

func registerMarkdownDelimiterWhitespaceTests() {
    /// Serialize, check the exact Markdown, and check that reading it back
    /// gives the document named — which is the part that actually matters.
    func writes(_ name: String, _ d: Node, _ markdown: String, reads back: Node) {
        test("md whitespace: \(name)") {
            let md = d.toMarkdown().trimmingCharacters(in: .newlines)
            try expectEqual(md, markdown)
            try expectEqual(try MarkdownParser.parse(md, schema: schema), back)
        }
    }

    writes("a mark ending in a space closes before it",
           doc(p(strong("foo "), t("bar"))),
           "**foo** bar",
           reads: doc(p(strong("foo"), t(" bar"))))

    writes("a mark starting with a space opens after it",
           doc(p(t("bar"), strong(" foo"))),
           "bar **foo**",
           reads: doc(p(t("bar "), strong("foo"))))

    writes("a mark padded on both sides",
           doc(p(t("a"), em(" b "), t("c"))),
           "a *b* c",
           reads: doc(p(t("a "), em("b"), t(" c"))))

    // `~~` and `==` are delimiter runs too, but they are deliberately paired
    // without the flanking rules, so whitespace beside one closes it perfectly
    // well. Nothing to expel — and expelling anyway would throw away a space
    // the mark is entitled to hold, which is why this is the one delimiter
    // spelling that keeps it.
    writes("a run paired without the flanking rules keeps its whitespace",
           doc(p(strike("gone "), t("here"))),
           "~~gone ~~here",
           reads: doc(p(strike("gone "), t("here"))))

    writes("the same for a highlight",
           doc(p(t("a"), highlight(" b "), t("c"))),
           "a== b ==c",
           reads: doc(p(t("a"), highlight(" b "), t("c"))))

    // The space is between two bold runs, so the run doesn't end and there is
    // nothing to expel.
    writes("no expulsion when the mark continues past the space",
           doc(p(strong("foo bar"))),
           "**foo bar**",
           reads: doc(p(strong("foo bar"))))

    // A hard break inside a marked run carries the mark like any other inline
    // node, so the run doesn't close at it and there is no delimiter for the
    // space to be stranded against.
    writes("a mark spanning a hard break keeps its space inside",
           doc(p(strong("foo "), boldBrk(), strong("bar"))),
           "**foo \\\nbar**",
           reads: doc(p(strong("foo "), boldBrk(), strong("bar"))))

    // A break that doesn't carry the mark ends the run, and the closing
    // delimiter would land right after the space.
    writes("a mark ending at a hard break expels its space",
           doc(p(strong("foo "), brk(), t("bar"))),
           "**foo** \\\nbar",
           reads: doc(p(strong("foo"), t(" "), brk(), t("bar"))))

    // Markdown has no way to spell a break at the end of a block: a trailing
    // backslash reads back as a literal backslash.
    writes("a hard break at the end of a block is dropped",
           doc(p(t("foo"), brk())),
           "foo",
           reads: doc(p("foo")))

    writes("a run of hard breaks at the end of a block is dropped",
           doc(p(t("foo"), brk(), brk())),
           "foo",
           reads: doc(p("foo")))

    writes("a hard break in the middle survives",
           doc(p(t("foo"), brk(), t("bar"))),
           "foo\\\nbar",
           reads: doc(p(t("foo"), brk(), t("bar"))))

    // Every character of the node is expelled, so there is nothing left to wrap
    // in delimiters — writing `x** **y` would spell no mark at all.
    writes("a mark covering nothing but whitespace writes no delimiters",
           doc(p(t("x"), strong(" "), t("y"))),
           "x y",
           reads: doc(p("x y")))

    // Whitespace held back at the end of a block is dropped rather than
    // written: no parser keeps trailing spaces on a line, and two of them would
    // read back as a hard break.
    writes("trailing whitespace at the end of a block is dropped",
           doc(p(strong("foo  "))),
           "**foo**",
           reads: doc(p(strong("foo"))))

    // Everything above is a paragraph, and `out` is empty when its inline
    // content starts being written. Every other block writes a prefix first —
    // `> `, `- `, `## ` — and pulling whitespace back out of a closing
    // delimiter walks backwards through that same buffer. It must not reach
    // into the prefix. (It cannot: a mark only becomes active once its opening
    // delimiter has been written, and none of `*`, `**`, `~~`, `==` is
    // whitespace, so the walk always stops there. These check it.)
    func inBlock(_ name: String, _ d: Node, _ markdown: String) {
        test("md whitespace: \(name)") {
            let md = d.toMarkdown().trimmingCharacters(in: .newlines)
            try expectEqual(md, markdown)
            try expectEqual(markedText(try MarkdownParser.parse(md, schema: schema)),
                            markedText(d), "marks changed")
        }
    }
    func quote(_ c: Node...) -> Node { node("blockquote", [:], c) }
    func item(_ c: Node...) -> Node { node("bulletList", ["tight": .bool(true)],
                                          [node("listItem", [:], c)]) }

    inBlock("expelled out of a heading, not out of its marker",
            doc(node("heading", ["level": .int(2)], [strong("Ti "), t("tle")])),
            "## **Ti** tle")
    inBlock("expelled out of a quoted paragraph, not out of its marker",
            doc(quote(p(strong("foo "), t("bar")))),
            "> **foo** bar")
    inBlock("expelled out of a list item, not out of its bullet",
            doc(item(p(strong("foo "), t("bar")))),
            "- **foo** bar")
    inBlock("expelled through two levels of block prefix",
            doc(item(quote(p(strong("a "), t("b"))))),
            "- > **a** b")
    inBlock("a whitespace-only mark inside a quote writes no delimiters",
            doc(quote(p(t("x"), strong(" "), t("y")))),
            "> x y")
    inBlock("a trailing hard break inside a quote is dropped",
            doc(quote(p(t("foo"), brk()))),
            "> foo")
    inBlock("a trailing hard break inside a list item is dropped",
            doc(item(p(t("foo"), brk()))),
            "- foo")
    // A table cell is the tightest case: its content is written between pipes,
    // so a walk that overshot would eat the delimiter of the cell itself. (A
    // table needs a header row to be written as pipes at all — without one the
    // serializer falls back to HTML, where there is no flanking rule and the
    // whitespace rightly stays where the document put it.)
    inBlock("expelled inside a table cell, not out through its pipe",
            doc(tableN(trN(thN([:], p(t("h1"))), thN([:], p(t("h2")))),
                       trN(tdN([:], p(strong("foo "), t("bar"))),
                           tdN([:], p(t("x"), strong(" "), t("y")))))),
            "| h1 | h2 |\n| --- | --- |\n| **foo** bar | x y |")

    test("md whitespace: the HTML fallback keeps whitespace inside the mark") {
        // No header row, so this is written as HTML rather than pipes. HTML has
        // no flanking rule — `<strong>foo </strong>` is bold text ending in a
        // space — so nothing should be moved.
        let d = doc(tableN(trN(tdN([:], p(strong("foo "), t("bar"))))))
        try expect(d.toMarkdown().contains("<strong>foo </strong>bar"),
                   "got \(d.toMarkdown())")
    }

    inBlock("a heading of nothing but marked whitespace keeps its marker",
            doc(node("heading", ["level": .int(1)], [strong(" ")])),
            "# ")

    // A link is written as `[text](url)`, which has no flanking rule, so its
    // whitespace stays where the document put it.
    test("md whitespace: a link keeps its own whitespace") {
        let d = doc(p(schema.text("foo ", [schema.mark("link", ["href": .string("u")])]), t("bar")))
        try expectEqual(d.toMarkdown().trimmingCharacters(in: .newlines), "[foo ](u)bar")
    }

    // The whole point, swept over every three-piece paragraph these shapes can
    // make: a delimiter run that dies takes its mark with it, and the mark is
    // gone the next time the document is read. Whitespace is allowed to move
    // across a delimiter — that is the fix — so what has to match is the marks
    // over the text that isn't whitespace.
    func sweep(_ name: String, _ pieces: [Node]) {
        test("md whitespace: no shape of paragraph loses a mark (\(name))") {
            for first in pieces {
                for second in pieces {
                    for third in pieces {
                        let d = doc(p(first, second, third))
                        let md = d.toMarkdown()
                        let back = try MarkdownParser.parse(md, schema: schema)
                        try expectEqual(markedText(back), markedText(d),
                                        "marks changed, written as \(md.debugDescription)")
                    }
                }
            }
        }
    }

    // One sweep over all four spellings. This was two for a while — a strike or
    // a highlight used to be read back as one flat run of text, so nothing
    // nested inside one survived and the second sweep had to steer clear of
    // hard breaks. They pair through the same machinery now, so the awkward
    // contents belong in one list again.
    sweep("every delimiter run", [strong("a "), strong(" a"), strong(" "), strong("a"),
                                  em("b "), em(" b"), em(" "),
                                  strike("c "), strike(" c"), strike("c"),
                                  highlight("d "), highlight(" d"), highlight("d"),
                                  t("x"), t(" x"), t("x "), t(" "), brk(), boldBrk()])
}
