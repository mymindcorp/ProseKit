import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

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
