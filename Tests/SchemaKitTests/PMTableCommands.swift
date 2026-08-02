import Foundation
import DocumentModel
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// Ported from prosemirror-tables/test/commands.test.ts.

private func runCmd(_ d: TaggedNode, _ cmd: @escaping Command) -> EditorState {
    var state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: d.node, selection: selectionFor(d)))
    _ = cmd(state, { tr in state = state.apply(tr) }, nil)
    return state
}

func selectionFor(_ d: TaggedNode) -> Selection {
    if let cursor = d.tags["cursor"] { return TextSelection(d.node.resolve(cursor)) }
    if let anchor = d.tags["anchor"], let a = cellAround(d.node.resolve(anchor)) {
        let h = d.tags["head"].flatMap { cellAround(d.node.resolve($0)) }
        return CellSelection(a, h)
    }
    if let node = d.tags["node"] { return NodeSelection.create(d.node, node) }
    return Selection.atStart(d.node)
}

func registerPMTableCommandsTests() {
    func tcase(_ name: String, _ d: TaggedNode, _ command: @escaping Command, _ result: TaggedNode?) {
        test("PM table \(name)") {
            var state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: d.node, selection: selectionFor(d)))
            let ran = command(state, { tr in state = state.apply(tr) }, nil)
            if let result { try expectEqual(state.doc, result.node) }
            else { try expect(ran == false, "expected command to return false") }
        }
    }
    func cAttr() -> TaggedNode { tdAttrs(["test": .string("value")], p("x")) }

    // MARK: addColumnAfter
    tcase("addColumnAfter: plain column", table(tr(c11(), cCursor(), c11()), tr(c11(), c11(), c11())), addColumnAfter,
          table(tr(c11(), c11(), cEmpty(), c11()), tr(c11(), c11(), cEmpty(), c11())))
    tcase("addColumnAfter: at right edge", table(tr(c11(), c11()), tr(c11(), cCursor())), addColumnAfter,
          table(tr(c11(), c11(), cEmpty()), tr(c11(), c11(), cEmpty())))
    tcase("addColumnAfter: second cell", table(tr(cCursor())), addColumnAfter, table(tr(c11(), cEmpty())))
    tcase("addColumnAfter: grow a colspan cell", table(tr(cCursor(), c11()), tr(cell(2, 1))), addColumnAfter,
          table(tr(c11(), cEmpty(), c11()), tr(cell(3, 1))))
    tcase("addColumnAfter: with row spans", table(tr(c11(), cell(1, 2), cell(1, 2)), tr(c11()), tr(c11(), cCursor(), c11())), addColumnAfter,
          table(tr(c11(), cell(1, 2), cEmpty(), cell(1, 2)), tr(c11(), cEmpty()), tr(c11(), c11(), cEmpty(), c11())))
    tcase("addColumnAfter: cell node selection", table(tr("<node>", c11(), c11()), tr(c11(), c11())), addColumnAfter,
          table(tr(c11(), cEmpty(), c11()), tr(c11(), cEmpty(), c11())))
    tcase("addColumnAfter: preserves header rows", table(tr(h11(), h11()), tr(c11(), cCursor())), addColumnAfter,
          table(tr(h11(), h11(), hEmpty()), tr(c11(), c11(), cEmpty())))
    tcase("addColumnAfter: nothing outside a table", doc(p("foo<cursor>")), addColumnAfter, nil)
    tcase("addColumnAfter: preserves column widths",
          table(tr(cAnchor(), c11()), tr(tdAttrs(["colspan": .int(2), "colwidth": .array([.int(100), .int(200)])], p("a")))), addColumnAfter,
          table(tr(cAnchor(), cEmpty(), c11()), tr(tdAttrs(["colspan": .int(3), "colwidth": .array([.int(100), .int(0), .int(200)])], p("a")))))

    // MARK: addColumnBefore
    tcase("addColumnBefore: plain", table(tr(c11(), c11(), c11()), tr(c11(), cCursor(), c11())), addColumnBefore,
          table(tr(c11(), cEmpty(), c11(), c11()), tr(c11(), cEmpty(), c11(), c11())))
    tcase("addColumnBefore: at left edge", table(tr(cCursor(), c11()), tr(c11(), c11())), addColumnBefore,
          table(tr(cEmpty(), c11(), c11()), tr(cEmpty(), c11(), c11())))
    tcase("addColumnBefore: left side of a cell selection", table(tr(cAnchor(), c11()), tr(c11(), c11())), addColumnBefore,
          table(tr(cEmpty(), c11(), c11()), tr(cEmpty(), c11(), c11())))

    // MARK: deleteColumn
    tcase("deleteColumn: plain", table(tr(cEmpty(), c11(), c11()), tr(c11(), cCursor(), c11()), tr(c11(), c11(), cEmpty())), deleteColumn,
          table(tr(cEmpty(), c11()), tr(c11(), c11()), tr(c11(), cEmpty())))
    tcase("deleteColumn: first column", table(tr(cCursor(), cEmpty(), c11()), tr(c11(), c11(), c11())), deleteColumn,
          table(tr(cEmpty(), c11()), tr(c11(), c11())))
    tcase("deleteColumn: last column", table(tr(c11(), cEmpty(), cCursor()), tr(c11(), c11(), c11())), deleteColumn,
          table(tr(c11(), cEmpty()), tr(c11(), c11())))
    tcase("deleteColumn: reduce a colspan", table(tr(c11(), cCursor()), tr(cell(2, 1))), deleteColumn,
          table(tr(c11()), tr(c11())))
    tcase("deleteColumn: under a colspan cell", table(tr(c11(), tdAttrs(["colspan": .int(2)], p("<cursor>"))), tr(cEmpty(), c11(), c11())), deleteColumn,
          table(tr(c11()), tr(cEmpty())))
    tcase("deleteColumn: cell-selected column", table(tr(cEmpty(), cAnchor()), tr(c11(), cHead())), deleteColumn,
          table(tr(cEmpty()), tr(c11())))
    tcase("deleteColumn: leaves widths intact",
          table(tr(c11(), cAnchor(), c11()), tr(tdAttrs(["colspan": .int(3), "colwidth": .array([.int(100), .int(200), .int(300)])], p("y")))), deleteColumn,
          table(tr(c11(), c11()), tr(tdAttrs(["colspan": .int(2), "colwidth": .array([.int(100), .int(300)])], p("y")))))

    // MARK: addRowAfter / addRowBefore
    tcase("addRowAfter: simple", table(tr(cCursor(), c11()), tr(c11(), c11())), addRowAfter,
          table(tr(c11(), c11()), tr(cEmpty(), cEmpty()), tr(c11(), c11())))
    tcase("addRowAfter: at end", table(tr(c11(), c11()), tr(c11(), cCursor())), addRowAfter,
          table(tr(c11(), c11()), tr(c11(), c11()), tr(cEmpty(), cEmpty())))
    tcase("addRowAfter: increases rowspan", table(tr(cCursor(), cell(1, 2)), tr(c11())), addRowAfter,
          table(tr(c11(), cell(1, 3)), tr(cEmpty()), tr(c11())))
    tcase("addRowAfter: preserves header columns", table(tr(c11(), hCursor()), tr(c11(), h11())), addRowAfter,
          table(tr(c11(), h11()), tr(cEmpty(), hEmpty()), tr(c11(), h11())))
    tcase("addRowBefore: simple", table(tr(c11(), c11()), tr(cCursor(), c11())), addRowBefore,
          table(tr(c11(), c11()), tr(cEmpty(), cEmpty()), tr(c11(), c11())))
    tcase("addRowBefore: at start", table(tr(cCursor(), c11()), tr(c11(), c11())), addRowBefore,
          table(tr(cEmpty(), cEmpty()), tr(c11(), c11()), tr(c11(), c11())))

    // MARK: deleteRow
    tcase("deleteRow: simple", table(tr(c11(), cEmpty()), tr(cCursor(), c11()), tr(c11(), cEmpty())), deleteRow,
          table(tr(c11(), cEmpty()), tr(c11(), cEmpty())))
    tcase("deleteRow: first row", table(tr(c11(), cCursor()), tr(cEmpty(), c11()), tr(c11(), cEmpty())), deleteRow,
          table(tr(cEmpty(), c11()), tr(c11(), cEmpty())))
    tcase("deleteRow: last row", table(tr(cEmpty(), c11()), tr(c11(), cEmpty()), tr(c11(), cCursor())), deleteRow,
          table(tr(cEmpty(), c11()), tr(c11(), cEmpty())))
    tcase("deleteRow: shrink rowspan cells", table(tr(cell(1, 2), c11(), cell(1, 3)), tr(cCursor()), tr(c11(), c11())), deleteRow,
          table(tr(c11(), c11(), cell(1, 2)), tr(c11(), c11())))
    tcase("deleteRow: cell selection", table(tr(cAnchor(), c11()), tr(c11(), cEmpty())), deleteRow,
          table(tr(c11(), cEmpty())))

    // MARK: mergeCells / splitCell
    tcase("mergeCells: one cell does nothing", table(tr(cAnchor(), c11())), mergeCells, nil)
    tcase("mergeCells: across spanning cells does nothing", table(tr(cAnchor(), cell(2, 1)), tr(c11(), cHead(), c11())), mergeCells, nil)
    tcase("mergeCells: two cells in a column", table(tr(cAnchor(), cHead(), c11())), mergeCells,
          table(tr(tdAttrs(["colspan": .int(2)], p("x"), p("x")), c11())))
    tcase("mergeCells: two cells in a row", table(tr(cAnchor(), c11()), tr(cHead(), c11())), mergeCells,
          table(tr(tdAttrs(["rowspan": .int(2)], p("x"), p("x")), c11()), tr(c11())))
    tcase("splitCell: non-spanning does nothing", table(tr(cAnchor(), c11())), splitCell, nil)
    tcase("splitCell: split a col-spanning cell", table(tr(tdAttrs(["colspan": .int(2)], p("foo<anchor>")), c11())), splitCell,
          table(tr(td(p("foo")), cEmpty(), c11())))
    tcase("splitCell: split a row-spanning cell", table(tr(c11(), tdAttrs(["rowspan": .int(2)], p("foo<anchor>")), c11()), tr(c11(), c11())), splitCell,
          table(tr(c11(), td(p("foo")), c11()), tr(c11(), cEmpty(), c11())))

    // MARK: mergeOrSplit — the one command a toolbar button can call
    tcase("mergeOrSplit: merges what can be merged", table(tr(cAnchor(), cHead(), c11())), mergeOrSplit,
          table(tr(tdAttrs(["colspan": .int(2)], p("x"), p("x")), c11())))
    tcase("mergeOrSplit: splits a spanning cell when there is nothing to merge",
          table(tr(tdAttrs(["colspan": .int(2)], p("foo<anchor>")), c11())), mergeOrSplit,
          table(tr(td(p("foo")), cEmpty(), c11())))
    // One plain cell is neither: nothing to merge it with, nothing to split.
    tcase("mergeOrSplit: a single plain cell does nothing", table(tr(cAnchor(), c11())), mergeOrSplit, nil)
    // Merging wins when both are possible, so a selection over a spanning cell
    // joins it to its neighbour rather than taking it apart.
    tcase("mergeOrSplit: prefers merging over splitting",
          table(tr(tdAttrs(["colspan": .int(2)], p("x<anchor>")), cHead())), mergeOrSplit,
          table(tr(tdAttrs(["colspan": .int(3)], p("x"), p("x")))))

    // MARK: setCellAttr
    tcase("setCellAttr: set on parent cell", table(tr(cCursor(), c11())), setCellAttr("test", .string("value")), table(tr(cAttr(), c11())))
    tcase("setCellAttr: no-op when already set", table(tr(cCursor(), c11())), setCellAttr("test", .string("default")), nil)
    tcase("setCellAttr: across a cell selection", table(tr(c11(), cAnchor(), c11()), tr(cell(2, 1), cHead()), tr(c11(), c11(), c11())), setCellAttr("test", .string("value")),
          table(tr(c11(), cAttr(), cAttr()), tr(cell(2, 1), cAttr()), tr(c11(), c11(), c11())))

    // MARK: toggleHeaderRow / Column (deprecated logic)
    tcase("toggleHeaderRow: non-header → header", doc(table(tr(cCursor(), c11()), tr(c11(), c11()))), toggleHeaderRow,
          doc(table(tr(h11(), h11()), tr(c11(), c11()))))
    tcase("toggleHeaderRow: header → regular", doc(table(tr(hCursor(), h11()), tr(c11(), c11()))), toggleHeaderRow,
          doc(table(tr(c11(), c11()), tr(c11(), c11()))))
    tcase("toggleHeaderColumn: non-header → header", doc(table(tr(cCursor(), c11()), tr(c11(), c11()))), toggleHeaderColumn,
          doc(table(tr(h11(), c11()), tr(h11(), c11()))))

    // MARK: toggleHeader (new logic)
    tcase("toggleHeader row: header row w/ spans → regular",
          doc(p("x"), table(tr(head(2, 1), head(1, 2)), tr(cCursor(), c11()), tr(c11(), c11(), c11()))), toggleHeader(.row),
          doc(p("x"), table(tr(cell(2, 1), cell(1, 2)), tr(cCursor(), c11()), tr(c11(), c11(), c11()))))
    tcase("toggleHeader column: keeps first cell header when column header enabled",
          doc(p("x"), table(tr(h11(), c11()), tr(hCursor(), c11()), tr(h11(), c11()))), toggleHeader(.row),
          doc(p("x"), table(tr(h11(), h11()), tr(h11(), c11()), tr(h11(), c11()))))

    // MARK: keyboard cell navigation/selection (input.ts)
    test("PM tableShiftArrow: starts a cell selection across two cells") {
        let s = runCmd(table(tr(cCursor(), c11())), tableShiftArrow(.horiz, 1))
        try expect(s.selection is CellSelection, "expected CellSelection")
        try expectEqual(s.selection.ranges.count, 2)
    }
    test("PM tableShiftArrow: extends an existing cell selection downward") {
        let d = table(tr(cAnchor(), c11()), tr(c11(), c11()))
        let s = runCmd(d, tableShiftArrow(.vert, 1))
        try expect(s.selection is CellSelection)
        try expectEqual(s.selection.ranges.count, 2) // anchor cell + the one below
    }
    test("PM tableArrow: moves into the next cell from a cell edge") {
        let d = table(tr(cCursor(), c11()))
        let s = runCmd(d, tableArrow(.horiz, 1))
        try expect(s.selection is TextSelection)
        try expect(s.selection.head > (d.tags["cursor"] ?? 0), "cursor advanced into the next cell")
    }
    test("PM tableArrow: collapses a cell selection to its head") {
        let d = table(tr(cAnchor(), cHead()))
        let s = runCmd(d, tableArrow(.horiz, 1))
        try expect(!(s.selection is CellSelection), "cell selection collapsed")
    }
}
