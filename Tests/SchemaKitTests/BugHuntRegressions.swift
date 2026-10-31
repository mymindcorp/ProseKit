import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorSerialization
import SchemaKit
import TestHarness

private let schema = try! Editor(extensions: fullKit()).schema

private func node(_ name: String, _ attrs: Attrs = [:], _ content: [Node] = []) -> Node {
    try! schema.node(name, attrs, content: Fragment.from(content))
}
private func paragraph(_ content: Node...) -> Node { node("paragraph", [:], content) }
private func code(_ text: String) -> Node { node("codeBlock", [:], [schema.text(text)]) }
private func doc(_ blocks: Node...) -> Node { node("doc", [:], blocks) }
private func parse(_ markdown: String) throws -> Node { try MarkdownParser.parse(markdown, schema: schema) }
private func roundTrip(_ d: Node) throws -> Node { try parse(MarkdownSerializer.serialize(d)) }

func registerBugHuntRegressionTests() {
    test("suggestions: Enter with a committed change that can't fold returns") {
        let e = try Editor(extensions: fullKit())
        e.setContent(doc(paragraph(schema.text("abcd"))))
        _ = e.run(toggleSuggestionMode)
        _ = e.run("toggleBulletList")
        _ = e.run(toggleSuggestionMode)
        _ = e.run(splitListItem(e.schema.nodes["listItem"]!))
    }

    test("join: a newline joining into a paragraph becomes a space") {
        let d = doc(paragraph(schema.text("x")), code("a\nb"))
        let tr = Transform(d)
        try tr.join(3)
        try expectEqual(tr.doc.textContent, "xa b")
    }

    test("markdown: CRLF and CR end lines") {
        let d = try parse("# h\r\n\r\npara\r\n\r\n```\r\ncode\r\n```\r\n\r\nend\rlast")
        try expectEqual(d.child(0).type.name, "heading")
        try expectEqual(d.child(0).textContent, "h")
        try expectEqual(d.child(1).textContent, "para")
        try expectEqual(d.child(2).type.name, "codeBlock")
        try expectEqual(d.child(2).textContent, "code")
    }

    test("markdown: a leading BOM doesn't stop the first block") {
        try expectEqual(try parse("\u{FEFF}# x").child(0).type.name, "heading")
    }

    test("markdown: tabs in fenced code survive, at the top level and in a list") {
        try expectEqual(try roundTrip(doc(code("\ta\n\t\tb"))).child(0).textContent, "\ta\n\t\tb")
        let listed = try parse("- ```\n  \ta\n  ```")
        try expectEqual(listed.child(0).textContent, "\ta")
        // Outside a fence a leading tab still indents.
        try expectEqual(try parse("\tcode").child(0).type.name, "codeBlock")
    }

    test("markdown: details tags inside a fence are the code's text") {
        for text in ["</details>\nfoo", "<details>"] {
            let d = doc(node("details", ["open": .bool(false)], [
                node("detailsSummary", [:], [schema.text("s")]),
                node("detailsContent", [:], [code(text)]),
            ]), paragraph(schema.text("after")))
            try expect(try roundTrip(d) == d, "lost: \(text)")
        }
    }

    test("markdown: an HTML block needs the whole tag name") {
        try expectEqual(try parse("<tablet is broken").textContent, "<tablet is broken")
        try expectEqual(try parse("text\n<tablet is broken\nmore").textContent.contains("more"), true)
        try expectEqual(try parse("<tableware> hello").textContent.contains("hello"), true)
        try expect(try parse("<detailsfoo> hello").child(0).type.name != "details")
    }

    test("markdown: one-line details keeps its summary and body") {
        let d = try parse("<details><summary>x</summary>body</details>\n\nafter")
        try expectEqual(d.child(0).type.name, "details")
        try expectEqual(d.child(0).child(0).textContent, "x")
        try expectEqual(d.child(0).child(1).textContent, "body")
        try expectEqual(d.child(1).textContent, "after")
    }

    test("markdown: only the open attribute opens details") {
        try expectEqual(try parse("<details class=\"reopen\">\n</details>").child(0).attrs["open"]?.boolValue, false)
        try expectEqual(try parse("<details open>\n</details>").child(0).attrs["open"]?.boolValue, true)
    }

    test("markdown: pipes in a table's code and math round-trip") {
        for (text, marked) in [("a|b", true), ("a\\|b", true)] where marked {
            let cell = try parse("| h |\n| --- |\n| x |").child(0).child(1).child(0)
            let inline = schema.text(text, [schema.marks["code"]!.create()])
            let d = doc(node("table", [:], [
                try parse("| h |\n| --- |\n| x |").child(0).child(0),
                node("tableRow", [:], [cell.copy(content: Fragment.from([paragraph(inline)]))]),
            ]))
            try expect(try roundTrip(d) == d, "lost: \(text)")
        }
        let math = try parse("| h |\n| --- |\n| $\\|x\\|$ |").child(0).child(1).child(0).child(0).child(0)
        try expectEqual(math.attrs["latex"]?.stringValue, "|x|")
    }

    test("search: text merging across a mark boundary doesn't hide the block") {
        for d in [
            doc(paragraph(schema.text("e", [schema.marks["bold"]!.create()]), schema.text("\u{301} needle"))),
            doc(paragraph(schema.text("🇺", [schema.marks["bold"]!.create()]), schema.text("🇸 needle"))),
        ] {
            let state = EditorState.create(EditorStateConfig(schema: schema, doc: d))
            let matches = SearchQuery(search: "needle").findAll(state)
            try expectEqual(matches.count, 1)
            try expectEqual(d.textBetween(matches[0].from, matches[0].to), "needle")
            try expectEqual(SearchQuery(search: "ne+dle", regexp: true).findAll(state).count, 1)
        }
    }
}
