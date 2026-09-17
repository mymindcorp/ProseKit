import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// Ported from prosemirror-schema-list/test/test-commands.ts — wrapInList,
// splitListItem, liftListItem, sinkListItem.

private func selFor(_ d: TaggedNode) -> Selection {
    if let a = d.tags["a"] {
        let r = d.node.resolve(a)
        if r.parent.inlineContent { return TextSelection.create(d.node, a, d.tags["b"]) }
        return NodeSelection.create(d.node, a)
    }
    return Selection.atStart(d.node)
}
private func mkState(_ d: TaggedNode) -> EditorState {
    EditorState.create(EditorStateConfig(schema: basicSchema, doc: d.node, selection: selFor(d)))
}

private func rootListState(nodeSelection: Bool, text: String = "") throws -> EditorState {
    let schema = try Schema(nodes: [
        ("doc", NodeSpec(content: "listItem+")),
        ("listItem", NodeSpec(content: "paragraph+")),
        ("paragraph", NodeSpec(content: "text*")),
        ("text", NodeSpec())
    ])
    let paragraph = try schema.node("paragraph", content: text.isEmpty ? .empty : Fragment.from(schema.text(text)))
    let item = try schema.node("listItem", content: Fragment.from(paragraph))
    let doc = try schema.node("doc", content: Fragment.from(item))
    let selection: Selection = nodeSelection ? NodeSelection.create(doc, 0) : TextSelection.create(doc, 2)
    return EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: selection))
}
private func run(_ d: TaggedNode, _ command: Command, _ result: TaggedNode?) throws {
    var state = mkState(d)
    _ = command(state, { tr in state = state.apply(tr) }, nil)
    try expectEqual(state.doc, (result ?? d).node)
    if let result, result.tags["a"] != nil {
        try expect(state.selection.eq(selFor(result)), "selection mismatch")
    }
}
private func lt(_ name: String) -> NodeType { basicSchema.nodes[name]! }

func registerPMListTests() {
    for supplied in [false, true] {
        for rangeSelected in [false, true] {
            test("list split: required item attributes supplied \(supplied), range selected \(rangeSelected)") {
                let schema = try Schema(nodes: [
                    ("doc", NodeSpec(content: "block+")),
                    ("paragraph", NodeSpec(content: "text*", group: "block")),
                    ("text", NodeSpec()),
                    ("list", NodeSpec(content: "(plainItem | listItem)+", group: "block")),
                    ("plainItem", NodeSpec(content: "paragraph block*")),
                    ("listItem", NodeSpec(content: "paragraph block*", attrs: ["id": AttributeSpec()]))
                ])
                let paragraph = try schema.node("paragraph", content: .from(schema.text("keep")))
                let item = try schema.node("listItem", ["id": .string("original")], content: .from(paragraph))
                let doc = try schema.node("doc", content: .from(schema.node("list", content: .from(item))))
                let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc,
                    selection: TextSelection.create(doc, 4, rangeSelected ? 6 : 4)))
                let command = splitListItem(schema.nodes["listItem"]!, supplied ? ["id": .string("new")] : [:])
                var result: Transaction?
                let performed = command(state, { result = $0 }, nil)
                if supplied {
                    try expectEqual(result?.doc.firstChild?.childCount, 2)
                    try expectEqual(result?.doc.firstChild?.child(0).attrs["id"], .string("original"))
                    try expectEqual(result?.doc.firstChild?.child(1).attrs["id"], .string("new"))
                    try expectEqual(result?.doc.textContent, rangeSelected ? "kp" : "keep")
                    try result?.doc.check()
                } else {
                    try expect(result == nil, "A failed split must not delete the selection or dispatch a no-op")
                }
                try expectEqual(performed, supplied)
                try expectEqual(command(state, nil, nil), supplied)
                try expectEqual(state.doc, doc)
            }
        }
    }
    for supplied in [false, true] {
        for nodeSelected in [false, true] {
            test("list wrapping: required attributes supplied \(supplied), node selected \(nodeSelected)") {
                let schema = try Schema(nodes: [
                    ("doc", NodeSpec(content: "block+")),
                    ("paragraph", NodeSpec(content: "text*", group: "block")),
                    ("text", NodeSpec()),
                    ("customList", NodeSpec(content: "listItem+", group: "block", attrs: ["key": AttributeSpec()])),
                    ("listItem", NodeSpec(content: "paragraph block*"))
                ])
                let paragraph = try schema.node("paragraph", content: .from(schema.text("keep")))
                let doc = try schema.node("doc", content: .from(paragraph))
                let selection: Selection = nodeSelected ? NodeSelection.create(doc, 0) : TextSelection.create(doc, 2)
                let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: selection))
                let command = wrapInList(schema.nodes["customList"]!, supplied ? ["key": .string("list-id")] : [:])
                var result: Transaction?
                try expectEqual(command(state, { result = $0 }, nil), supplied)
                try expectEqual(command(state, nil, nil), supplied)
                if supplied {
                    try expectEqual(result?.doc.firstChild?.attrs["key"], .string("list-id"))
                    try expectEqual(result?.doc.firstChild?.firstChild?.firstChild, paragraph)
                    try result?.doc.check()
                } else {
                    try expect(result == nil, "Failed wrapping must not dispatch a no-op transaction")
                }
                try expectEqual(state.doc, doc)
            }
        }
    }
    for listName in ["bulletList", "orderedList", "taskList"] {
        for allowed in [false, true] {
            for nodeSelected in [false, true] {
                test("list indent validity: \(listName), allowed \(allowed), node selection \(nodeSelected)") {
                    let schema = try Schema(nodes: [
                        ("doc", NodeSpec(content: "block+")),
                        ("paragraph", NodeSpec(content: "text*", group: "block")),
                        ("text", NodeSpec(group: "inline")),
                        (listName, NodeSpec(content: "listItem+", group: "block")),
                        ("listItem", NodeSpec(content: allowed ? "paragraph block*" : "paragraph"))
                    ])
                    let first = try schema.node("listItem", content: .from(schema.node("paragraph", content: .from(schema.text("one")))))
                    let second = try schema.node("listItem", content: .from(schema.node("paragraph", content: .from(schema.text("two")))))
                    let doc = try schema.node("doc", content: .from(schema.node(listName, content: .from([first, second]))))
                    let pos = 1 + first.nodeSize
                    let selection: Selection = nodeSelected ? NodeSelection.create(doc, pos) : TextSelection.create(doc, pos + 2)
                    let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: selection))
                    let command = sinkListItem(schema.nodes["listItem"]!)
                    var dispatched: Transaction?
                    let available = command(state, nil, nil)
                    let performed = command(state, { dispatched = $0 }, nil)
                    try expectEqual(performed, allowed)
                    try expectEqual(available, allowed)
                    if allowed {
                        try expectNotNil(dispatched)
                        let changed = dispatched!.doc
                        try expectEqual(changed.firstChild?.childCount, 1)
                        try expectEqual(changed.firstChild?.firstChild?.firstChild?.textContent, "one")
                        try expectEqual(changed.firstChild?.firstChild?.lastChild?.firstChild, second)
                        try changed.check()
                    } else {
                        try expect(dispatched == nil)
                    }
                    try expectEqual(state.doc, doc)
                }
            }
        }
    }
    for listName in ["bulletList", "orderedList", "taskList"] {
        for allowed in [false, true] {
            test("list lift availability: \(listName) agrees with execution (allowed \(allowed))") {
                let schema = try Schema(nodes: [
                    ("doc", NodeSpec(content: allowed ? "block+" : listName + "+")),
                    ("paragraph", NodeSpec(content: "text*", group: "block")),
                    ("text", NodeSpec(group: "inline")),
                    (listName, NodeSpec(content: "listItem+", group: "block")),
                    ("listItem", NodeSpec(content: "paragraph block*"))
                ])
                let paragraph = try schema.node("paragraph", content: .from(schema.text("keep")))
                let item = try schema.node("listItem", content: .from(paragraph))
                let doc = try schema.node("doc", content: .from(schema.node(listName, content: .from(item))))
                let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: TextSelection.create(doc, 3)))
                let command = liftListItem(schema.nodes["listItem"]!)
                let available = command(state, nil, nil)
                var dispatched: Transaction?
                let performed = command(state, { dispatched = $0 }, nil)
                try expectEqual(performed, allowed)
                try expectEqual(available, performed)
                if let dispatched {
                    try expectEqual(dispatched.doc.firstChild, paragraph)
                    try dispatched.doc.check()
                } else {
                    try expect(!allowed)
                }
                try expectEqual(state.doc, doc)
            }
        }
    }
    test("root list: nonempty items can still split") {
        let state = try rootListState(nodeSelection: false, text: "keep")
        var result = state
        try expect(splitListItem(state.schema.nodes["listItem"]!)(state, { result = state.apply($0) }, nil))
        try expectEqual(result.doc.childCount, 2)
        try expectEqual(result.doc.textContent, "keep")
        try result.doc.check()
    }

    test("root list: splitting an empty item does not read above the document") {
        let state = try rootListState(nodeSelection: false)
        let command = splitListItem(state.schema.nodes["listItem"]!)
        try expect(!command(state, nil, nil))
        var dispatched = false
        try expect(!command(state, { _ in dispatched = true }, nil))
        try expect(!dispatched)
    }

    test("root list: lifting a selected item cannot remove the document wrapper") {
        for selected in [true, false] {
            let state = try rootListState(nodeSelection: selected)
            let command = liftListItem(state.schema.nodes["listItem"]!)
            var dispatched = false
            try expect(!command(state, { _ in dispatched = true }, nil))
            try expect(!dispatched)
            try expect(!command(state, nil, nil))
        }
    }

    func c(_ name: String, _ body: @escaping @Sendable () throws -> Void) { test("PM list \(name)") { try body() } }

    // MARK: wrapInList
    c("wrapInList: can wrap a paragraph") { try run(doc(p("<a>foo")), wrapInList(lt("bullet_list")), doc(ul(li(p("foo"))))) }
    c("wrapInList: can wrap a nested paragraph") { try run(doc(blockquote(p("<a>foo"))), wrapInList(lt("ordered_list")), doc(blockquote(ol(li(p("foo")))))) }
    c("wrapInList: can wrap multiple paragraphs") { try run(doc(p("foo"), p("ba<a>r"), p("ba<b>z")), wrapInList(lt("bullet_list")), doc(p("foo"), ul(li(p("bar")), li(p("baz"))))) }
    c("wrapInList: doesn't wrap the first paragraph in a list item") { try run(doc(ul(li(p("<a>foo")))), wrapInList(lt("bullet_list")), nil) }
    c("wrapInList: doesn't wrap the first para in a different type of list item") { try run(doc(ol(li(p("<a>foo")))), wrapInList(lt("ordered_list")), nil) }
    c("wrapInList: does wrap the second paragraph in a list item") { try run(doc(ul(li(p("foo"), p("<a>bar")))), wrapInList(lt("bullet_list")), doc(ul(li(p("foo"), ul(li(p("bar"))))))) }
    c("wrapInList: joins with the list item above when wrapping its first paragraph") { try run(doc(ul(li(p("foo")), li(p("<a>bar")), li(p("baz")))), wrapInList(lt("ordered_list")), doc(ul(li(p("foo"), ol(li(p("bar")))), li(p("baz"))))) }
    c("wrapInList: only splits items where valid") { try run(doc(p("<a>one"), ol(li(p("two"))), p("three<b>")), wrapInList(lt("ordered_list")), doc(ol(li(p("one"), ol(li(p("two")))), li(p("three"))))) }

    // MARK: splitListItem
    c("splitListItem: has no effect outside of a list") { try run(doc(p("foo<a>bar")), splitListItem(lt("list_item")), nil) }
    c("splitListItem: has no effect on the top level") { try run(doc("<a>", p("foobar")), splitListItem(lt("list_item")), nil) }
    c("splitListItem: can split a list item") { try run(doc(ul(li(p("foo<a>bar")))), splitListItem(lt("list_item")), doc(ul(li(p("foo")), li(p("bar"))))) }
    c("splitListItem: can split a list item at the end") { try run(doc(ul(li(p("foobar<a>")))), splitListItem(lt("list_item")), doc(ul(li(p("foobar")), li(p())))) }
    c("splitListItem: deletes selected content") { try run(doc(ul(li(p("foo<a>ba<b>r")))), splitListItem(lt("list_item")), doc(ul(li(p("foo")), li(p("r"))))) }
    c("splitListItem: splits when lifting from a nested list") { try run(doc(ul(li(p("a"), ul(li(p("b")), li(p("<a>"))))), p("x")), splitListItem(lt("list_item")), doc(ul(li(p("a"), ul(li(p("b")))), li(p("<a>"))), p("x"))) }
    c("splitListItem: can lift from a continued nested list item") { try run(doc(ul(li(p("a"), ul(li(p("b")), li(p("ok"), p("<a>"))))), p("x")), splitListItem(lt("list_item")), doc(ul(li(p("a"), ul(li(p("b")), li(p("ok")))), li(p("<a>"))), p("x"))) }
    c("splitListItem: correctly lifts an entirely empty sublist") { try run(doc(ul(li(p("one"), ul(li(p("<a>"))), p("two")))), splitListItem(lt("list_item")), doc(ul(li(p("one")), li(p("<a>")), li(p("two"))))) }

    // MARK: liftListItem
    c("liftListItem: can lift from a nested list") { try run(doc(ul(li(p("hello"), ul(li(p("o<a><b>ne")), li(p("two")))))), liftListItem(lt("list_item")), doc(ul(li(p("hello")), li(p("one"), ul(li(p("two"))))))) }
    c("liftListItem: can lift two items from a nested list") { try run(doc(ul(li(p("hello"), ul(li(p("o<a>ne")), li(p("two<b>")))))), liftListItem(lt("list_item")), doc(ul(li(p("hello")), li(p("one")), li(p("two"))))) }
    c("liftListItem: can lift two items from a nested three-item list") { try run(doc(ul(li(p("hello"), ul(li(p("o<a>ne")), li(p("two<b>")), li(p("three")))))), liftListItem(lt("list_item")), doc(ul(li(p("hello")), li(p("one")), li(p("two"), ul(li(p("three"))))))) }
    c("liftListItem: can lift an item out of a list") { try run(doc(p("a"), ul(li(p("b<a>"))), p("c")), liftListItem(lt("list_item")), doc(p("a"), p("b"), p("c"))) }
    c("liftListItem: can lift two items out of a list") { try run(doc(p("a"), ul(li(p("b<a>")), li(p("c<b>"))), p("d")), liftListItem(lt("list_item")), doc(p("a"), p("b"), p("c"), p("d"))) }
    c("liftListItem: can lift three items from the middle of a list") { try run(doc(ul(li(p("a")), li(p("b<a>")), li(p("c")), li(p("d<b>")), li(p("e")))), liftListItem(lt("list_item")), doc(ul(li(p("a"))), p("b"), p("c"), p("d"), ul(li(p("e"))))) }
    c("liftListItem: can lift the first item from a list") { try run(doc(ul(li(p("a<a>")), li(p("b")), li(p("c")))), liftListItem(lt("list_item")), doc(p("a"), ul(li(p("b")), li(p("c"))))) }
    c("liftListItem: can lift the last item from a list") { try run(doc(ul(li(p("a")), li(p("b")), li(p("c<a>")))), liftListItem(lt("list_item")), doc(ul(li(p("a")), li(p("b"))), p("c"))) }
    c("liftListItem: joins adjacent lists when lifting an item with subitems") { try run(doc(ol(li(p("a"), ol(li(p("<a>b<b>"), ol(li(p("c")))), li(p("d")))), li(p("e")))), liftListItem(lt("list_item")), doc(ol(li(p("a")), li(p("b"), ol(li(p("c")), li(p("d")))), li(p("e"))))) }
    c("liftListItem: only joins adjacent lists when lifting if their types match") { try run(doc(ol(li(p("a"), ul(li(p("<a>b<b>"), ol(li(p("c")))), li(p("d")))))), liftListItem(lt("list_item")), doc(ol(li(p("a")), li(p("b"), ol(li(p("c"))), ul(li(p("d"))))))) }

    // MARK: sinkListItem
    c("sinkListItem: can wrap a simple item in a list") { try run(doc(ul(li(p("one")), li(p("t<a><b>wo")), li(p("three")))), sinkListItem(lt("list_item")), doc(ul(li(p("one"), ul(li(p("two")))), li(p("three"))))) }
    c("sinkListItem: won't wrap the first item in a sublist") { try run(doc(ul(li(p("o<a><b>ne")), li(p("two")), li(p("three")))), sinkListItem(lt("list_item")), nil) }
    c("sinkListItem: will move an item's content into the item above") { try run(doc(ul(li(p("one")), li(p("..."), ul(li(p("two")))), li(p("t<a><b>hree")))), sinkListItem(lt("list_item")), doc(ul(li(p("one")), li(p("..."), ul(li(p("two")), li(p("three"))))))) }
}
