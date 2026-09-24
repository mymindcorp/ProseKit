import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// Cases a mutation pass over the HTML importer (`HTML.swift`'s parser and
// `StructuralCoercion.swift`) found missing. Each pins a behaviour that a
// flipped condition, a deleted fallback or a widened check broke without any
// other test noticing, and each asserts the exact document parsed — a round
// trip or a text comparison is often satisfied by the broken reading too.

private func parseHTML(_ s: String, _ sch: Schema = schema) throws -> Node {
    try HTMLParser.parse(s, schema: sch)
}

/// The test schema with some node specs changed, declaration order kept.
private func reshaped(_ change: [String: (inout NodeSpec) -> Void]) throws -> Schema {
    var specs: [(String, NodeSpec)] = []
    for name in schema.nodeSpecOrder {
        guard var s = schema.nodes[name]?.spec else { continue }
        change[name]?(&s)
        specs.append((name, s))
    }
    return try Schema(nodes: specs, marks: schema.markSpecOrder.compactMap { n in schema.marks[n].map { (n, $0.spec) } },
                      topNode: "doc")
}

/// The test schema without some node types.
private func without(_ dropped: Set<String>) throws -> Schema {
    try Schema(nodes: schema.nodeSpecOrder.filter { !dropped.contains($0) }.compactMap { n in schema.nodes[n].map { (n, $0.spec) } },
               marks: schema.markSpecOrder.compactMap { n in schema.marks[n].map { (n, $0.spec) } }, topNode: "doc")
}

private func item(_ c: Node...) -> Node { node("listItem", [:], c) }
private func cell(_ attrs: Attrs = [:], _ c: Node...) -> Node { node("tableCell", attrs, c) }

func registerHTMLImportMutationKillTests() {
    test("html mut: a node with no place in a container that isn't full is unwrapped inside it") {
        // A blockquote can take more blocks after its first, so a stray
        // caption in one isn't overflow — it is unwrapped where it stands.
        // Only a *full* container (a figure after its caption) closes and
        // hands what follows out to its parent.
        let d = try parseHTML("<blockquote><p>a</p><figcaption>cap</figcaption><p>b</p></blockquote>")
        try d.check()
        try expectEqual(d, doc(node("blockquote", [:], [p("a"), p("cap"), p("b")])))
    }

    test("html mut: a stray item a list can't hold alone is filled out, not unwrapped") {
        // `wrap` falls back to `createAndFill` when the wrapper's content needs
        // more than the node: a list of at least two items gets an empty second.
        let pairs = try reshaped(["bulletList": { $0.content = "listItem listItem+" }])
        let d = try parseHTML("<li>a</li>", pairs)
        try d.check()
        try expectEqual(d, try pairs.node("doc", [:], content: Fragment.from([
            try pairs.node("bulletList", [:], content: Fragment.from([
                try pairs.node("listItem", [:], content: Fragment.from([try pairs.node("paragraph", [:], content: Fragment.from([pairs.text("a")]))])),
                try pairs.node("listItem", [:], content: Fragment.from([try pairs.node("paragraph")])),
            ])),
        ])))
    }

    test("html mut: stray cells merge into one row only while the row stays complete") {
        // A row of header/cell pairs: two stray headers would leave the merged
        // row wanting a cell, so the second starts a table of its own instead of
        // being merged into something `createAndFill` has to patch.
        let pairs = try reshaped(["tableRow": { $0.content = "(tableHeader tableCell)+" }])
        let d = try parseHTML("<th>a</th><th>b</th>", pairs)
        try d.check()
        func header(_ s: String) throws -> Node {
            try pairs.node("tableHeader", [:], content: Fragment.from([try pairs.node("paragraph", [:], content: Fragment.from([pairs.text(s)]))]))
        }
        let empty = try pairs.node("tableCell", [:], content: Fragment.from([try pairs.node("paragraph")]))
        func table(_ s: String) throws -> Node {
            try pairs.node("table", [:], content: Fragment.from([try pairs.node("tableRow", [:], content: Fragment.from([try header(s), empty]))]))
        }
        try expectEqual(d, try pairs.node("doc", [:], content: Fragment.from([try table("a"), try table("b")])))
    }

    test("html mut: a mark is judged against its own parent, whatever the document allows") {
        // A document that allows every mark doesn't make a mark legal in a
        // heading that allows none: the check has to descend with each node's
        // own type, both when looking for a forbidden mark and when rebuilding.
        let s = try reshaped(["doc": { $0.marks = "_" }, "heading": { $0.marks = "" }])
        let d = try parseHTML("<h1><b>bold</b> title</h1><p><b>kept</b></p>", s)
        try d.check()
        try expectEqual(d, try s.node("doc", [:], content: Fragment.from([
            try s.node("heading", ["level": .int(1)], content: Fragment.from([s.text("bold title")])),
            try s.node("paragraph", [:], content: Fragment.from([s.text("kept", [s.mark("bold")])])),
        ])))
    }

    test("html mut: a block node inside a paragraph splits it, keeping the text before it first") {
        let d = try parseHTML("<p>before <span data-type=\"block-math\" data-latex=\"x\">$$x$$</span> after</p>")
        try d.check()
        try expectEqual(d, doc(p("before "), blockMath("x"), p(" after")))
    }

    test("html mut: code degraded to paragraphs keeps its blank lines and its empty blocks") {
        let noCode = try without(["codeBlock"])
        func para(_ s: String) throws -> Node {
            try noCode.node("paragraph", [:], content: s.isEmpty ? .empty : Fragment.from([noCode.text(s)]))
        }
        let lines = try parseHTML("<pre>a\n\nb</pre>", noCode)
        try expectEqual(lines, try noCode.node("doc", [:], content: Fragment.from([try para("a"), try para(""), try para("b")])))
        // An empty code block still stood for a block.
        let empty = try parseHTML("<p>a</p><pre></pre><p>b</p>", noCode)
        try expectEqual(empty, try noCode.node("doc", [:], content: Fragment.from([try para("a"), try para(""), try para("b")])))
    }

    test("html mut: a code block's language is read past the whitespace before <code>") {
        let d = try parseHTML("<pre>\n<code class=\"language-swift\">let x</code></pre>")
        try expectEqual(d, doc(node("codeBlock", ["language": .string("swift")], [t("\nlet x")])))
    }

    test("html mut: cells straight inside a <table> are fitted there and take the column widths") {
        // No `<tr>`: the table fits its cells into a row itself, which is where
        // the `<col>` widths get applied — fitting them later, at the top
        // level, builds the table without them.
        let d = try parseHTML("<table><colgroup><col width=\"50\"><col width=\"70\"></colgroup><td>a</td><td>b</td></table>")
        try d.check()
        try expectEqual(d, doc(tableN(trN(cell(["colwidth": .array([.int(50)])], p("a")),
                                          cell(["colwidth": .array([.int(70)])], p("b"))))))
    }

    test("html mut: only aria-hidden=\"true\" hides a block") {
        let d = try parseHTML("<div aria-hidden=\"false\"><p>shown</p></div><p>next</p>")
        try expectEqual(d, doc(p("shown"), p("next")))
    }

    test("html mut: an item written loose inside a nested <ol> doesn't make the outer list loose") {
        // Whether a list is tight is read off its own items; a `<p>` inside a
        // nested list — ordered as much as unordered — belongs to that list.
        let d = try parseHTML("<ul><li>a<ol><li><p>b</p></li></ol></li></ul>")
        try expectEqual(d, doc(node("bulletList", tightList, [
            item(p("a"), node("orderedList", [:], [item(p("b"))])),
        ])))
    }

    test("html mut: a checkbox's trailing newline and tab are trimmed from the task text") {
        let d = try parseHTML("<ul><li><input type=\"checkbox\">\n\tbuy milk</li></ul>")
        try expectEqual(d, doc(taskListN(taskItemN(false, p("buy milk")))))
    }

    test("html mut: an ordered sub-list directly inside a task list joins the task above") {
        let d = try parseHTML("<ul data-type=\"taskList\"><li data-type=\"taskItem\" data-checked=\"false\">a</li><ol><li>b</li></ol></ul>")
        try d.check()
        try expectEqual(d, doc(taskListN(taskItemN(false, p("a"), node("orderedList", tightList, [item(p("b"))])))))
    }

    test("html mut: data-checked=\"false\" still marks a list as a checklist") {
        // The attribute's presence is what says "task item"; its value only
        // says whether it is done.
        let d = try parseHTML("<ul><li data-checked=\"false\">todo</li><li data-checked=\"false\">later</li></ul>")
        try expectEqual(d, doc(taskListN(taskItemN(false, p("todo")), taskItemN(false, p("later")))))
    }

    test("html mut: CSS property names and keyword values are case-insensitive") {
        // Word writes `FONT-WEIGHT: bold`; hand-written markup writes `BOLD`.
        for style in ["FONT-WEIGHT: bold", "font-weight: BOLD", "Font-Weight: Bold"] {
            let d = try parseHTML("<p><span style=\"\(style)\">x</span></p>")
            try expectEqual(d, doc(p(strong("x"))), style)
        }
    }

    test("html mut: only a line-through decoration strikes; an overline doesn't") {
        let d = try parseHTML("<p><span style=\"text-decoration: overline\">o</span></p>")
        try expectEqual(d, doc(p("o")))
    }

    test("html mut: a zero-width column carries no width, and fractional pixels round") {
        let d = try parseHTML("<table><colgroup><col width=\"0\"><col style=\"width: 99.6px\"></colgroup><tr><td>a</td><td>b</td></tr></table>")
        try expectEqual(d, doc(tableN(trN(cell([:], p("a")), cell(["colwidth": .array([.int(100)])], p("b"))))))
    }

    test("html mut: a row-spanning cell stops pushing cells right once its rows end") {
        // Widths 10 and 20. Row 1: a (two rows tall), b. Row 2: c, pushed into
        // the second column by a. Row 3: d, e — back to both columns.
        let d = try parseHTML("""
        <table><colgroup><col width="10"><col width="20"></colgroup>\
        <tr><td rowspan="2">a</td><td>b</td></tr><tr><td>c</td></tr><tr><td>d</td><td>e</td></tr></table>
        """)
        func w(_ n: Int) -> Attrs { ["colwidth": .array([.int(n)])] }
        try expectEqual(d, doc(tableN(
            trN(cell(w(10).merging(["rowspan": .int(2)]) { a, _ in a }, p("a")), cell(w(20), p("b"))),
            trN(cell(w(20), p("c"))),
            trN(cell(w(10), p("d")), cell(w(20), p("e"))))))
    }

    test("html mut: only aria-hidden=\"true\" hides inline content") {
        let d = try parseHTML("<p>a <span aria-hidden=\"false\">b</span> c</p>")
        try expectEqual(d, doc(p("a b c")))
    }

    test("html mut: a self-closed mark tag marks nothing after it") {
        let d = try parseHTML("<p>a<b/>plain</p>")
        try expectEqual(d, doc(p("aplain")))
    }

    test("html mut: closing a nested span ends that span's marks, not the outer one's") {
        let red = schema.mark("textColor", ["color": .string("red")])
        let d = try parseHTML("<p><span style=\"color:red\">r<span style=\"font-weight:bold\">b</span>t</span></p>")
        try expectEqual(d, doc(p(schema.text("r", [red]), schema.text("b", [schema.mark("bold"), red]),
                                 schema.text("t", [red]))))
    }

    test("html mut: a self-closed tag doesn't count toward finding its namesake's close") {
        let d = try parseHTML("<blockquote><blockquote/><p>a</p></blockquote><p>b</p>")
        try expectEqual(d, doc(node("blockquote", [:], [p("a")]), p("b")))
    }

    test("html mut: an element's own style beats a class's") {
        let d = try parseHTML("<style>.b { font-weight: bold }</style><p><span class=\"b\" style=\"font-weight:normal;\">x</span></p>")
        try expectEqual(d, doc(p("x")))
    }
}
