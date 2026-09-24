import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// Tests written while mutation-testing the table code (TableMap,
// TableCommandsPM, CellSelection, CellCopyPaste, FixTables, ColumnResizing,
// TableMove, TableInput, TableUtil). Each pins down a behaviour, matching
// prosemirror-tables, that a code change could break without any of the
// ported upstream tests noticing; the comment on each says which.

private func runTable(_ d: TaggedNode, _ cmd: @escaping Command) -> (ran: Bool, state: EditorState) {
    var state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: d.node, selection: selectionFor(d)))
    let ran = cmd(state, { tr in state = state.apply(tr) }, nil)
    return (ran, state)
}

private func cwCell(_ width: Int, _ text: String = "x") -> TaggedNode {
    tdAttrs(["colwidth": .array([.int(width)])], p(text))
}

/// The top-level index of the node the selection's head is in.
private func topIndex(_ state: EditorState) -> Int { state.selection.resolvedHead.index(0) }

/// Paste the cells between `<a>` and `<b>` of `cellsN` into the (first) table
/// of `docN`, at the cell holding `<anchor>`, the way `handlePaste` does.
private func pasteCells(_ docN: TaggedNode, _ cellsN: TaggedNode) throws -> EditorState {
    var state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: docN.node))
    guard let cell = cellAround(docN.node.resolve(tag(docN, "anchor"))) else {
        try expect(false, "no cell at <anchor>")
        return state
    }
    let tableStart = cell.start(-1)
    let map = TableMap.get(cell.node(-1))
    guard let cells = pastedCells(cellsN.node.slice(tag(cellsN, "a"), tag(cellsN, "b"))) else {
        try expect(false, "no pasted cells")
        return state
    }
    insertCells(state, { tr in state = state.apply(tr) }, tableStart, map.findCell(cell.pos - tableStart), cells)
    return state
}

func registerTableMutationKillTests() {
    // MARK: TableMap column widths

    // The map settles a column's width by majority: a width seen once gives
    // way to a different one, which then holds once it is seen twice.
    test("table mutation: fixTables resolves a column's width by majority, not first-seen") {
        let d = doc(table(tr(cwCell(100)), tr(cwCell(200)), tr(cwCell(200)))).node
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: d))
        let fixed = fixTables(state, nil)
        try expectNotNil(fixed)
        try expectEqual(fixed!.doc, doc(table(tr(cwCell(200)), tr(cwCell(200)), tr(cwCell(200)))).node)
    }

    // MARK: addColumn

    // A cell spanning both the new column's slot and several rows is widened
    // once, not once per row it covers.
    test("table mutation: addColumn widens a col+row-spanning cell once") {
        let r = runTable(table(tr(cCursor(), c11(), c11()), tr(cell(2, 2), c11()), tr(c11())), addColumnAfter)
        try expect(r.ran)
        try expectEqual(r.state.doc, table(tr(c11(), cEmpty(), c11(), c11()), tr(cell(3, 2), c11()), tr(c11())).node)
    }

    // MARK: keepCursorInTable

    // Deleting the last column can map the caret forward into the *next*
    // table; it belongs back in the table that was edited.
    test("table mutation: deleting the last column pulls the caret out of a following table") {
        let r = runTable(doc(table(tr(c11(), cCursor())), table(tr(td(p("y"))))), deleteColumn)
        try expect(r.ran)
        try expectEqual(r.state.doc, doc(table(tr(c11())), table(tr(td(p("y"))))).node)
        try expectEqual(topIndex(r.state), 0, "caret should stay in the first table")
        try expectEqual(r.state.selection.resolvedHead.parent.textContent, "x")
    }

    // MARK: removeRow

    // A cell whose rowspan starts in the deleted row moves down into the next
    // row at its own column, not at the row's start.
    test("table mutation: deleteRow re-seats a rowspanning cell at its column") {
        let r = runTable(table(tr(cCursor(), tdAttrs(["rowspan": .int(2)], p("y"))), tr(td(p("z")))), deleteRow)
        try expect(r.ran)
        try expectEqual(r.state.doc, table(tr(td(p("z")), td(p("y")))).node)
    }

    // MARK: mergeCells content

    // An empty cell contributes nothing to the merged cell's content (upstream
    // skips it), rather than an empty paragraph at the end.
    test("table mutation: mergeCells drops the empty paragraph of an empty cell") {
        let r = runTable(table(tr(td(p("x<anchor>")), td(p("<head>")))), mergeCells)
        try expect(r.ran)
        try expectEqual(r.state.doc, table(tr(tdAttrs(["colspan": .int(2)], p("x")))).node)
    }

    // When the cell merged into is itself empty, its empty paragraph is
    // replaced by the content that arrives, not kept in front of it.
    test("table mutation: mergeCells into an empty cell replaces its paragraph") {
        let r = runTable(table(tr(td(p("<anchor>")), td(p("y<head>")))), mergeCells)
        try expect(r.ran)
        try expectEqual(r.state.doc, table(tr(tdAttrs(["colspan": .int(2)], p("y")))).node)
    }

    // MARK: splitCell selection

    // Splitting a cell that is cell-selected leaves every piece selected: the
    // head moves to the last cell the split inserted.
    test("table mutation: splitCell on a cell selection selects all the pieces") {
        let r = runTable(table(tr(tdAttrs(["colspan": .int(2), "rowspan": .int(2)], p("foo<anchor>")), c11()), tr(c11())), splitCell)
        try expect(r.ran)
        try expectEqual(r.state.doc, table(tr(td(p("foo")), cEmpty(), c11()), tr(cEmpty(), cEmpty(), c11())).node)
        try expect(r.state.selection is CellSelection, "expected a CellSelection")
        let sel = r.state.selection as! CellSelection
        try expectEqual(sel.ranges.count, 4)
        try expectEqual(sel.anchorCell.pos, 1)
        // The bottom-right piece: row 1's second cell.
        let row0 = r.state.doc.child(0).nodeSize
        try expectEqual(sel.headCell.pos, row0 + 1 + cEmpty().node.nodeSize)
    }

    // MARK: goToNextCell

    // Shift-Tab from the start of a row lands on the previous row's last cell
    // and selects all of its content, not just its first block.
    test("table mutation: goToNextCell(-1) across rows selects the whole previous cell") {
        let r = runTable(table(tr(td(p("a")), td(p("b"), p("c"))), tr(td(p("<cursor>d")), td(p("e")))), goToNextCell(-1))
        try expect(r.ran)
        try expectEqual(r.state.selection.from, 8)
        try expectEqual(r.state.selection.to, 12)
    }

    // MARK: CellSelection.content / isColSelection

    // A cell cut off only on its right keeps its content (upstream only
    // empties cells whose *left* part is cut away).
    test("table mutation: CellSelection content keeps a cell clipped on the right") {
        let d = table(tr(td(p("a<anchor>")), td(p("b"))),
                      tr(tdAttrs(["colspan": .int(2)], p("w"))),
                      tr(td(p("d<head>")), td(p("e"))))
        let sel = selectionFor(d)
        try expect(sel is CellSelection)
        let expected = table(tr(td(p("a"))), tr(td(p("w"))), tr(td(p("d")))).node.content
        try expectEqual(sel.content(), Slice(content: expected, openStart: 1, openEnd: 1))
    }

    // The last row, selected whole, is a row selection but not a column one:
    // its copy is that row, not the table.
    test("table mutation: a bottom row selection is not a column selection") {
        let d = table(tr(td(p("a")), td(p("b"))), tr(td(p("c<anchor>")), td(p("d<head>"))))
        let sel = selectionFor(d) as! CellSelection
        try expect(sel.isRowSelection())
        try expect(!sel.isColSelection(), "a selection starting in row 1 is not a column selection")
        let expected = table(tr(td(p("c")), td(p("d")))).node.content
        try expectEqual(sel.content(), Slice(content: expected, openStart: 1, openEnd: 1))
    }

    // MARK: colSelection

    // Two cells of one row: the anchor goes to the top of its column and the
    // head to the bottom of its own — not the other way around.
    test("table mutation: colSelection from cells on one row runs top to bottom") {
        let grid = doc(table(tr(cEmpty(), cEmpty(), cEmpty()), tr(cEmpty(), cEmpty(), cEmpty()), tr(cEmpty(), cEmpty(), cEmpty()))).node
        let sel = CellSelection.colSelection(grid.resolve(16), grid.resolve(20))
        try expectEqual(sel.anchorCell.pos, 2)
        try expectEqual(sel.headCell.pos, 34)
        try expectEqual(sel.ranges.count, 6)
    }

    // A column-spanning head extends to the bottom cell under its *right*
    // edge, so the whole span is selected.
    test("table mutation: colSelection with a colspanning head covers its right column") {
        let d = doc(table(tr(td(p("a")), tdAttrs(["colspan": .int(2)], p("w"))), tr(td(p("b")), td(p("c")), td(p("d"))))).node
        let sel = CellSelection.colSelection(d.resolve(2), d.resolve(7))
        try expectEqual(sel.anchorCell.pos, 2)
        try expectEqual(sel.headCell.pos, 24)
        try expectEqual(d.nodeAt(sel.headCell.pos)?.textContent, "d")
        try expectEqual(sel.ranges.count, 5)
    }

    // MARK: rowSelection

    // A row-spanning head extends to the end of its *top* row, the row the
    // selection is anchored in, not the last row it reaches.
    test("table mutation: rowSelection of a rowspanning cell ends on its top row") {
        let d = doc(table(tr(tdAttrs(["rowspan": .int(2)], p("a")), td(p("b"))), tr(td(p("c"))))).node
        let sel = CellSelection.rowSelection(d.resolve(2), d.resolve(2))
        try expectEqual(sel.anchorCell.pos, 2)
        try expectEqual(sel.headCell.pos, 7)
        try expectEqual(d.nodeAt(sel.headCell.pos)?.textContent, "b")
    }

    // MARK: pastedCells

    // A multi-row slice that starts inside a cell's text is open one level
    // deeper than its rows: the first row is fitted with the cell and its
    // paragraph open, so the partial cell keeps the text after the cut.
    test("table mutation: pastedCells fits a first row opened inside a cell's text") {
        let d = table(tr(td(p("fo<a>o")), td(p("x"))), tr(td(p("y")), td(p("z<b>"))))
        let area = pastedCells(d.node.slice(tag(d, "a"), tag(d, "b")))
        try expectNotNil(area)
        try expectEqual(area!.width, 2)
        try expectEqual(area!.height, 2)
        try expectEqual(area!.rows[0], Fragment.from([td(p("o")).node, td(p("x")).node]))
        try expectEqual(area!.rows[1], Fragment.from([td(p("y")).node, td(p("z")).node]))
    }

    // MARK: insertCells isolation

    // Pasting whose left edge cuts through a cell spanning two columns *and*
    // two rows splits that cell once, keeping its rowspan on both halves,
    // rather than once per row it covers.
    test("table mutation: paste splits a col+row-spanning cell at its left edge once") {
        let state = try pasteCells(
            doc(table(tr(td(p("a")), td(p("b<anchor>")), td(p("c"))),
                      tr(tdAttrs(["colspan": .int(2), "rowspan": .int(2)], p("w")), td(p("d"))),
                      tr(td(p("e"))))),
            doc(table("<a>", tr(td(p("1")), td(p("2"))), tr(td(p("3")), td(p("4"))), tr(td(p("5")), td(p("6"))), "<b>")))
        try expectEqual(state.doc, doc(table(tr(td(p("a")), td(p("1")), td(p("2"))),
                                             tr(tdAttrs(["rowspan": .int(2)], p("w")), td(p("3")), td(p("4"))),
                                             tr(td(p("5")), td(p("6"))))).node)
        // The pasted block ends up selected, from its top-left to its
        // bottom-right cell.
        try expect(state.selection is CellSelection, "expected the pasted cells selected")
        let sel = state.selection as! CellSelection
        try expectEqual(sel.anchorCell.nodeAfter?.textContent, "1")
        try expectEqual(sel.headCell.nodeAfter?.textContent, "6")
        try expectEqual(sel.ranges.count, 6)
    }

    // MARK: fixTables collisions

    // A colliding cell that spans two rows is narrowed, and each row it spans
    // is owed the cell it gave up — the second row gets one at its start.
    test("table mutation: fixTables owes a cell to every row a colliding cell spans") {
        let d = doc(table(tr(c11(), cell(1, 2), c11()), tr(cell(2, 2)), tr(c11()))).node
        let tr0 = fixTables(EditorState.create(EditorStateConfig(schema: basicSchema, doc: d)), nil)
        try expectNotNil(tr0)
        try expectEqual(tr0!.doc, doc(table(tr(c11(), cell(1, 2), c11()), tr(cell(1, 2), cEmpty(), cEmpty()), tr(cEmpty(), c11()))).node)
    }

    // MARK: ResizeState remapping

    // The handle maps with a backward bias, as upstream does: a cell inserted
    // exactly where the hovered cell starts leaves the handle at that position
    // (now the inserted cell), rather than following the old cell forward.
    test("table mutation: the resize handle maps backward over an insertion at it") {
        var state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: doc(table(tr(cEmpty(), cEmpty()))).node,
                                                         plugins: [columnResizing()]))
        state = state.apply(setResizeHandle(state.tr, 6))
        let txn = state.tr
        _ = try txn.insert(6, cEmpty().node)
        state = state.apply(txn)
        try expectEqual(columnResizingKey.getState(state)?.activeHandle, 6)
    }

    // MARK: moveColumn selection

    // After a move the moved column is selected where it landed.
    test("table mutation: moveColumn selects the column at its target") {
        let d = doc(table(tr(td(p("a")), td(p("b")), td(p("c"))), tr(td(p("d")), td(p("e")), td(p("f"))))).node
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: d))
        let txn = state.tr
        try expect(moveColumn(txn, originIndex: 0, targetIndex: 2, pos: 3))
        try expectEqual(txn.doc, doc(table(tr(td(p("b")), td(p("c")), td(p("a"))), tr(td(p("e")), td(p("f")), td(p("d"))))).node)
        try expect(txn.selection is CellSelection, "expected a cell selection")
        let texts = (txn.selection as! CellSelection).selectedCellPositions.map { txn.doc.nodeAt($0)!.textContent }
        try expectEqual(texts.sorted(), ["a", "d"])
    }

    // MARK: selectionCell

    // For a cell selection, the cell commands work from whichever end comes
    // later in the document — here the anchor — so Tab moves past it.
    test("table mutation: goToNextCell from a backward cell selection starts at its later end") {
        let r = runTable(table(tr(td(p("a<head>")), td(p("b<anchor>")), td(p("c")))), goToNextCell(1))
        try expect(r.ran)
        try expectEqual(r.state.selection.resolvedHead.parent.textContent, "c")
    }

    // MARK: removeColSpan widths

    // Removing the only column that had a width leaves no widths at all, not
    // an array of zeros.
    test("table mutation: deleteColumn drops a colwidth left all zero") {
        let r = runTable(table(tr(cCursor(), c11()), tr(tdAttrs(["colspan": .int(2), "colwidth": .array([.int(100), .int(0)])], p("y")))), deleteColumn)
        try expect(r.ran)
        try expectEqual(r.state.doc, table(tr(c11()), tr(td(p("y")))).node)
        try expectEqual(r.state.doc.child(1).child(0).attrs["colwidth"], AttributeValue.null)
    }

    // MARK: atEndOfCell

    // Shift-Left only leaves the cell from its very start; with text before
    // the caret it is ordinary text selection, not a cell selection.
    test("table mutation: Shift-Left mid-text does not start a cell selection") {
        let r = runTable(table(tr(td(p("a")), td(p("b<cursor>c")))), tableShiftArrow(.horiz, -1))
        try expect(!r.ran, "Shift-Left should fall through mid-text")
        try expect(r.state.selection is TextSelection)
        let atStart = runTable(table(tr(td(p("a")), td(p("<cursor>bc")))), tableShiftArrow(.horiz, -1))
        try expect(atStart.ran)
        try expect(atStart.state.selection is CellSelection)
    }

    // MARK: moveRowInArrayOfRows

    // Moving an even number of rows down lands the block one earlier than the
    // target's end (upstream's positionOffset), so it sits where the target was.
    test("table mutation: moving two rows down lands them before the target's end") {
        try expectEqual(moveRowInArrayOfRows(["a", "b", "c", "d", "e"], [0, 1], [3], 0), ["c", "d", "a", "b", "e"])
        // An odd-sized block goes after the target.
        try expectEqual(moveRowInArrayOfRows(["a", "b", "c", "d", "e"], [0], [3], 0), ["b", "c", "d", "a", "e"])
    }

    // MARK: mergeCells overlap

    // A cell inside the selection that reaches below its bottom edge makes the
    // rectangle unmergeable, as one reaching past any other edge does.
    test("table mutation: mergeCells refuses a cell sticking out of the bottom") {
        let d = table(tr(td(p("a<anchor>")), tdAttrs(["rowspan": .int(2)], p("t")), td(p("c<head>"))), tr(td(p("d")), td(p("e"))))
        let r = runTable(d, mergeCells)
        try expect(!r.ran, "merging would cut the rowspanning cell")
        try expectEqual(r.state.doc, d.node)
    }

    // MARK: clipCells

    // Widening repeats cells, and a repeated cell spanning three rows reserves
    // its column in each of the rows below it, not just the next one.
    test("table mutation: clipCells reserves a three-row span in every row it covers") {
        let slice = table("<a>", tr(cell(1, 3), c11()), tr(c11()), tr(c11()), "<b>")
        let r = clipCells(pastedCells(slice.node.slice(tag(slice, "a"), tag(slice, "b")))!, 3, 3)
        try expectEqual(r.width, 3)
        try expectEqual(r.height, 3)
        try expectEqual(r.rows, [Fragment.from([cell(1, 3).node, c11().node, cell(1, 3).node]),
                                 Fragment.from([c11().node]), Fragment.from([c11().node])])
    }
}
