import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// A handful of prose documents that exercise every node and mark, with tests
// that they parse / round-trip correctly. Uses the shared `schema`, `node`,
// `doc`, `p`, `h`, `t` helpers from main.swift.

private func codeMark(_ s: String) -> Node { schema.text(s, [schema.mark("code")]) }
private func strikeMark(_ s: String) -> Node { schema.text(s, [schema.mark("strike")]) }
private func linkMark(_ s: String, _ href: String) -> Node { schema.text(s, [schema.mark("link", ["href": .string(href)])]) }

private func count(_ doc: Node, _ name: String) -> Int {
    var n = 0
    doc.descendants { node, _, _, _ in if node.type.name == name { n += 1 }; return true }
    return n
}
private func firstNode(_ doc: Node, _ name: String) -> Node? {
    var found: Node?
    doc.descendants { node, _, _, _ in if found == nil, node.type.name == name { found = node }; return true }
    return found
}
private func usesMark(_ doc: Node, _ name: String) -> Bool {
    var found = false
    doc.descendants { node, _, _, _ in if node.marks.contains(where: { $0.type.name == name }) { found = true }; return true }
    return found
}

/// A document that uses every node type and every mark.
private func everythingDocument() -> Node {
    doc(
        h(1, "The Document Object Model"),
        p(t("Plain, "), strong("bold"), t(", "), em("italic"), t(", "), codeMark("code"),
          t(", "), strikeMark("struck"), t(", and a "), linkMark("link", "https://example.com"), t(".")),
        node("blockquote", [:], [p("A quotation, kept as block content.")]),
        node("bulletList", [:], [
            node("listItem", [:], [p("first bullet")]),
            node("listItem", [:], [p("second bullet")]),
        ]),
        node("orderedList", ["order": .int(1)], [
            node("listItem", [:], [p("step one")]),
            node("listItem", [:], [p("step two")]),
        ]),
        node("taskList", [:], [
            node("taskItem", ["checked": .bool(true)], [p("done")]),
            node("taskItem", ["checked": .bool(false)], [p("todo")]),
        ]),
        node("codeBlock", [:], [t("let x = 1\nprint(x)")]),
        node("horizontalRule"),
        p(t("An image "), node("image", ["src": .string("cat.png"), "alt": .string("a cat")]), t(" inline.")),
        p(t("A wiki link "), node("wikiLink", ["target": .string("Home"), "label": .string("home page")]), t(".")),
        p(t("Line one"), node("hardBreak"), t("line two")),
        node("table", [:], [
            node("tableRow", [:], [node("tableHeader", [:], [p("Feature")]), node("tableHeader", [:], [p("State")])]),
            node("tableRow", [:], [node("tableCell", [:], [p("Marks")]), node("tableCell", [:], [p("done")])]),
        ]))
}

func registerProseTests() {
    // The canonical JSON format must round-trip every node + mark losslessly.
    test("prose: the everything-document round-trips through JSON exactly") {
        let original = everythingDocument()
        let restored = try DocumentJSON.decode(schema, DocumentJSON.string(original, pretty: true))
        try expectEqual(original, restored)
        // sanity: it really does use everything
        for name in ["heading", "blockquote", "bulletList", "orderedList", "taskList", "taskItem",
                     "codeBlock", "horizontalRule", "image", "wikiLink", "hardBreak", "table", "tableRow", "tableCell", "tableHeader"] {
            try expect(count(original, name) >= 1, "missing \(name)")
        }
        for mark in ["bold", "italic", "code", "strike", "link"] {
            try expect(usesMark(original, mark), "missing mark \(mark)")
        }
    }

    // A rich Markdown source must parse into the right structure.
    test("prose: comprehensive Markdown parses correctly") {
        let markdown = """
        # Heading One

        A paragraph with **bold**, *italic*, `code`, ~~strike~~, a [link](https://example.com), and a [[WikiPage|wiki]].

        > A blockquote paragraph.

        - bullet one
        - bullet two

        1. step one
        2. step two

        ---

        ```
        let x = 1
        ```
        """
        let parsed = try MarkdownParser.parse(markdown, schema: schema)
        try expectEqual(firstNode(parsed, "heading")?.attrs["level"], .int(1))
        try expect(usesMark(parsed, "bold"))
        try expect(usesMark(parsed, "italic"))
        try expect(usesMark(parsed, "code"))
        try expect(usesMark(parsed, "strike"))
        try expect(usesMark(parsed, "link"))
        try expectEqual(count(parsed, "wikiLink"), 1)
        try expectEqual(count(parsed, "blockquote"), 1)
        try expectEqual(count(parsed, "bulletList"), 1)
        try expectEqual(count(parsed, "listItem"), 4) // 2 bullets + 2 ordered
        try expectEqual(count(parsed, "orderedList"), 1)
        try expectEqual(count(parsed, "horizontalRule"), 1)
        try expectEqual(count(parsed, "codeBlock"), 1)
        try expectEqual(firstNode(parsed, "codeBlock")?.textContent, "let x = 1")
    }

    // A rich HTML source must parse into the right structure.
    test("prose: comprehensive HTML parses correctly") {
        let html = """
        <h2>Subheading</h2>
        <p>Text with <strong>bold</strong>, <em>italic</em>, <code>code</code>, <s>strike</s>, and a <a href="https://x.com">link</a>.</p>
        <blockquote><p>Quoted.</p></blockquote>
        <ul><li><p>a</p></li><li><p>b</p></li></ul>
        <ol><li><p>one</p></li></ol>
        <hr>
        <p>Break<br>here</p>
        <table><tr><th>H</th></tr><tr><td>C</td></tr></table>
        """
        let parsed = try HTMLParser.parse(html, schema: schema)
        try expectEqual(firstNode(parsed, "heading")?.attrs["level"], .int(2))
        try expect(usesMark(parsed, "bold"))
        try expect(usesMark(parsed, "italic"))
        try expect(usesMark(parsed, "code"))
        try expect(usesMark(parsed, "strike"))
        try expect(usesMark(parsed, "link"))
        try expectEqual(count(parsed, "blockquote"), 1)
        try expectEqual(count(parsed, "bulletList"), 1)
        try expectEqual(count(parsed, "orderedList"), 1)
        try expectEqual(count(parsed, "horizontalRule"), 1)
        try expectEqual(count(parsed, "hardBreak"), 1)
        try expectEqual(count(parsed, "table"), 1)
        try expectEqual(count(parsed, "tableHeader"), 1)
        try expectEqual(count(parsed, "tableCell"), 1)
    }

    // Round-trip the lossless subset through HTML.
    test("prose: HTML round-trips the formatting subset") {
        let original = doc(
            h(2, "Title"),
            p(t("a "), strong("b"), t(" "), em("c"), t(" "), codeMark("d"), t(" "), strikeMark("e")),
            node("blockquote", [:], [p("quote")]),
            node("bulletList", [:], [node("listItem", [:], [p("x")]), node("listItem", [:], [p("y")])]),
            node("horizontalRule"))
        let restored = try HTMLParser.parse(HTMLSerializer.serialize(original), schema: schema)
        try expectEqual(original, restored)
    }

    // A wiki-link's `targetId` — the host's own id for the page — is not part of
    // the `[[target|label]]` text, so HTML is where it has to survive.
    test("prose: a wiki-link's targetId round-trips through HTML") {
        let original = doc(p(t("see "), node("wikiLink", ["target": .string("Page"),
                                                         "targetId": .string("3xK9")])))
        let html = HTMLSerializer.serialize(original)
        try expect(html.contains("data-wikilink-id=\"3xK9\""), "id is written: \(html)")
        let restored = try HTMLParser.parse(html, schema: schema)
        try expectEqual(firstNode(restored, "wikiLink")?.attrs["targetId"], .string("3xK9"))
    }

    // Round-trip the lossless subset through Markdown.
    test("prose: Markdown round-trips the formatting subset") {
        let original = doc(
            h(3, "Notes"),
            p(t("see "), linkMark("PM", "https://prosemirror.net"), t(" and "),
              node("wikiLink", ["target": .string("Page")])),
            node("blockquote", [:], [p("quote")]),
            node("orderedList", ["order": .int(1)], [node("listItem", [:], [p("one")]), node("listItem", [:], [p("two")])]),
            node("codeBlock", [:], [t("x = 1")]))
        let restored = try MarkdownParser.parse(MarkdownSerializer.serialize(original), schema: schema)
        try expectEqual(original, restored)
    }
}
