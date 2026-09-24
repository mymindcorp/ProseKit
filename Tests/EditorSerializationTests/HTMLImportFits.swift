import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// One regression test per content-loss bug the HTML import property
// (`HTMLImportProperties.swift`) found, each asserting the exact document —
// the property only asks that the words survive, and a wrong shape can keep
// them all. The readings follow ProseMirror's DOM parser: content with no
// place in the open node closes it and lands after it, and an inline element
// around blocks marks their text rather than flattening them.

private func parseHTML(_ s: String, _ sch: Schema = schema) throws -> Node {
    let d = try HTMLParser.parse(s, schema: sch)
    try d.check()
    return d
}

/// The test schema with some content expressions or marks changed,
/// declaration order kept.
private func narrowed(content: [String: String] = [:], marks: [String: String] = [:]) throws -> Schema {
    var specs: [(String, NodeSpec)] = []
    for name in schema.nodeSpecOrder {
        guard var s = schema.nodes[name]?.spec else { continue }
        if let c = content[name] { s.content = c }
        if let m = marks[name] { s.marks = m }
        specs.append((name, s))
    }
    return try Schema(nodes: specs, marks: schema.markSpecOrder.compactMap { n in schema.marks[n].map { (n, $0.spec) } },
                      topNode: "doc")
}

/// `expected`, built with the test schema's helpers, compared with `actual`
/// from another schema: through JSON, since nodes of two schemas never compare
/// equal.
private func expectSameDoc(_ actual: Node, _ expected: Node, file: StaticString = #file, line: UInt = #line) throws {
    try expectEqual(shape(actual), shape(expected), file: file, line: line)
    try expectEqual(actual.toJSON(), expected.toJSON(), file: file, line: line)
}

private func linked(_ s: String, _ href: String) -> Node {
    schema.text(s, [schema.mark("link", ["href": .string(href)])])
}

func registerHTMLImportFitTests() {
    // MARK: An inline element around blocks

    test("html fit: an inline wrapper around paragraphs keeps them separate paragraphs") {
        // Google Docs wraps every copy in this `<b>`; read as one inline run,
        // its paragraphs came back as the single word "onetwo".
        let d = try parseHTML(#"<b style="font-weight:normal" id="docs-internal-guid-x"><p>one</p><p>two</p></b>"#)
        try expectSameDoc(d, doc(p("one"), p("two")))
    }

    test("html fit: a list inside a Google Docs wrapper stays a list") {
        let d = try parseHTML(#"<b style="font-weight:normal;"><ul><li><p>Apples</p></li><ul><li><p>Granny "#
                              + #"Smith</p></li></ul><li><p>Pears</p></li></ul></b>"#)
        try expectSameDoc(d, doc(ul(tight: false,
                                  li(p("Apples"), ul(tight: false, li(p("Granny Smith")))),
                                  li(p("Pears")))))
        // Written that way without the wrapper, too: the sub-list joins the
        // item above it rather than having its items merged into this list.
        try expectSameDoc(try parseHTML("<ol><li>one</li><ul><li>sub</li></ul><li>two</li></ol>"),
                          doc(node("orderedList", ["order": .int(1), "tight": .bool(true)], [
                              li(p("one"), ul(li(p("sub")))), li(p("two"))])))
    }

    test("html fit: a table inside a Google Docs wrapper stays a table") {
        let d = try parseHTML(#"<b style="font-weight:normal;"><div><table><tr><td><p>Name</p></td><td><p>Role</p>"#
                              + #"</td></tr><tr><td><p>Ada</p></td><td><p>Engineer</p></td></tr></table></div></b>"#)
        try expectSameDoc(d, doc(tableN(trN(tdN([:], p("Name")), tdN([:], p("Role"))),
                                      trN(tdN([:], p("Ada")), tdN([:], p("Engineer"))))))
    }

    test("html fit: a link around a card links the text of every block in it") {
        let href = "https://example.test/card"
        let d = try parseHTML(#"<a href="\#(href)"><div><h4>Card title</h4><p>Card body</p></div></a>"#)
        try expectSameDoc(d, doc(node("heading", ["level": .int(4)], [linked("Card title", href)]),
                               p(linked("Card body", href))))
    }

    test("html fit: a wrapper's marks start where it opens and end where it closes") {
        // Text before the wrapper shares its paragraph without its mark; text
        // after the close is plain again.
        let d = try parseHTML("lead <b>bold <p>inside</p> tail</b> after")
        try expectSameDoc(d, doc(p(t("lead "), strong("bold ")), p(strong("inside")), p(strong(" tail"), t(" after"))))
    }

    test("html fit: a wrapper's marks reach the paragraphs inside a list, but not a code block") {
        // The textblock decides what marks it takes; the list around it
        // takes none of its own, and filtering there lost the emphasis.
        let d = try parseHTML("<b><ul><li>x</li></ul><pre>code</pre></b>")
        try expectSameDoc(d, doc(ul(li(p(strong("x")))), node("codeBlock", [:], [t("code")])))
    }

    test("html fit: an aria-hidden inline element around blocks is still dropped whole") {
        let d = try parseHTML(#"<p>shown</p><span aria-hidden="true"><p>HIDDEN</p></span>"#)
        try expectSameDoc(d, doc(p("shown")))
    }

    // MARK: Overflow below the top level

    test("html fit: what a one-paragraph quote can't hold follows it, however deep it sat") {
        // Unwrapping the list finds "x" a place, which fills the quote; the
        // other items used to be dropped because only the quote's direct
        // children could overflow.
        let quote = try narrowed(content: ["blockquote": "paragraph"])
        let d = try parseHTML("<blockquote><ul><li>x</li><li>y</li><li>z</li></ul></blockquote>", quote)
        try expectSameDoc(d, doc(node("blockquote", [:], [p("x")]), ul(tight: false, li(p("y")), li(p("z")))))
    }

    test("html fit: a container that holds nothing doesn't hand everything back out") {
        // Overflow needs something placed first, or a container that can
        // accept nothing would return its content unchanged, forever.
        let d = try parseHTML("<blockquote><p>a</p><p>b</p></blockquote>")
        try expectSameDoc(d, doc(node("blockquote", [:], [p("a"), p("b")])))
    }

    // MARK: Table cells

    test("html fit: a cell's overflow spills into another cell, which keeps no span") {
        let cells = try narrowed(content: ["tableCell": "paragraph"])
        let d = try parseHTML(#"<table><tr><td colspan="2"><p>first</p><p>second</p><p>third</p></td></tr></table>"#,
                              cells)
        try expectSameDoc(d, doc(tableN(trN(tdN(["colspan": .int(2)], p("first")),
                                            tdN([:], p("second")), tdN([:], p("third"))))))
    }

    // MARK: Task items

    test("html fit: a task item that can't hold its nested list is kept, and the nested tasks follow it") {
        let items = try narrowed(content: ["taskItem": "paragraph"])
        let d = try parseHTML(#"<ul data-type="taskList"><li data-type="taskItem" data-checked="false"><p>second "#
                              + #"task</p><ul data-type="taskList"><li data-type="taskItem" data-checked="true"><p>"#
                              + #"nested task</p></li></ul></li></ul>"#, items)
        try expectSameDoc(d, doc(taskListN(taskItemN(false, p("second task")), taskItemN(true, p("nested task")))))
    }

    // MARK: Details

    test("html fit: a details body the schema can't hold as written is fitted, and keeps its summary") {
        // The fallback returned the body alone: the summary's words went.
        let paragraphs = try narrowed(content: ["detailsContent": "paragraph+"])
        let d = try parseHTML("<details><summary>Sum</summary><p>body</p><ul><li>item</li></ul></details>", paragraphs)
        try expectSameDoc(d, doc(details("Sum", [p("body"), p("item")])))
    }

    test("html fit: what a full details body can't hold follows the section") {
        let one = try narrowed(content: ["detailsContent": "paragraph"])
        let d = try parseHTML("<details open><summary>Sum</summary><p>body</p><p>after</p></details>", one)
        try expectSameDoc(d, doc(details("Sum", [p("body")], open: true), p("after")))
    }

    test("html fit: a summary that takes no marks keeps its words, unmarked") {
        let plain = try narrowed(marks: ["detailsSummary": ""])
        let d = try parseHTML("<details><summary>Outer <b>toggle</b></summary><p>x</p></details>", plain)
        try expectSameDoc(d, doc(details("Outer toggle", [p("x")])))
    }

    // MARK: Unwrapped runs

    test("html fit: blocks unwrapped side by side stay separate paragraphs") {
        let paragraphs = try narrowed(content: ["doc": "paragraph+"])
        let d = try parseHTML("<h2>First heading</h2><h3>Second <em>heading</em></h3>", paragraphs)
        try expectSameDoc(d, doc(p("First heading"), p(t("Second "), em("heading"))))
        // Loose items still share one list: they stood side by side as items.
        try expectSameDoc(try parseHTML("<li>a</li><li>b</li>"), doc(ul(tight: false, li(p("a")), li(p("b")))))
    }

    test("html fit: a row after a loose cell joins that cell's table") {
        // As ProseMirror reads it: the table the loose cell opened is still
        // open when the row arrives. This made two tables.
        let d = try parseHTML("<td>a</td><tr><td>b</td></tr><td>c</td>")
        try expectSameDoc(d, doc(tableN(trN(tdN([:], p("a"))), trN(tdN([:], p("b"))), trN(tdN([:], p("c"))))))
    }

    // MARK: Inline content a textblock won't take

    test("html fit: a hard break in a text-only paragraph or heading becomes a space") {
        // The parse threw invalidDocument: the break was never fitted.
        let paragraphs = try narrowed(content: ["paragraph": "text*"])
        try expectSameDoc(try parseHTML("<p>line one<br>line two<br></p>", paragraphs),
                          doc(p("line one line two")))
        let headings = try narrowed(content: ["heading": "text*"])
        try expectSameDoc(try parseHTML("<h1>a <br>b</h1>", headings), doc(h(1, "a b")))
    }

    // MARK: Captions

    test("html fit: a table caption goes above the table, not into a row") {
        let d = try parseHTML("<table><tr><td>a</td></tr><caption>Cap</caption></table>")
        try expectSameDoc(d, doc(p("Cap"), tableN(trN(tdN([:], p("a"))))))
        // A nested table's caption is that table's.
        let nested = try parseHTML("<table><tr><td><table><caption>In</caption><tr><td>b</td></tr></table></td></tr></table>")
        try expectSameDoc(nested, doc(tableN(trN(tdN([:], p("In"), tableN(trN(tdN([:], p("b")))))))))
    }
}

/// A node as a one-line outline with its attributes, for reading a failure.
private func shape(_ n: Node) -> String {
    if n.isText { return (n.text ?? "").debugDescription + (n.marks.isEmpty ? "" : "[" + n.marks.map(\.type.name).joined(separator: ",") + "]") }
    let attrs = n.attrs.filter { if case .null = $0.value { return false }; return true }
        .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    let head = n.type.name + (attrs.isEmpty ? "" : "{" + attrs.joined(separator: " ") + "}")
    let kids = (0 ..< n.childCount).map { shape(n.child($0)) }
    return kids.isEmpty ? head : head + "(" + kids.joined(separator: " ") + ")"
}
