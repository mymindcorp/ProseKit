import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// Corners of the Markdown, HTML, and RTF paths with no test: an image title
// that itself contains a quote, a loose list of one item, a pipe table read
// into a schema with no table nodes, inline HTML with a doctype or unquoted
// attributes, block-level stray text and images, `aria-hidden` wrappers at
// the top level, wiki-link target types, RTF's hyphen controls, and what each
// parser's errors say.
//
// Plus the ones a coverage sweep named: a heading carrying a line break or
// ending in a "#", a hard break caught inside emphasis, a link definition
// written inside a quote, a table whose schema declares the nodes but won't
// hold the shape, and emphasis flanked by non-ASCII punctuation.

private let minimalSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("paragraph", NodeSpec(content: "inline*", group: "block")),
    ("text", NodeSpec(group: "inline")),
])

private func rtf(_ body: String) -> String { "{\\rtf1\\ansi\\deff0 " + body + "}" }

/// `schema` with `dropped` node types removed, for asking what a parser does
/// when the host's schema simply has no such node.
///
/// Rebuilding is the only way to ask: a `Schema` validates its content
/// expressions on construction, so the types that *referred* to the dropped
/// ones have to go with them — dropping `listItem` leaves `bulletList`
/// describing content that can no longer exist.
private func schemaWithout(_ dropped: Set<String>) throws -> Schema {
    var specs: [(String, NodeSpec)] = []
    for name in schema.nodes.keys.sorted() where !dropped.contains(name) {
        guard let type = schema.nodes[name] else { continue }
        let s = type.spec
        // A content expression naming a dropped type would fail to compile, and
        // one naming only dropped types would leave the node uninhabitable.
        if let content = s.content,
           dropped.contains(where: { content.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) {
            continue
        }
        specs.append((name, s))
    }
    var marks: [(String, MarkSpec)] = []
    for name in schema.marks.keys.sorted() {
        if let m = schema.marks[name] { marks.append((name, m.spec)) }
    }
    return try Schema(nodes: specs, marks: marks, topNode: "doc")
}

func registerSerializerEdgeTests() {
    test("every parser: a block the schema has no node for keeps its text") {
        // The schema decides which nodes exist, and a host that ships no
        // `heading` is an ordinary configuration rather than a broken one. What
        // it must not mean is that the words vanish: every build site here sat
        // inside a `textblockSplittingBlocks` wrap closure, `schema.node(_:)`
        // throws for a type the schema doesn't declare, and the closure
        // returning nil dropped the whole run. "# Title" parsed to nothing at
        // all — no heading, and no title either.
        //
        // RTF and the Apple Notes importer already degraded to a paragraph and
        // kept the text, so this only settles Markdown and HTML the same way.
        // The trailing "tail" is the tell: it proves the parse ran and produced
        // a document, so a missing "KEEPME" is a dropped block rather than a
        // thrown error.
        let listTypes: Set<String> = ["bulletList", "orderedList", "listItem"]
        let rtfHead = #"{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Courier New;}}"#
        var lost: [String] = []
        let cases: [(String, Set<String>, String, String, String)] = [
            ("heading", ["heading"],
             "# KEEPME\n\ntail",
             "<h1>KEEPME</h1><p>tail</p>",
             rtfHead + #"\pard\outlinelevel0 KEEPME\par\pard\outlinelevel0\s0 tail\par}"#),
            ("codeBlock", ["codeBlock"],
             "```\nKEEPME\n```\n\ntail",
             "<pre><code>KEEPME</code></pre><p>tail</p>",
             rtfHead + #"\pard\f1 KEEPME\par\pard\f0 tail\par}"#),
            ("lists", listTypes,
             "- KEEPME\n\ntail",
             "<ul><li>KEEPME</li></ul><p>tail</p>",
             rtfHead + #"\pard{\pntext\f0 \'B7\tab}KEEPME\par\pard tail\par}"#),
            // Half a list: the container is gone but `listItem` remains, which
            // is the other side of a guard that needs both. Whatever the items
            // end up wrapped in, the words have to still be there.
            ("bulletList only", ["bulletList"],
             "- KEEPME\n\ntail",
             "<ul><li>KEEPME</li></ul><p>tail</p>",
             rtfHead + #"\pard{\pntext\f0 \'B7\tab}KEEPME\par\pard tail\par}"#),
        ]
        for (label, dropped, md, html, rtfSource) in cases {
            let narrow = try schemaWithout(dropped)
            for name in dropped {
                try expect(narrow.nodes[name] == nil, "\(label): \(name) survived the narrowing")
            }
            let parsers: [(String, () throws -> Node)] = [
                ("markdown", { try MarkdownParser.parse(md, schema: narrow) }),
                ("html", { try HTMLParser.parse(html, schema: narrow) }),
                ("rtf", { try RTFParser.parse(rtfSource, schema: narrow) }),
            ]
            for (parser, parse) in parsers {
                let d = try parse()
                let site = "\(label) missing, \(parser)"
                if !d.textContent.contains("KEEPME") {
                    lost.append("\(site): got \(d.textContent.debugDescription)")
                }
                // The rest of the document has to survive too, and the result
                // has to be a document the editor would accept.
                try expect(d.textContent.contains("tail"), "\(site): the following block was dropped")
                try d.check()
            }
        }
        // Reported together: the same closure returning nil drops a block at
        // every one of these sites, so a fix at one of them says nothing about
        // the others, and stopping at the first would hide five.
        try expect(lost.isEmpty, "blocks dropped:\n  " + lost.joined(separator: "\n  "))
    }

    // MARK: Markdown

    test("md: a hard break followed by a node that writes nothing isn't written") {
        // A break is held back until something follows it, because a `\` at the
        // end of a line reads back as a literal backslash rather than as a
        // break. But it was flushed by the next child that *arrived*, not by
        // the next one that wrote anything — and several inline nodes write
        // nothing: an empty formula, a footnote reference with no label. Every
        // save then added another backslash to the user's text. Found by the
        // serialization fuzz.
        let d = doc(p(t("a"), node("hardBreak"), node("footnoteReference", ["label": .string("")])))
        let md = d.toMarkdown()
        try expect(!md.hasSuffix("\\"), "a trailing hard break was written: \(md.debugDescription)")
        let back = try MarkdownParser.parse(md, schema: schema)
        try expect(!back.textContent.contains("\\"),
                   "a backslash came back as text: \(back.textContent.debugDescription)")
        // A break with real content after it is still a break.
        let kept = doc(p(t("a"), node("hardBreak"), t("b")))
        let keptBack = try MarkdownParser.parse(kept.toMarkdown(), schema: schema)
        try expectEqual(keptBack, kept)
    }

    test("md: a heading carrying a line break is flattened to one line") {
        // A heading is one line by construction, so a break inside its content
        // can't be written as one. A hard break becomes "<br>" — the only
        // spelling that survives — and a bare newline, which a mark spanning a
        // soft wrap can carry in, becomes the space it reads as.
        let broken = doc(node("heading", ["level": .int(1)], [t("a"), node("hardBreak"), t("b")]))
        try expectEqual(broken.toMarkdown(), "# a<br>b")
        let wrapped = doc(node("heading", ["level": .int(1)], [t("a\nb")]))
        try expectEqual(wrapped.toMarkdown(), "# a b")
        // Either way it comes back as a heading rather than as two blocks.
        for d in [broken, wrapped] {
            let back = try MarkdownParser.parse(d.toMarkdown(), schema: schema)
            try expectEqual(back.childCount, 1)
            try expectEqual(back.child(0).type.name, "heading")
        }
    }

    test("md: a heading ending in # escapes the closing run") {
        // "## C#" reads back as a heading of "C": a trailing run of hashes is a
        // closing sequence, not text. Escaping the run keeps the sharp.
        try expectEqual(doc(h(2, "C#")).toMarkdown(), "## C\\#")
        try expectEqual(doc(h(1, "###")).toMarkdown(), "# \\###")
        for text in ["C#", "###", "F# and C#"] {
            let back = try MarkdownParser.parse(doc(h(2, text)).toMarkdown(), schema: schema)
            try expectEqual(back.child(0).textContent, text)
        }
    }

    test("md: a hard break inside emphasis moves out of the closing delimiter") {
        // "*a\<newline>*" closes nothing — a delimiter run preceded by
        // whitespace can't close, and the newline of a break is whitespace. The
        // break has to be expelled past the closer, or the asterisks come back
        // as literal text.
        let italic = schema.mark("italic")
        let d = doc(p(em("a"), node("hardBreak").mark([italic]), t("b")))
        let md = d.toMarkdown()
        try expect(md.hasPrefix("*a*"), "the break stayed inside: \(md.debugDescription)")
        let back = try MarkdownParser.parse(md, schema: schema)
        try expect(!back.textContent.contains("*"),
                   "an asterisk came back as text: \(back.textContent.debugDescription)")
        try expectEqual(back.child(0).childCount, 3)
        try expectEqual(back.child(0).child(1).type.name, "hardBreak")
    }

    test("md: emphasis flanked by non-ASCII punctuation still closes") {
        // Whether a delimiter run may open or close is decided by the character
        // beside it, and "punctuation" there is Unicode's, not ASCII's. Guillemets
        // and a dash are punctuation; the emphasis between them is emphasis.
        for (source, text) in [("«*a*»", "«a»"), ("—*a*—", "—a—"), ("*a*…", "a…")] {
            let back = try MarkdownParser.parse(source, schema: schema)
            try expectEqual(back.textContent, text, source)
            let marked = back.child(0).content.content.filter { !$0.marks.isEmpty }
            try expectEqual(marked.count, 1, source)
            try expectEqual(marked.first?.text, "a", source)
        }
    }

    test("md: a link definition written inside a quote resolves outside it") {
        // A reference resolves against every definition in the document, not
        // only the ones at the top level — the quote is where a footnote-style
        // author tends to park them.
        let d = try MarkdownParser.parse("""
        > [ref]: https://example.test/x "T"

        see [ref]
        """, schema: schema)
        let paragraph = d.child(d.childCount - 1)
        let link = paragraph.child(paragraph.childCount - 1).marks.first
        try expectEqual(link?.type.name, "link")
        try expectEqual(link?.attrs["href"], .string("https://example.test/x"))
        try expectEqual(link?.attrs["title"], .string("T"))
    }

    test("every parser: a mark the schema won't allow in a node is dropped, not fatal") {
        // `create` computes attributes but checks neither content nor marks, so
        // a mark a node's spec forbids only surfaced at the document's own
        // `check()` — and every parser then threw the whole paste away over
        // formatting the schema merely didn't want. `marks: ""` on a heading is
        // an ordinary thing for a host to ask for; the standard code block here
        // already asks for it. Keep the words, lose the emphasis.
        func narrowed(_ node: String, _ marks: String) throws -> Schema {
            var specs: [(String, NodeSpec)] = []
            for name in schema.nodes.keys.sorted() {
                guard let t = schema.nodes[name] else { continue }
                let s = t.spec
                specs.append((name, NodeSpec(content: s.content, marks: name == node ? marks : s.marks,
                                             group: s.group, inline: s.inline, atom: s.atom, attrs: s.attrs,
                                             selectable: s.selectable, draggable: s.draggable, code: s.code,
                                             defining: s.defining, isolating: s.isolating, leafText: s.leafText)))
            }
            var marksList: [(String, MarkSpec)] = []
            for name in schema.marks.keys.sorted() {
                if let m = schema.marks[name] { marksList.append((name, m.spec)) }
            }
            return try Schema(nodes: specs, marks: marksList, topNode: "doc")
        }
        let plainHeadings = try narrowed("heading", "")
        let boldOnlyParagraphs = try narrowed("paragraph", "bold")
        let rtfHeader = #"{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Courier New;}}"#

        let cases: [(String, Schema, String, (String, Schema) throws -> Node, String)] = [
            ("md heading+bold", plainHeadings, "# **bold** title",
             { try MarkdownParser.parse($0, schema: $1) }, "bold title"),
            ("md heading+link", plainHeadings, "# [x](https://e.test)",
             { try MarkdownParser.parse($0, schema: $1) }, "x"),
            ("md heading+code", plainHeadings, "# `c` title",
             { try MarkdownParser.parse($0, schema: $1) }, "c title"),
            ("md para+italic", boldOnlyParagraphs, "*it* plain",
             { try MarkdownParser.parse($0, schema: $1) }, "it plain"),
            ("html h1+strong", plainHeadings, "<h1><strong>b</strong> t</h1>",
             { try HTMLParser.parse($0, schema: $1) }, "b t"),
            ("html p+em", boldOnlyParagraphs, "<p><em>i</em> plain</p>",
             { try HTMLParser.parse($0, schema: $1) }, "i plain"),
            ("rtf heading+bold", plainHeadings, rtfHeader + #"\pard\outlinelevel0 \b bold\b0  title\par}"#,
             { try RTFParser.parse($0, schema: $1) }, "bold title"),
            ("rtf para+italic", boldOnlyParagraphs, rtfHeader + #"\pard \i it\i0  plain\par}"#,
             { try RTFParser.parse($0, schema: $1) }, "it plain"),
        ]
        for (name, narrow, source, parse, text) in cases {
            let d = try parse(source, narrow)
            try d.check()   // the point: a document the schema accepts
            try expectEqual(d.textContent, text, "\(name): the text didn't survive")
            // `check()` above is what proves the forbidden mark is gone: a
            // node's type validates the marks of its children. What it can't
            // prove is that the case had a mark to lose in the first place, so
            // parse it again with the full schema and insist one survives there.
            let full = try parse(source, schema)
            try full.check()
            var marks: [String] = []
            func walk(_ n: Node) {
                marks.append(contentsOf: n.marks.map(\.type.name))
                for i in 0 ..< n.childCount { walk(n.child(i)) }
            }
            walk(full)
            try expect(!marks.isEmpty, "\(name): no mark even with the full schema — the case proves nothing")
        }
    }

    test("md: an indented </details> closes its own block, not the one around it") {
        // The `<details>` scan counted its depth off the *trimmed* line, so a
        // closing tag belonging to a nested block — one indented four columns
        // as a footnote's continuation — closed the outer section instead. The
        // section's real `</details>` was then left over as literal text, and
        // since the serializer writes that text back out escaped, every save
        // added another one. A document that grows by ten characters each time
        // it is written is the kind of thing nobody notices until it is large.
        //
        // Found by the round-trip fuzz at PROSEKIT_FUZZ_DOCS=1000, seed 986.
        let source = """
        <details>
        <summary>o</summary>

        [^n]: <details>
            <summary>s</summary>

            b

            </details>

        </details>
        """
        let once = try MarkdownParser.parse(source, schema: schema)
        try once.check()
        try expectEqual(once.childCount, 1, "a stray block was left outside the section")
        try expectEqual(once.child(0).type.name, "details")
        try expect(!once.textContent.contains("</details>"),
                   "a closing tag came back as text: \(once.textContent.debugDescription)")

        // And it settles: four passes, same document and the same size every
        // time, which is the property the growth broke.
        var doc = once
        var markdown = MarkdownSerializer.serialize(doc)
        for pass in 1 ... 4 {
            let next = try MarkdownParser.parse(markdown, schema: schema)
            try expectEqual(next, doc, "the document changed on pass \(pass)")
            try expectEqual(next.textContent.count, once.textContent.count,
                            "the document grew on pass \(pass)")
            doc = next
            markdown = MarkdownSerializer.serialize(doc)
        }
    }

    test("md: a quote the schema can't hold degrades instead of failing the parse") {
        // Parsing must either produce a valid document or fail with a *parse*
        // error. It must never build a document that fails its own `check()` —
        // that throws the whole paste away rather than degrading the one block
        // it couldn't hold. The quote was the last block here that did: it was
        // built unchecked, so a schema whose blockquote takes paragraphs only
        // got an invalid quote and lost the entire document. The HTML parser
        // already degraded on the same input.
        let quotesParagraphsOnly: Schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "inline*", group: "block")),
            ("heading", NodeSpec(content: "inline*", group: "block",
                                 attrs: ["level": AttributeSpec(default: .int(1))], defining: true)),
            ("blockquote", NodeSpec(content: "paragraph+", group: "block", defining: true)),
            ("bulletList", NodeSpec(content: "listItem+", group: "block")),
            ("listItem", NodeSpec(content: "paragraph block*", defining: true)),
            ("codeBlock", NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true)),
            ("horizontalRule", NodeSpec(group: "block")),
            ("text", NodeSpec(group: "inline")),
        ])
        let cases: [(String, String, String)] = [
            ("heading", "> # Title\n>\n> body", "Title"),
            ("list", "> - a\n> - b", "a"),
            ("code", "> ```\n> x\n> ```", "x"),
            ("nested quote", "> > deep", "deep"),
            ("rule", "> ---\n>\n> after", "after"),
        ]
        for (name, source, keeps) in cases {
            let d = try MarkdownParser.parse(source, schema: quotesParagraphsOnly)
            try d.check()   // the point: it is a document the schema accepts
            try expect(d.textContent.contains(keeps),
                       "\(name): lost the quote's content — \(d.textContent.debugDescription)")
        }
        // With a schema that *can* hold them, they stay inside the quote.
        for (_, source, _) in cases {
            let d = try MarkdownParser.parse(source, schema: schema)
            try d.check()
            try expectEqual(d.child(0).type.name, "blockquote", source.debugDescription)
        }
    }

    test("md: a pipe table the schema declares but can't hold reads as paragraphs") {
        // The nodes exist, so the table branch is entered — but this schema's
        // row won't take a header cell, so the table can't be built. The lines
        // are then what they look like: paragraphs, not a swallowed table.
        let noHeaderRows: Schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "inline*", group: "block")),
            ("text", NodeSpec(group: "inline")),
            ("table", NodeSpec(content: "tableRow+", group: "block", isolating: true)),
            ("tableRow", NodeSpec(content: "tableCell+")),
            ("tableCell", NodeSpec(content: "block+", isolating: true)),
            ("tableHeader", NodeSpec(content: "block+", isolating: true)),
        ])
        let d = try MarkdownParser.parse("| a | b |\n| - | - |\n| c | d |", schema: noHeaderRows)
        try d.check()
        try expect(!(0..<d.childCount).contains { d.child($0).type.name == "table" },
                   "a table was built anyway")
        try expect(d.textContent.contains("a"), "the header row was dropped: \(d.textContent)")
        try expect(d.textContent.contains("d"), "the body row was dropped: \(d.textContent)")
    }

    test("md: a mention is exported as its name rather than dropped") {
        // Markdown has no mention, so this is lossy by nature — it comes back
        // as the text it looks like. Writing nothing was lossier: `@jane` is
        // something a person typed, and an export that drops it leaves a hole
        // in the sentence.
        let d = doc(p(t("hi "), node("mention", ["id": .string("u1"), "label": .string("jane")])))
        try expect(d.toMarkdown().contains("@jane"), "got: \(d.toMarkdown())")
        // With no label it falls back to the id, rather than to a bare "@" —
        // which is not a mention on the way back, it is an at-sign in a
        // sentence.
        let bare = doc(p(node("mention", ["id": .string("u1"), "label": .string("")])))
        try expect(bare.toMarkdown().contains("@u1"), "got: \(bare.toMarkdown())")
    }

    test("md: an image title containing a double quote is written in single quotes") {
        let d = doc(p(node("image", ["src": .string("a.png"), "alt": .string("x"), "title": .string("say \"hi\"")])))
        let md = d.toMarkdown()
        try expect(md.contains("![x](a.png 'say \"hi\"')"), "got: \(md)")
        let back = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(back, d)
    }

    test("md: a loose list with a single item stays loose through a round trip") {
        let d = doc(ol(tight: false, li(p("only"))))
        let md = d.toMarkdown()
        let back = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(back, d, "reserialized as:\n\(md)")
        let bullets = doc(ul(tight: false, li(p("only"))))
        try expectEqual(try MarkdownParser.parse(bullets.toMarkdown(), schema: schema), bullets)
    }

    test("md: a pipe table read into a schema without tables is ordinary text") {
        let md = "| a | b |\n|---|---|\n| 1 | 2 |"
        let d = try MarkdownParser.parse(md, schema: minimalSchema)
        try expect(d.textContent.contains("| a | b |"), "got: \(d.textContent)")
        try expectEqual(d.child(0).type.name, "paragraph")
    }

    test("md: inline HTML with unquoted attributes and a doctype is still read") {
        let d = try MarkdownParser.parse("pic <img src=a.png alt=cat> here", schema: schema)
        var image: Node?
        d.descendants { n, _, _, _ in if n.type.name == "image" { image = n }; return image == nil }
        try expectEqual(image?.attrs["src"], .string("a.png"))
        try expectEqual(image?.attrs["alt"], .string("cat"))
        let declared = try MarkdownParser.parse("<!DOCTYPE html>\n\nafter", schema: schema)
        try expect(declared.textContent.contains("after"))
    }

    test("md: the parser's errors describe themselves") {
        try expect("\(MarkdownParseError.nestingTooDeep(limit: 3))".contains("3"))
        try expect("\(MarkdownParseError.invalidDocument("why"))".contains("why"))
    }

    // MARK: HTML

    test("html: stray text at the top level becomes a paragraph, and blank text is dropped") {
        let d = try HTMLParser.parse("just text", schema: schema)
        try expectEqual(d, doc(p("just text")))
        let blank = try HTMLParser.parse("   \n  <p>x</p>", schema: schema)
        try expectEqual(blank, doc(p("x")))
    }

    test("html: an image at the top level is kept") {
        let d = try HTMLParser.parse("<img src=\"a.png\" alt=\"x\">", schema: schema)
        var image: Node?
        d.descendants { n, _, _, _ in if n.type.name == "image" { image = n }; return image == nil }
        try expectEqual(image?.attrs["src"], .string("a.png"))
    }

    test("html: an aria-hidden wrapper at the top level is skipped") {
        let d = try HTMLParser.parse("<span aria-hidden=\"true\"><p>hidden</p></span><p>shown</p>", schema: schema)
        try expectEqual(d.textContent, "shown")
    }

    test("html: a wiki link's target type is written and read back") {
        let link = node("wikiLink", ["text": .string("Home"), "targetId": .string("42"), "targetType": .string("Note")])
        let d = doc(p(link))
        let html = HTMLSerializer.serialize(d)
        try expect(html.contains("data-wikilink-id=\"42\""), "got: \(html)")
        try expect(html.contains("data-wikilink-type=\"Note\""), "got: \(html)")
        let back = try HTMLParser.parse(html, schema: schema)
        var found: Node?
        back.descendants { n, _, _, _ in if n.type.name == "wikiLink" { found = n }; return found == nil }
        try expectEqual(found?.attrs["targetType"], .string("Note"))
        try expectEqual(found?.attrs["targetId"], .string("42"))
    }

    test("html: an empty parse is an empty paragraph, not an empty document") {
        // `doc` is `block+`, so a paste that yields nothing has to become
        // something — a document with no children wouldn't pass its own check.
        for html in ["", "   ", "<!-- just a comment -->", "<style>.a{}</style>"] {
            let d = try HTMLParser.parse(html, schema: schema)
            try d.check()
            try expectEqual(d.childCount, 1, html.debugDescription)
            try expectEqual(d.child(0).type.name, "paragraph", html.debugDescription)
            try expectEqual(d.textContent, "", html.debugDescription)
        }
    }

    test("html: the parser's errors describe themselves") {
        try expect("\(HTMLParseError.nestingTooDeep(depth: 9, limit: 8))".contains("9"))
        try expect("\(HTMLParseError.invalidDocument("why"))".contains("why"))
    }

    test("html: the benchmark's token count sees every tag") {
        try expectEqual(HTMLParser.tokenCountForBenchmark("<p>a</p><p>b</p>"), 6)
    }

    // MARK: RTF

    test("rtf: a narrow schema keeps the content of blocks it can't build") {
        // The RTF on the pasteboard doesn't know what the host's schema holds.
        // A code block, a heading and a table all have to survive as the text
        // they are made of. Each case is checked against the full schema too,
        // so it pins the degradation rather than passing for both.
        let fonts = #"{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Courier New;}}"#
        let codeSource = fonts + #"\pard\f1 let x = 1\par\pard\f1 let y = 2\par}"#
        try expectEqual(try RTFParser.parse(codeSource, schema: schema).child(0).type.name, "codeBlock")
        let code = try RTFParser.parse(codeSource, schema: minimalSchema)
        try code.check()
        try expectEqual(code.childCount, 2)
        try expectEqual(code.child(0).type.name, "paragraph")
        try expectEqual(code.child(0).textContent, "let x = 1")
        try expectEqual(code.child(1).textContent, "let y = 2")

        let headingSource = rtf(#"\pard\outlinelevel1 Sub\par\pard Body\par"#)
        try expectEqual(try RTFParser.parse(headingSource, schema: schema).child(0).type.name, "heading")
        let heading = try RTFParser.parse(headingSource, schema: minimalSchema)
        try heading.check()
        try expectEqual(heading.child(0).type.name, "paragraph")
        try expectEqual(heading.textContent, "SubBody")

        let tableSource = rtf(
            #"\trowd\trhdr\cellx2880\cellx5760\pard\intbl A\cell\pard\intbl B\cell\row"# +
            #"\trowd\cellx2880\cellx5760\pard\intbl C\cell\pard\intbl D\cell\row\pard end\par"#)
        try expectEqual(try RTFParser.parse(tableSource, schema: schema).child(0).type.name, "table")
        let table = try RTFParser.parse(tableSource, schema: minimalSchema)
        try table.check()
        try expect(!(0..<table.childCount).contains { table.child($0).type.name == "table" },
                   "a table was built in a schema without one")
        for cell in ["A", "B", "C", "D", "end"] {
            try expect(table.textContent.contains(cell), "lost \(cell): \(table.textContent)")
        }
    }

    test("rtf: the hyphen controls — non-breaking kept, optional dropped, and a non-breaking space") {
        let d = try RTFParser.parse(rtf("\\pard a\\_b\\-c\\~d\\par"), schema: schema)
        try expectEqual(d.textContent, "a\u{2011}bc\u{00A0}d")
    }

    test("rtf: the parser's errors describe themselves") {
        try expectThrows { _ = try RTFParser.parse("not rtf at all", schema: schema) }
        try expect("\(RTFParseError.notRTF)".contains("RTF"))
        try expect("\(RTFParseError.nestingTooDeep(depth: 5, limit: 4))".contains("5"))
        try expect("\(RTFParseError.invalidDocument("why"))".contains("why"))
    }
}
