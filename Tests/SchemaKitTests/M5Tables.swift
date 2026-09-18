import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// Registered into the shared `collector` from main.swift.

func makeFullEditor() throws -> Editor { try Editor(extensions: fullKit()) }

/// Count nodes of a given type in a doc.
func count(_ doc: Node, _ typeName: String) -> Int {
    var n = 0
    doc.descendants { node, _, _, _ in
        if node.type.name == typeName { n += 1 }
        return true
    }
    return n
}

/// Place the cursor inside the first cell of a table in the doc.
func cursorInFirstCell(_ editor: Editor) {
    var target: Int? = nil
    editor.doc.descendants { node, pos, _, _ in
        if target == nil && (node.type.name == "tableCell" || node.type.name == "tableHeader") {
            target = pos + 2 // inside the cell's paragraph
        }
        return true
    }
    if let t = target {
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, min(t, editor.doc.content.size))))
    }
}

/// Whether the caret sits inside a table.
private func inTable(_ editor: Editor) -> Bool {
    let rp = editor.doc.resolve(editor.state.selection.from)
    return (0...rp.depth).contains { rp.node($0).type.name == "table" }
}

/// Caret in the last cell of the document's last table.
private func cursorInLastCell(_ editor: Editor) {
    var pos = 0
    editor.doc.descendants { node, p, _, _ in
        if node.type.name == "tableCell" { pos = p + 2 }
        return true
    }
    editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, pos)))
}

/// A table of empty cells with a paragraph after it — somewhere for a caret
/// pushed out of the table to land.
private func tableThenParagraph(rows: Int, cols: Int) throws -> Editor {
    let editor = try makeFullEditor()
    try expect(editor.insertTable(rows: rows, cols: cols, withHeaderRow: false))
    let tr = editor.state.tr
    try tr.insert(tr.doc.content.size, editor.schema.nodes["paragraph"]!.createAndFill()!)
    editor.dispatch(tr)
    return editor
}

func registerM5Tests() {
    for required in [false, true] {
        for nodeSelected in [false, true] {
            test("delete table: required table \(required), node selection \(nodeSelected)") {
                let schema = try Schema(nodes: [
                    ("doc", NodeSpec(content: required ? "table+" : "block+")),
                    ("paragraph", NodeSpec(content: "text*", group: "block")),
                    ("text", NodeSpec()),
                    ("table", TableExtension().nodeSpec),
                    ("tableRow", TableRowExtension().nodeSpec),
                    ("tableCell", TableCellExtension().nodeSpec),
                    ("tableHeader", TableHeaderExtension().nodeSpec)
                ])
                let paragraph = try schema.node("paragraph", content: .from(schema.text("keep")))
                let cell = try schema.node("tableCell", content: .from(paragraph))
                let row = try schema.node("tableRow", content: .from(cell))
                let table = try schema.node("table", content: .from(row))
                let doc = try schema.node("doc", content: .from(table))
                let selection: Selection = nodeSelected ? NodeSelection.create(doc, 0) : TextSelection.create(doc, 4)
                let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: selection))
                var result: Transaction?
                let handled = deleteTable(state, { result = $0 }, nil)
                if required {
                    try expect(result == nil, "Cannot erase table contents and silently replace it with another table")
                } else {
                    try expectEqual(result?.doc, try schema.node("doc", content: .from(schema.node("paragraph"))))
                    try result?.doc.check()
                }
                try expectEqual(handled, !required)
                try expectEqual(deleteTable(state, nil, nil), !required)
            }
        }
    }
    test("table insertion: rejects a schema that cannot retain the table") {
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "paragraph+")),
            ("paragraph", NodeSpec(content: "text*", group: "block")),
            ("text", NodeSpec()),
            ("table", TableExtension().nodeSpec),
            ("tableRow", TableRowExtension().nodeSpec),
            ("tableCell", TableCellExtension().nodeSpec),
            ("tableHeader", TableHeaderExtension().nodeSpec)
        ])
        let paragraph = try schema.node("paragraph", content: Fragment.from(schema.text("keep")))
        let doc = try schema.node("doc", content: Fragment.from(paragraph))
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: TextSelection.create(doc, 1, 5)))
        let command = insertTable(rows: 1, cols: 1)
        var dispatched = false
        try expect(!command(state, { _ in dispatched = true }, nil))
        try expect(!dispatched)
        try expect(!command(state, nil, nil))
    }

    test("table insertion: places the caret in the inserted table at paragraph boundaries") {
        for pos in [1, 3, 5] {
            let editor = try makeFullEditor()
            try editor.setContent(html: "<p>abcd</p>")
            select(editor, pos, pos)
            try expect(editor.insertTable(rows: 1, cols: 1))
            let head = editor.state.selection.resolvedHead
            try expect((0...head.depth).contains { head.node($0).type.name == "table" })
            try expectEqual(head.parent.type.name, "paragraph")
            try editor.doc.check()
        }
    }

    test("delete table: a table document root cannot be deleted") {
        let schema = try Schema(nodes: [
            ("paragraph", NodeSpec(content: "text*", group: "block")),
            ("text", NodeSpec()),
            ("table", TableExtension().nodeSpec),
            ("tableRow", TableRowExtension().nodeSpec),
            ("tableCell", TableCellExtension().nodeSpec),
            ("tableHeader", TableHeaderExtension().nodeSpec)
        ], topNode: "table")
        let doc = createTable(schema, rows: 1, cols: 1, withHeaderRow: false)!
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc))
        try expect(!deleteTable(state, nil, nil))
        var dispatched = false
        try expect(!deleteTable(state, { _ in dispatched = true }, nil))
        try expect(!dispatched)
    }

    test("delete table: a node selection targets the selected table") {
        for nested in [false, true] {
            let editor = try makeFullEditor()
            let inner = "<table><tr><td>remove</td></tr></table>"
            try editor.setContent(html: nested ? "<table><tr><td><p>keep</p>" + inner + "</td></tr></table>" : "<p>keep</p>" + inner)
            var pos = 0
            editor.doc.descendants { node, at, _, _ in
                if node.type.name == "table" { pos = at }
                return true
            }
            let state = EditorState.create(EditorStateConfig(schema: editor.schema, doc: editor.doc, selection: NodeSelection.create(editor.doc, pos)))
            var result = state
            try expect(deleteTable(state, { result = state.apply($0) }, nil))
            try expectEqual(result.doc.textContent, "keep")
            try expectEqual(result.doc.firstChild?.type.name, nested ? "table" : "paragraph")
            try result.doc.check()
        }
    }

    test("table creation: nonpositive dimensions are rejected") {
        let editor = try Editor(extensions: fullKit())
        let before = editor.doc
        for (rows, cols) in [(-1, 2), (2, -1), (0, 2), (2, 0)] {
            try expect(createTable(editor.schema, rows: rows, cols: cols) == nil)
            try expect(!editor.insertTable(rows: rows, cols: cols))
            try expectEqual(editor.doc, before)
        }
    }

    test("table creation: headers are optional when not requested") {
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "text*", group: "block")),
            ("text", NodeSpec()),
            ("table", TableExtension().nodeSpec),
            ("tableRow", NodeSpec(content: "tableCell+")),
            ("tableCell", TableCellExtension().nodeSpec)
        ])
        let table = createTable(schema, rows: 2, cols: 2, withHeaderRow: false)
        try expectNotNil(table)
        try table!.check()
        try expect(createTable(schema, rows: 2, cols: 2, withHeaderRow: true) == nil)
    }

    test("table creation: requested dimensions must satisfy the schema") {
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "text*", group: "block")),
            ("text", NodeSpec()),
            ("table", NodeSpec(content: "tableRow{2}", group: "block")),
            ("tableRow", NodeSpec(content: "tableCell{2}")),
            ("tableCell", TableCellExtension().nodeSpec),
            ("tableHeader", TableHeaderExtension().nodeSpec)
        ])
        try expect(createTable(schema, rows: 1, cols: 2, withHeaderRow: false) == nil)
        try expect(createTable(schema, rows: 2, cols: 1, withHeaderRow: false) == nil)
        try expect(createTable(schema, rows: 2, cols: 2, withHeaderRow: true) == nil)
        let table = createTable(schema, rows: 2, cols: 2, withHeaderRow: false)
        try expectNotNil(table)
        try table!.check()
    }

    // MARK: Image

    test("image: schema + insert") {
        let editor = try makeFullEditor()
        try expectNotNil(editor.schema.nodes["image"])
        try type(editor, "x")
        try expect(editor.insertImage(src: "cat.png", alt: "cat"))
        try expectEqual(count(editor.doc, "image"), 1)
    }

    // MARK: WikiLink

    test("wikiLink: [[Page]] input rule creates a node") {
        let editor = try makeFullEditor()
        try type(editor, "[[Page]")
        // type the final "]" which triggers the rule
        try expect(textInput(editor, at: editor.doc.content.size - 1, "]"))
        try expectEqual(count(editor.doc, "wikiLink"), 1)
        var target: String? = nil
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "wikiLink" { target = node.attrs["text"]?.stringValue }
            return true
        }
        try expectEqual(target, "Page")
    }

    test("wikiLink: [[Target|Label]] reads as the label") {
        let editor = try makeFullEditor()
        try type(editor, "[[Home|Start]")
        try expect(textInput(editor, at: editor.doc.content.size - 1, "]"))
        var node: Node? = nil
        editor.doc.descendants { n, _, _, _ in if n.type.name == "wikiLink" { node = n }; return true }
        // The words a reader sees are the link's text; the page name they were
        // written against isn't kept, because nothing resolves by name.
        try expectEqual(node?.attrs["text"]?.stringValue, "Start")
        try expectEqual(node?.textContent, "Start")
    }

    test("wikiLink: insert via Editor + suggestion tracking") {
        let editor = try makeFullEditor()
        try expect(editor.insertWikiLink(text: "Index"))
        try expectEqual(count(editor.doc, "wikiLink"), 1)

        // Suggestion state: typing "[[Ho" should expose a query.
        let editor2 = try makeFullEditor()
        try type(editor2, "[[Ho")
        try expectNotNil(editor2.wikiLinkSuggestion)
        try expectEqual(editor2.wikiLinkSuggestion?.query, "Ho")
    }

    // MARK: Tables

    test("table: insert a 3x3 table") {
        let editor = try makeFullEditor()
        try expect(editor.insertTable(rows: 3, cols: 3))
        try expectEqual(count(editor.doc, "table"), 1)
        try expectEqual(count(editor.doc, "tableRow"), 3)
        // 3 header cells + 6 body cells
        try expectEqual(count(editor.doc, "tableHeader"), 3)
        try expectEqual(count(editor.doc, "tableCell"), 6)
    }

    test("table: addRowAfter adds a row") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 2, cols: 2)
        cursorInFirstCell(editor)
        try expect(editor.run(addRowAfter))
        try expectEqual(count(editor.doc, "tableRow"), 3)
    }

    test("table: addColumnAfter widens every row") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 2, cols: 2, withHeaderRow: false)
        cursorInFirstCell(editor)
        try expect(editor.run(addColumnAfter))
        // 2 rows × 3 cols = 6 body cells
        try expectEqual(count(editor.doc, "tableCell"), 6)
    }

    test("table: deleteRow removes a row") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 3, cols: 2, withHeaderRow: false)
        cursorInFirstCell(editor)
        try expect(editor.run(deleteRow))
        try expectEqual(count(editor.doc, "tableRow"), 2)
    }

    // Tiptap Table 3.30.0: prosemirror-tables leaves the caret wherever the
    // deletion mapped it, which for the last row or column is the paragraph
    // after the table.
    test("table: deleting the last row keeps the caret in the table") {
        let editor = try tableThenParagraph(rows: 2, cols: 2)
        cursorInLastCell(editor)
        try expect(editor.run(deleteRow))
        try expectEqual(count(editor.doc, "tableRow"), 1)
        try expect(inTable(editor), "caret left the table")
    }

    test("table: deleting the last column keeps the caret in the table") {
        let editor = try tableThenParagraph(rows: 2, cols: 2)
        cursorInLastCell(editor)
        try expect(editor.run(deleteColumn))
        try expectEqual(count(editor.doc, "tableCell"), 2)
        try expect(inTable(editor), "caret left the table")
    }

    test("table: deleting a row that isn't the last leaves the caret alone") {
        let editor = try tableThenParagraph(rows: 3, cols: 2)
        cursorInFirstCell(editor)
        let before = editor.state.selection.from
        try expect(editor.run(deleteRow))
        try expectEqual(editor.state.selection.from, before)
        try expect(inTable(editor))
    }

    test("table: deleteColumn removes a column") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 2, cols: 3, withHeaderRow: false)
        cursorInFirstCell(editor)
        try expect(editor.run(deleteColumn))
        try expectEqual(count(editor.doc, "tableCell"), 4) // 2 rows × 2 cols
    }

    test("table: Tab moves to the next cell") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 2, cols: 2, withHeaderRow: false)
        cursorInFirstCell(editor)
        let firstHead = editor.state.selection.head
        try expect(editor.run(goToNextCell(1)))
        // The selection should land inside a (different, later) cell.
        try expect(editor.state.selection.head > firstHead)
        try expect(editor.isActive(node: "tableCell"))
        // Shift-Tab goes back.
        try expect(editor.run(goToNextCell(-1)))
        try expectEqual(editor.state.selection.head, firstHead)
    }

    test("table: Tab at the last cell does nothing (returns false)") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 1, cols: 1, withHeaderRow: false)
        cursorInFirstCell(editor)
        try expect(!editor.run(goToNextCell(1)))
    }

    test("table: Tab past the last cell appends a row and lands in its first cell") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 2, cols: 2, withHeaderRow: false)
        // Tab forward into the very last cell (bottom-right).
        cursorInFirstCell(editor)
        try expect(editor.run(goToNextCellOrAddRow)) // (0,1)
        try expect(editor.run(goToNextCellOrAddRow)) // (1,0)
        try expect(editor.run(goToNextCellOrAddRow)) // (1,1) — last cell
        try expectEqual(count(editor.doc, "tableRow"), 2)
        // Tab off the end grows the table and keeps the caret inside it.
        try expect(editor.run(goToNextCellOrAddRow))
        try expectEqual(count(editor.doc, "tableRow"), 3)
        try expectEqual(count(editor.doc, "tableCell"), 6) // 3 rows × 2 cols
        try expect(editor.isActive(node: "tableCell"))
        // The caret lands in the first cell of the new (last) row.
        var cellPos: [Int] = []
        editor.doc.descendants { node, pos, _, _ in
            if node.type.name == "tableCell" { cellPos.append(pos) }
            return true
        }
        let lastRowFirstCell = cellPos[4] // index 4 = first cell of the 3rd row
        let head = editor.state.selection.head
        try expect(head > lastRowFirstCell && head <= lastRowFirstCell + 3)
    }

    test("cellSelection: spans a rectangle of cells") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 2, cols: 2, withHeaderRow: false)
        var cellPos: [Int] = []
        editor.doc.descendants { node, pos, _, _ in
            if node.type.name == "tableCell" { cellPos.append(pos) }
            return true
        }
        try expectEqual(cellPos.count, 4)
        let sel = CellSelection.create(editor.doc, anchorCellPos: cellPos[0], headCellPos: cellPos[3])
        try expect(sel is CellSelection)
        try expectEqual(sel.ranges.count, 4) // 2x2 rectangle
        try expect(!sel.empty)
    }

    test("cellSelection: content() is a sub-table") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 2, cols: 2, withHeaderRow: false)
        var cellPos: [Int] = []
        editor.doc.descendants { node, pos, _, _ in
            if node.type.name == "tableCell" { cellPos.append(pos) }
            return true
        }
        let sel = CellSelection.create(editor.doc, anchorCellPos: cellPos[0], headCellPos: cellPos[1]) // top row only
        let slice = sel.content()
        // ProseMirror's CellSelection.content() returns the selected rows as an
        // open slice (openStart/openEnd 1), not wrapped in a table node.
        try expectEqual(slice.openStart, 1)
        try expectEqual(slice.openEnd, 1)
        let row = slice.content.firstChild
        try expectEqual(row?.type.name, "tableRow")
        try expectEqual(slice.content.childCount, 1)  // one row selected
        try expectEqual(row?.childCount, 2)           // two cells in it
    }

    test("cellSelection: a column through a rowspan leaves no empty row in content()") {
        // Column 1 of a 3-row table where row 0's cell spans two rows: row 1
        // has nothing of its own in the rectangle. prosemirror-tables writes an
        // empty row there, which our `tableRow` (one cell or more) rejects, so
        // pasting the slice back built a document the schema refused — found by
        // the selection fuzz at PROSEKIT_FUZZ_DOCS=1000, seed 591.
        let editor = try makeFullEditor()
        try editor.setContent(html: """
            <table><tr><td>a</td><td rowspan="2">b</td></tr>\
            <tr><td>c</td></tr>\
            <tr><td>d</td><td>e</td></tr></table>
            """)
        var cellPos: [Int] = []
        editor.doc.descendants { node, pos, _, _ in
            if node.type.name == "tableCell" { cellPos.append(pos) }
            return true
        }
        try expectEqual(cellPos.count, 5)
        let sel = CellSelection.create(editor.doc, anchorCellPos: cellPos[1], headCellPos: cellPos[4])
        try expectEqual(sel.ranges.count, 2)
        let slice = sel.content()
        try expectEqual(slice.content.childCount, 2, "the covered row is left out")
        try expectEqual(slice.content.child(0).firstChild?.attrs["rowspan"], .int(1), "and the span that crossed it ends sooner")
        try expectEqual(slice.content.child(0).firstChild?.textContent, "b")
        try expectEqual(slice.content.child(1).firstChild?.textContent, "e")
        let tr = editor.state.tr.setSelection(sel)
        _ = tr.replaceSelection(slice)
        try tr.doc.check()
    }

    test("cellSelection: create falls back to text selection outside a table") {
        let editor = try makeFullEditor()
        try type(editor, "hello")
        let sel = CellSelection.create(editor.doc, anchorCellPos: 1, headCellPos: 4)
        try expect(!(sel is CellSelection))
        try expect(sel is TextSelection)
    }

    test("deleteCellSelectionContent applies on a cell selection") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 2, cols: 2, withHeaderRow: false)
        var cellPos: [Int] = []
        editor.doc.descendants { node, pos, _, _ in
            if node.type.name == "tableCell" { cellPos.append(pos) }
            return true
        }
        let sel = CellSelection.create(editor.doc, anchorCellPos: cellPos[0], headCellPos: cellPos[3])
        editor.dispatch(editor.state.tr.setSelection(sel))
        try expect(editor.run(deleteCellSelectionContent))
        // The table is intact (still 4 cells), content cleared.
        try expectEqual(count(editor.doc, "tableCell"), 4)
    }

    test("table: deleteTable removes the table") {
        let editor = try makeFullEditor()
        _ = editor.insertTable(rows: 2, cols: 2)
        cursorInFirstCell(editor)
        try expect(editor.run(deleteTable))
        try expectEqual(count(editor.doc, "table"), 0)
    }
}
