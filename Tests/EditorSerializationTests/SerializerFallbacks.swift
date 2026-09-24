import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// The fallbacks each parser and serializer takes when the input, or the schema
// it is given, doesn't have the shape the main path expects: a node the schema
// lacks, a node the schema has but won't take this content, markup cut off
// mid-tag, and the nodes the Markdown writer has no dedicated spelling for.
// A coverage sweep named every one of these as never run.

/// Prose and nothing else — no marks, no headings, no disclosure sections.
private let bareSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("paragraph", NodeSpec(content: "inline*", group: "block")),
    ("text", NodeSpec(group: "inline")),
], marks: [])

/// A document that may be empty, so a parser's own "at least one paragraph"
/// fallback is what decides the result rather than the content expression.
private let emptyableSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block*")),
    ("paragraph", NodeSpec(content: "inline*", group: "block")),
    ("text", NodeSpec(group: "inline")),
], marks: [])

/// Block-level images, a textblock the Markdown writer has never heard of, and
/// table cells that may be empty.
private let blockImageSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("paragraph", NodeSpec(content: "inline*", group: "block")),
    ("callout", NodeSpec(content: "inline*", group: "block")),
    ("image", NodeSpec(group: "block", atom: true,
                       attrs: ["src": AttributeSpec(), "alt": AttributeSpec(default: .null),
                               "title": AttributeSpec(default: .null)])),
    ("text", NodeSpec(group: "inline")),
    ("table", NodeSpec(content: "tableRow+", group: "block")),
    ("tableRow", NodeSpec(content: "(tableCell | tableHeader)+")),
    ("tableCell", NodeSpec(content: "block*")),
    ("tableHeader", NodeSpec(content: "block*")),
], marks: [])

/// Nodes that exist but are narrower than what RTF describes: a heading that
/// takes plain text only, and a table cell that holds exactly one paragraph.
private let narrowSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("paragraph", NodeSpec(content: "inline*", group: "block")),
    ("heading", NodeSpec(content: "text*", group: "block",
                         attrs: ["level": AttributeSpec(default: .int(1))])),
    ("text", NodeSpec(group: "inline")),
    ("hardBreak", NodeSpec(group: "inline", inline: true)),
    ("table", NodeSpec(content: "tableRow+", group: "block")),
    ("tableRow", NodeSpec(content: "tableCell+")),
    ("tableCell", NodeSpec(content: "paragraph")),
], marks: [])

private func build(_ s: Schema, _ type: String, _ attrs: Attrs = [:], _ content: [Node] = []) throws -> Node {
    try s.node(type, attrs, content: Fragment.from(content))
}

private let fallbackRTFHeader =
    #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Courier New;}}"#

func registerSerializerFallbackTests() {
    // MARK: HTML

    test("HTML: an aria-hidden block is dropped along with what it holds") {
        // KaTeX's visual copy of a formula, as a block rather than a span. The
        // MathML beside it is the formula; the glyph soup is not text.
        let d = try HTMLParser.parse("<p>a</p><div aria-hidden=\"true\">junk</div><p>b</p>", schema: schema)
        try expectEqual(d, doc(p("a"), p("b")))
    }

    test("HTML: a figcaption with no figure around it keeps its words") {
        // A caption can't open a figure (the figure's content starts with a
        // block), so nothing wraps it — but its text still fits once unwrapped.
        let d = try HTMLParser.parse("<figcaption>cap</figcaption>", schema: schema)
        try expectEqual(d, doc(p("cap")))
    }

    test("HTML: an empty document is one empty paragraph even where none is required") {
        try expectEqual(try HTMLParser.parse("", schema: emptyableSchema),
                        try build(emptyableSchema, "doc", [:], [try build(emptyableSchema, "paragraph")]))
        try expectEqual(try HTMLParser.parse("<!-- nothing -->", schema: emptyableSchema).childCount, 1)
    }

    test("HTML: empty containers are filled rather than dropped") {
        try expectEqual(try HTMLParser.parse("<table><tr><td></td></tr></table>", schema: schema),
                        doc(tableN(trN(tdN([:], p(""))))))
        try expectEqual(try HTMLParser.parse("<blockquote></blockquote>", schema: schema),
                        doc(node("blockquote", [:], [p("")])))
        try expectEqual(try HTMLParser.parse("<ul></ul>", schema: schema),
                        doc(node("bulletList", tightList, [node("listItem", [:], [p("")])])))
    }

    test("HTML: an empty task item keeps its checked state") {
        let d = try HTMLParser.parse(#"<ul data-type="taskList"><li data-checked="true"></li></ul>"#, schema: schema)
        try expectEqual(d, doc(taskListN(taskItemN(true, p("")))))
    }

    test("HTML: a sub-list outside any <li> isn't read as the task list's own items") {
        // Malformed, but real: a `<ul>` directly inside another. Its item is
        // not this checklist's item, so it mustn't come back as a task.
        let d = try HTMLParser.parse(
            #"<ul data-type="taskList"><li data-checked="true">a</li><ul><li>b</li></ul></ul>"#, schema: schema)
        let list = d.child(0)
        try expectEqual(list.type.name, "taskList")
        try expectEqual(list.childCount, 1)
        try expectEqual(list.child(0), taskItemN(true, p("a")))
    }

    test("HTML colgroup: a style without a width falls back to the width attribute") {
        let d = try HTMLParser.parse(
            #"<table><colgroup><col style="background: red; border: 0" width="80"></colgroup><tr><td>a</td></tr></table>"#,
            schema: schema)
        try expectEqual(d, doc(tableN(trN(tdN(["colwidth": .array([.int(80)])], p("a"))))))
    }

    test("HTML: a MathML closing tag with no opener is skipped, not read as content") {
        let d = try HTMLParser.parse("<p>a <math><mi>x</mi></mn><mo>+</mo><mn>1</mn></math></p>", schema: schema)
        try expectEqual(d, doc(p(t("a "), inlineMath("x+1"))))
    }

    // MARK: JSON

    test("JSON: a Foundation value with no JSON spelling is refused") {
        // `attributeValue(from:)` takes Foundation's tree, and a caller can hand
        // it anything — a Date is the likeliest.
        try expectThrows { _ = try DocumentJSON.attributeValue(from: Date()) }
        try expectThrows { _ = try DocumentJSON.attributeValue(from: ["ok": 1, "bad": Data()] as [String: Any]) }
    }

    // MARK: Apple Notes

    test("Notes proto doc: a title line in a schema without headings is a paragraph") {
        // Note { 2: text, 5: AttributeRun { 1: length, 2: ParagraphStyle { 1: style } } }
        let text = Array("Title\n".utf8)
        let style: [UInt8] = [0x08, 0x00]               // style 0: title
        let run: [UInt8] = [0x08, 0x06, 0x12, UInt8(style.count)] + style
        let data = Data([0x12, UInt8(text.count)] + text + [0x2a, UInt8(run.count)] + run)
        let d = AppleNotesPasteboard.parseNoteDocument(data, schema: bareSchema)
        try expectEqual(d, try build(bareSchema, "doc", [:], [
            try build(bareSchema, "paragraph", [:], [bareSchema.text("Title")])]))
    }

    // MARK: Markdown out

    test("md: a block-level image writes its title too") {
        let s = blockImageSchema
        let image = try build(s, "image", ["src": .string("a.png"), "alt": .string("x"),
                                           "title": .string("say \"hi\"")])
        let d = try build(s, "doc", [:], [image])
        let markdown = MarkdownSerializer.serialize(d)
        try expectEqual(markdown, "![x](a.png 'say \"hi\"')")
        try expectEqual(try MarkdownParser.parse(markdown, schema: s), d)
    }

    test("md: a textblock with no Markdown spelling writes as its inline content") {
        let s = blockImageSchema
        let d = try build(s, "doc", [:], [try build(s, "callout", [:], [s.text("hi *there*")])])
        // The text is still escaped: it comes back as the words, not as emphasis.
        let markdown = MarkdownSerializer.serialize(d)
        try expectEqual(markdown, "hi \\*there\\*")
        try expectEqual(try MarkdownParser.parse(markdown, schema: s).textContent, "hi *there*")
    }

    test("md: an empty table cell is an empty column, not a reason to give up on pipes") {
        let s = blockImageSchema
        let para = { (text: String) in try build(s, "paragraph", [:], [s.text(text)]) }
        let d = try build(s, "doc", [:], [try build(s, "table", [:], [
            try build(s, "tableRow", [:], [try build(s, "tableHeader", [:], [try para("h")]), try build(s, "tableHeader")]),
            try build(s, "tableRow", [:], [try build(s, "tableCell"), try build(s, "tableCell", [:], [try para("b")])]),
        ])])
        let markdown = MarkdownSerializer.serialize(d)
        try expect(!markdown.contains("<table"), "fell back to HTML:\n\(markdown)")
        try expectEqual(markdown.split(separator: "\n").count, 3, markdown)
        try expect(markdown.hasPrefix("| h |"), markdown)
    }

    test("md: a hard break at the end of emphasis moves outside the closing run") {
        // `**a\` + newline + `**b` would leave the closing `**` after a line
        // break, where it closes nothing.
        let br = node("hardBreak").mark([schema.mark("bold")])
        let d = doc(p(strong("a"), br, t("b")))
        let markdown = MarkdownSerializer.serialize(d)
        try expectEqual(markdown, "**a**\\\nb")
        try expectEqual(try MarkdownParser.parse(markdown, schema: schema), doc(p(strong("a"), node("hardBreak"), t("b"))))
    }

    test("md: a hard break already written moves outside the run it ends") {
        // A break is normally held until something follows it, but a node that
        // writes nothing (an unlabelled footnote reference) flushes it without
        // adding anything — so when the bold then closes, the break is already
        // in the output and has to be taken back out from under the `**`.
        let bold = [schema.mark("bold")]
        let d = doc(p(strong("a"), node("hardBreak").mark(bold), footnoteRef("").mark(bold), t("b")))
        let markdown = MarkdownSerializer.serialize(d)
        try expectEqual(markdown, "**a**\\\nb")
        try expectEqual(try MarkdownParser.parse(markdown, schema: schema), doc(p(strong("a"), node("hardBreak"), t("b"))))
    }

    test("md: emphasis on a non-ASCII symbol inside a word is written as tags") {
        // `a**€**b`: the run before `€` follows a letter and precedes a symbol,
        // which CommonMark counts as punctuation, so it can't open. Tags can.
        for symbol in ["€", "“q”"] {
            let d = doc(p(t("a"), strong(symbol), t("b")))
            let markdown = MarkdownSerializer.serialize(d)
            try expectEqual(markdown, "a<strong>\(symbol)</strong>b")
            try expectEqual(try MarkdownParser.parse(markdown, schema: schema), d)
        }
    }

    // MARK: Markdown in

    test("md: a <details> block in a schema without one keeps its summary and body") {
        let d = try MarkdownParser.parse("<details>\n<summary>Hi *there*</summary>\n\nbody\n\n</details>",
                                         schema: bareSchema)
        try expectEqual(d, try build(bareSchema, "doc", [:], [
            try build(bareSchema, "paragraph", [:], [bareSchema.text("Hi there")]),
            try build(bareSchema, "paragraph", [:], [bareSchema.text("body")]),
        ]))
    }

    test("md: inline HTML cut off before its '>' is text") {
        // Including where a ">" further on makes it look like a tag at first:
        // one inside a quoted attribute value, and one that isn't a comment's.
        for source in ["a <span foo", "a <span title=x", "a<sub>b", "a <!-- b",
                       "a <span title=\"x>\"", "a <!-- b > c"] {
            try expectEqual(try MarkdownParser.parse(source, schema: schema), doc(p(source)), source)
        }
    }

    test("md: a strike or highlight run of one character pairs with nothing") {
        // `~~` and `==` only mean something doubled; a lone closer is text.
        for source in ["~~a~ b", "==a= b"] {
            try expectEqual(try MarkdownParser.parse(source, schema: schema), doc(p(source)), source)
        }
        // And so is the one character a longer closing run has left over once
        // it has spent two on the pair.
        try expectEqual(try MarkdownParser.parse("~~a~~~ b", schema: schema),
                        doc(p(schema.text("a", [schema.mark("strike")]), t("~ b"))))
        try expectEqual(try MarkdownParser.parse("==a=== b", schema: schema),
                        doc(p(schema.text("a", [schema.mark("highlight")]), t("= b"))))
    }

    test("md: an empty code block in a schema without one is an empty paragraph") {
        let empty = try build(bareSchema, "doc", [:], [try build(bareSchema, "paragraph")])
        try expectEqual(try MarkdownParser.parse("```\n```", schema: bareSchema), empty)
        try expectEqual(try HTMLParser.parse("<pre></pre>", schema: bareSchema), empty)
    }

    test("md: an image's alt text keeps the words of the inline nodes in its label") {
        // Alt text is what the label renders to, and a formula or wiki link
        // renders to its own text rather than to nothing.
        let math = try MarkdownParser.parse("![area $x^2$ m](a.png)", schema: schema)
        try expectEqual(math.child(0).child(0).attrs["alt"], .string("area $x^2$ m"))
        let wiki = try MarkdownParser.parse("![a [[Page]] b](a.png)", schema: schema)
        try expectEqual(wiki.child(0).child(0).attrs["alt"], .string("a Page b"))
    }

    // MARK: RTF

    test("RTF: a heading its schema can't hold becomes a paragraph, break and all") {
        // This heading takes text only, so a `\line` inside it has no place —
        // the words and the break go to a paragraph instead.
        let d = try RTFParser.parse(fallbackRTFHeader + #"\pard\outlinelevel0 A\line B\par}"#, schema: narrowSchema)
        try expectEqual(d, try build(narrowSchema, "doc", [:], [try build(narrowSchema, "paragraph", [:], [
            narrowSchema.text("A"), try build(narrowSchema, "hardBreak"), narrowSchema.text("B"),
        ])]))
    }

    test("RTF: a table none of whose cells fit the schema keeps the cells' text") {
        // Two paragraphs in one cell, where a cell holds exactly one.
        let d = try RTFParser.parse(fallbackRTFHeader + #"\trowd\cellx2000\pard\intbl one\par two\cell\row}"#,
                                    schema: narrowSchema)
        try expectEqual(d, try build(narrowSchema, "doc", [:], [
            try build(narrowSchema, "paragraph", [:], [narrowSchema.text("one")]),
            try build(narrowSchema, "paragraph", [:], [narrowSchema.text("two")]),
        ]))
    }
}
