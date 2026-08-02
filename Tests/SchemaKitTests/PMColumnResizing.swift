import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness
import DocumentTransform

// Ported from prosemirror-tables/test/column-resizing.test.ts (one upstream
// case) plus headless coverage for the pieces upstream only exercises through
// the DOM: ResizeState meta transitions/remapping and updateColumnWidth.

private func resizeState(_ d: TaggedNode) -> EditorState {
    EditorState.create(EditorStateConfig(schema: basicSchema, doc: d.node, plugins: [columnResizing()]))
}

func registerPMColumnResizingTests() {
    test("PM columnresizing: handleDecorations returns empty for a non-cell position") {
        // Upstream passes null; the headless equivalent is any invalid position.
        let state = resizeState(doc(table(tr(cEmpty(), cEmpty(), cEmpty()))))
        try expectEqual(handleDecorations(state, -1), DecorationSet.empty)
        try expectEqual(handleDecorations(state, 0), DecorationSet.empty) // doc start, not a cell
    }

    test("PM columnresizing: one handle per row on the hovered column edge") {
        let state = resizeState(doc(table(tr(cEmpty(), cEmpty()), tr(cEmpty(), cEmpty()))))
        // First cell of the first row starts at pos 2.
        let decos = handleDecorations(state, 2).decorations
        try expectEqual(decos.count, 2) // one widget per row
        try expect(decos.allSatisfy { $0.attributes["class"] == "column-resize-handle" })
    }

    test("PM columnresizing: a rowspanning cell gets a single handle") {
        let state = resizeState(doc(table(tr(cell(1, 2), cEmpty()), tr(cEmpty()))))
        let decos = handleDecorations(state, 2).decorations
        try expectEqual(decos.count, 1)
    }

    test("PM columnresizing: ResizeState follows setHandle/setDragging metas and remaps") {
        let d = doc(p("x"), table(tr(cEmpty(), cEmpty())))
        var state = resizeState(d)
        try expectEqual(columnResizingKey.getState(state)?.activeHandle, -1)

        // Hover a cell edge (first cell of the table starts at p-size + 2 = 5).
        state = state.apply(setResizeHandle(state.tr, 5))
        try expectEqual(columnResizingKey.getState(state)?.activeHandle, 5)

        // Start dragging.
        state = state.apply(setResizeDragging(state.tr, ColumnDragging(startX: 10, startWidth: 100)))
        try expectEqual(columnResizingKey.getState(state)?.dragging, ColumnDragging(startX: 10, startWidth: 100))

        // A doc change before the handle remaps it.
        let tr = try! state.tr.insertText("yy", 1)
        state = state.apply(tr)
        try expectEqual(columnResizingKey.getState(state)?.activeHandle, 7)

        // Deleting the table invalidates the handle.
        let tr2 = try! state.tr.delete(5, state.doc.content.size)
        state = state.apply(tr2)
        try expectEqual(columnResizingKey.getState(state)?.activeHandle, -1)
    }

    test("PM columnresizing: updateColumnWidth writes colwidth down the column") {
        let d = doc(table(tr(cEmpty(), cEmpty()), tr(cEmpty(), cEmpty())))
        let state = resizeState(d)
        let tr = state.tr
        updateColumnWidth(tr, 2, 120) // first column
        let table = tr.doc.child(0)
        try expectEqual(cellAt(table, row: 0, col: 0).attrs["colwidth"], .array([.int(120)]))
        try expectEqual(cellAt(table, row: 1, col: 0).attrs["colwidth"], .array([.int(120)]))
        try expectEqual(cellAt(table, row: 0, col: 1).attrs["colwidth"], .null)
    }

    test("PM columnresizing: updateColumnWidth ignores a non-cell position") {
        // A stale/invalid handle position (not pointing at a cell) must be a safe
        // no-op, not a crash (regression for the missing pointsAtCell guard).
        let d = doc(table(tr(cEmpty(), cEmpty())))
        let state = resizeState(d)
        let tr = state.tr
        updateColumnWidth(tr, 0, 120)                       // before the table
        updateColumnWidth(tr, tr.doc.content.size + 50, 120) // out of range
        try expect(!tr.docChanged)
    }

    test("PM columnresizing: updateColumnWidth sets the right slot of a colspan cell") {
        // Row 0: one cell spanning both columns; row 1: two cells.
        let d = doc(table(tr(cell(2, 1)), tr(cEmpty(), cEmpty())))
        let state = resizeState(d)
        let tr = state.tr
        // Resize via the second cell of row 1 (column 1); table content starts at 1.
        let row1SecondCell = 1 + TableMap.get(d.node.child(0)).map[3]
        updateColumnWidth(tr, row1SecondCell, 80)
        let table = tr.doc.child(0)
        try expectEqual(cellAt(table, row: 0, col: 0).attrs["colwidth"], .array([.int(0), .int(80)]))
        try expectEqual(cellAt(table, row: 1, col: 1).attrs["colwidth"], .array([.int(80)]))
    }
}

private func cellAt(_ table: Node, row: Int, col: Int) -> Node {
    let map = TableMap.get(table)
    return table.nodeAt(map.map[row * map.width + col])!
}

// MARK: - Configuration

func registerTableOptionTests() {
    test("table options: resizing carries the grab area and minimum width") {
        let options = ColumnResizingOptions(handleWidth: 12, cellMinWidth: 40)
        let state = EditorState.create(EditorStateConfig(
            schema: basicSchema, doc: doc(table(tr(cEmpty(), cEmpty()))).node,
            plugins: [columnResizing(options: options)]))
        try expectEqual(columnResizingKey.getState(state)?.options, options)
        // They survive an edit: the options belong to the plugin, not the state
        // it recomputes on every transaction.
        let after = state.apply(try state.tr.insertText("x", 3))
        try expectEqual(columnResizingKey.getState(after)?.options, options)
    }

    test("table options: the defaults are the renderer's, not upstream's") {
        // 6pt suits a fingertip where the web's 5px suits a mouse.
        try expectEqual(ColumnResizingOptions().handleWidth, 6)
        try expectEqual(ColumnResizingOptions().cellMinWidth, 24)
    }

    test("table options: resizable false leaves the plugin out") {
        // The view asks for the plugin's state to decide whether a border can
        // be dragged, so leaving it out is how the option reaches the renderer.
        let on = try Editor(extensions: fullKit())
        try expect(columnResizingKey.getState(on.state) != nil, "expected the plugin when resizable")
        let off = try Editor(extensions: fullKit(tableOptions: TableOptions(resizable: false)))
        try expect(columnResizingKey.getState(off.state) == nil, "expected no plugin when not resizable")
        // It is the resizing that was turned off, not the table: editing one
        // still works.
        try putCursorInATable(off)
        try expect(off.run("addRowAfter"), "expected addRowAfter to still run")
    }

    test("table options: a table node selection is normalized unless allowed") {
        for allowed in [false, true] {
            let editor = try Editor(extensions: fullKit(
                tableOptions: TableOptions(allowTableNodeSelection: allowed)))
            try putCursorInATable(editor)
            let tr = editor.state.tr
            tr.setSelection(NodeSelection.create(tr.doc, 0))
            editor.dispatch(tr)
            // Off, the selection of the whole table becomes a selection of its
            // cells — which is what the commands and the renderer expect.
            try expectEqual(editor.state.selection is NodeSelection, allowed,
                            "allowTableNodeSelection: \(allowed)")
        }
    }
}

/// Put a 2×2 table in the editor and the cursor in its first cell.
private func putCursorInATable(_ editor: Editor) throws {
    try expect(editor.run(insertTable(rows: 2, cols: 2)), "could not insert a table")
}

// MARK: - Regression

func registerCellSelectionMappingTests() {
    test("cellselection: a column selection over a ragged table doesn't trap") {
        // A column selection is rebuilt from the table map, which is arithmetic
        // over cell offsets. In a ragged table the map has no entry for the
        // missing cell, so the arithmetic gives a position that isn't a cell —
        // the table's own start. Resolving that and handing it to
        // `CellSelection.init` trapped: a table map cannot be built from the
        // document node. A table is ragged for real mid-transaction, before
        // `fixTables` squares it up, which is how the fuzz reached this.
        let d = doc(table(tr(cEmpty()), tr(cEmpty(), cEmpty()))).node
        // The second cell of the second row: the column above it is missing.
        var cells: [Int] = []
        d.descendants { node, pos, _, _ in
            if node.type.name == "tableCell" || node.type.name == "tableHeader" { cells.append(pos) }
            return true
        }
        try expect(cells.count == 3, "expected a ragged 1+2 table, found \(cells.count) cells")
        let selection = CellSelection.colSelection(d.resolve(cells[2]))
        try expect(selection.to <= d.content.size, "selection out of range")
    }
}

