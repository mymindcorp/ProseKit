import DocumentModel
import EditorStateKit
import EditorHistory
import SchemaKit
import TestHarness

private struct ListKeys {
    let editor: Editor
    let kind: String
    var schema: Schema { editor.schema }
    var itemType: String { kind == "taskList" ? "taskItem" : "listItem" }
    init(_ kind: String) throws {
        self.kind = kind
        editor = try Editor(extensions: fullKit())
    }
    func paragraph(_ text: String) throws -> Node {
        try schema.node("paragraph", content: .from(schema.text(text)))
    }
    func item(_ text: String, extra: [Node] = []) throws -> Node {
        try schema.node(itemType, kind == "taskList" ? ["checked": .bool(true)] : [:],
                        content: .from([paragraph(text)] + extra))
    }
    func list(_ items: [Node], order: Int = 4) throws -> Node {
        try schema.node(kind, kind == "orderedList" ? ["order": .int(order)] : [:], content: .from(items))
    }
    func load(_ nodes: [Node]) throws { editor.setContent(try schema.node("doc", content: .from(nodes))) }
    func pos(_ text: String, _ offset: Int = 0) -> Int {
        var found = -1
        editor.doc.descendants { node, pos, _, _ in
            if node.text == text { found = pos + offset }
            return true
        }
        return found
    }
    func selection(_ text: String, _ offset: Int = 0) { select(editor, pos(text, offset), pos(text, offset)) }
}

private func expectSelectionText(_ editor: Editor, anchor: String, anchorOffset: Int, head: String, headOffset: Int) throws {
    let selection = editor.state.selection
    try expectEqual(selection.resolvedAnchor.parent.textContent, anchor)
    try expectEqual(selection.resolvedAnchor.parentOffset, anchorOffset)
    try expectEqual(selection.resolvedHead.parent.textContent, head)
    try expectEqual(selection.resolvedHead.parentOffset, headOffset)
}

func registerListKeyboardCoverageTests() {
    for kind in ["bulletList", "orderedList", "taskList"] {
        test("list toggle: unwraps node-selected \(kind) and restores it with undo") {
            let f = try ListKeys(kind), e = f.editor
            let one = try f.item("one"), two = try f.item("two")
            let list = try f.list([one, two])
            try f.load([list])
            e.dispatch(e.state.tr.setSelection(NodeSelection.create(e.doc, 0)))
            let original = e.state
            let command = toggleList(f.schema.nodes[kind]!, f.schema.nodes[f.itemType]!)
            try expect(command(e.state, nil, nil))
            try expect(e.run(command))
            try expectEqual(e.doc, try f.schema.node("doc", content: .from([f.paragraph("one"), f.paragraph("two")])))
            try e.doc.check()
            try expect(key(e, "Mod-z"))
            try expectEqual(e.doc, original.doc)
            try expect(e.state.selection.eq(original.selection))
        }
        test("list toggle: lifts node-selected nested \(kind) with all its items") {
            let f = try ListKeys(kind), e = f.editor
            let two = try f.item("two"), three = try f.item("three")
            let inner = try f.list([two, three])
            let outerItem = try f.item("one", extra: [inner])
            try f.load([f.list([outerItem])])
            let nestedPos = 2 + (try f.paragraph("one")).nodeSize
            e.dispatch(e.state.tr.setSelection(NodeSelection.create(e.doc, nestedPos)))
            let original = e.state
            let command = toggleList(f.schema.nodes[kind]!, f.schema.nodes[f.itemType]!)
            try expect(command(e.state, nil, nil))
            try expect(e.run(command))
            try expectEqual(e.doc, try f.schema.node("doc", content: .from(f.list([f.item("one"), two, three]))))
            try e.doc.check()
            try expect(key(e, "Mod-z"))
            try expectEqual(e.doc, original.doc)
            try expect(e.state.selection.eq(original.selection))
        }
        test("list keyboard: \(kind) node-selected item survives indent and outdent") {
            let f = try ListKeys(kind), e = f.editor
            let one = try f.item("one"), two = try f.item("two")
            try f.load([f.list([one, two])])
            e.dispatch(e.state.tr.setSelection(NodeSelection.create(e.doc, 1 + one.nodeSize)))
            let original = e.state
            try expect(key(e, "Tab"))
            try expectEqual((e.state.selection as? NodeSelection)?.node, two)
            try expectEqual(e.doc.firstChild?.childCount, 1)
            try expect(key(e, "Shift-Tab"))
            try expectEqual(e.doc, original.doc)
            try expect(e.state.selection.eq(original.selection))
        }
        for offset in [0, 1, 3] {
            test("list keyboard: \(kind) Tab Shift-Tab and history preserve caret at \(offset)") {
                let f = try ListKeys(kind), e = f.editor
                let one = try f.item("one"), two = try f.item("two"), three = try f.item("three")
                try f.load([f.list([one, two, three])])
                f.selection("two", offset)
                let original = e.state
                e.dispatch(closeHistory(e.state.tr))
                try expect(key(e, "Tab"))
                let expected = try f.schema.node("doc", content: .from(f.list([f.item("one", extra: [f.list([two], order: 1)]), three])))
                try expectEqual(e.doc, expected)
                try expectSelectionText(e, anchor: "two", anchorOffset: offset, head: "two", headOffset: offset)
                let indented = e.state
                try expect(key(e, "Mod-z"))
                try expectEqual(e.doc, original.doc)
                try expect(e.state.selection.eq(original.selection))
                try expect(key(e, "Mod-y"))
                try expectEqual(e.doc, indented.doc)
                try expect(e.state.selection.eq(indented.selection))
                e.dispatch(closeHistory(e.state.tr))
                try expect(key(e, "Shift-Tab"))
                try expectEqual(e.doc, original.doc)
                try expect(e.state.selection.eq(original.selection))
                try expect(key(e, "Mod-z"))
                try expectEqual(e.doc, indented.doc)
                try expect(e.state.selection.eq(indented.selection))
                try expect(key(e, "Mod-y"))
                try expectEqual(e.doc, original.doc)
                try e.doc.check()
            }
        }
        for backwards in [false, true] {
            test("list keyboard: \(kind) moves a multi-item selection, backwards \(backwards)") {
                let f = try ListKeys(kind), e = f.editor
                let one = try f.item("one"), two = try f.item("two"), three = try f.item("three"), four = try f.item("four")
                try f.load([f.list([one, two, three, four])])
                let a = f.pos("two", 1), b = f.pos("three", 3)
                select(e, backwards ? b : a, backwards ? a : b)
                let original = e.state
                try expect(key(e, "Tab"))
                try expectEqual(e.doc.firstChild, f.list([f.item("one", extra: [f.list([two, three], order: 1)]), four]))
                try expectSelectionText(e, anchor: backwards ? "three" : "two", anchorOffset: backwards ? 3 : 1,
                    head: backwards ? "two" : "three", headOffset: backwards ? 1 : 3)
                try expect(key(e, "Shift-Tab"))
                try expectEqual(e.doc, original.doc)
                try expect(e.state.selection.eq(original.selection))
                try e.doc.check()
            }
        }
        test("list keyboard: \(kind) first item cannot indent and top-level Shift-Tab lifts") {
            let f = try ListKeys(kind), e = f.editor
            let one = try f.item("one"), two = try f.item("two")
            try f.load([f.list([one, two])])
            f.selection("one", 1)
            let original = e.state
            try expect(!key(e, "Tab"))
            try expect(e.state === original)
            try expectEqual(undoDepth(e.state), 0)
            try expect(key(e, "Shift-Tab"))
            try expectEqual(e.doc.child(0), f.paragraph("one"))
            try expectEqual(e.doc.child(1), f.list([two]))
            try expectSelectionText(e, anchor: "one", anchorOffset: 1, head: "one", headOffset: 1)
            try expect(key(e, "Mod-z"))
            try expectEqual(e.doc, original.doc)
            try expect(e.state.selection.eq(original.selection))
        }
        test("list keyboard: \(kind) appends into an existing nested list") {
            let f = try ListKeys(kind), e = f.editor
            let nested = try f.item("nested"), two = try f.item("two")
            try f.load([f.list([f.item("one", extra: [f.list([nested])]), two])])
            f.selection("two", 2)
            let original = e.state
            try expect(key(e, "Tab"))
            try expectEqual(e.doc.firstChild, f.list([f.item("one", extra: [f.list([nested, two])])]))
            try expectSelectionText(e, anchor: "two", anchorOffset: 2, head: "two", headOffset: 2)
            try expect(key(e, "Shift-Tab"))
            try expectEqual(e.doc, original.doc)
            try expect(e.state.selection.eq(original.selection))
        }
        test("list keyboard: \(kind) code block handles Tab before list indentation") {
            let f = try ListKeys(kind), e = f.editor
            let code = try f.schema.node("codeBlock", content: .from(f.schema.text("code")))
            try f.load([f.list([f.item("one"), f.item("two", extra: [code])])])
            f.selection("code")
            let original = e.state
            try expect(key(e, "Tab"))
            try expectEqual(e.doc.firstChild?.childCount, 2)
            try expectEqual(e.doc.firstChild?.lastChild?.lastChild?.textContent, "  code")
            try expectEqual(e.state.selection.resolvedHead.parent.type.name, "codeBlock")
            try expect(key(e, "Shift-Tab"))
            try expectEqual(e.doc, original.doc)
            try expect(e.state.selection.eq(original.selection))
        }
        test("list keyboard: \(kind) indentation inside a table precedes cell navigation") {
            let f = try ListKeys(kind), e = f.editor, s = f.schema
            let one = try f.item("one"), two = try f.item("two")
            let cell = try s.node("tableCell", content: .from(f.list([one, two])))
            let other = try s.node("tableCell", content: .from(f.paragraph("other")))
            try f.load([s.node("table", content: .from(s.node("tableRow", content: .from([cell, other]))))])
            f.selection("two", 1)
            let original = e.state
            try expect(key(e, "Tab"))
            let expectedList = try f.list([f.item("one", extra: [f.list([two], order: 1)])])
            try expectEqual(e.doc.firstChild?.firstChild?.firstChild?.firstChild, expectedList)
            try expectSelectionText(e, anchor: "two", anchorOffset: 1, head: "two", headOffset: 1)
            try expect(key(e, "Shift-Tab"))
            try expectEqual(e.doc, original.doc)
            try expect(e.state.selection.eq(original.selection))
            // The first item cannot indent: Tab falls through to the next cell.
            f.selection("one")
            try expect(key(e, "Tab"))
            try expectEqual(e.doc, original.doc)
            try expectSelectionText(e, anchor: "other", anchorOffset: 0, head: "other", headOffset: 5)
            try e.doc.check()
        }
    }
    for outer in ["bulletList", "orderedList", "taskList"] {
        for inner in ["bulletList", "orderedList", "taskList"] where inner != outer {
            test("list keyboard: mixed \(outer) containing \(inner) round-trips") {
                let f = try ListKeys(inner), e = f.editor
                let nested = try f.list([f.item("one"), f.item("two")])
                let outerItem = try f.schema.node(outer == "taskList" ? "taskItem" : "listItem",
                    content: .from([f.paragraph("parent"), nested]))
                try f.load([f.schema.node(outer, content: .from(outerItem))])
                f.selection("two", 1)
                let original = e.state
                try expect(key(e, "Tab"))
                try expect(e.doc != original.doc)
                try expectSelectionText(e, anchor: "two", anchorOffset: 1, head: "two", headOffset: 1)
                try expect(key(e, "Shift-Tab"))
                try expectEqual(e.doc, original.doc)
                try expect(e.state.selection.eq(original.selection))
                try e.doc.check()
            }
        }
    }
}
