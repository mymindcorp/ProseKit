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

func registerM5Tests() {
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
            if node.type.name == "wikiLink" { target = node.attrs["target"]?.stringValue }
            return true
        }
        try expectEqual(target, "Page")
    }

    test("wikiLink: [[Target|Label]] keeps a distinct label") {
        let editor = try makeFullEditor()
        try type(editor, "[[Home|Start]")
        try expect(textInput(editor, at: editor.doc.content.size - 1, "]"))
        var node: Node? = nil
        editor.doc.descendants { n, _, _, _ in if n.type.name == "wikiLink" { node = n }; return true }
        try expectEqual(node?.attrs["target"]?.stringValue, "Home")
        try expectEqual(node?.attrs["label"]?.stringValue, "Start")
        try expectEqual(node?.textContent, "Start")
    }

    test("wikiLink: insert via Editor + suggestion tracking") {
        let editor = try makeFullEditor()
        try expect(editor.insertWikiLink(target: "Index"))
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
