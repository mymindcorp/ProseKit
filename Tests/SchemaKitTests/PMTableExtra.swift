import Foundation
import DocumentModel
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness
import DocumentTransform

// Ported from prosemirror-tables/test/{cellselection,fixtable}.test.ts — validates
// CellSelection (head/anchor placement, map-extension, content) + fixTables.

private func cw(_ width: Int) -> TaggedNode { tdAttrs(["colwidth": .array([.int(width)])], p("x")) }

func registerPMTableExtraTests() {
    // MARK: CellSelection head/anchor + map extension
    let grid = doc(table(tr(cEmpty(), cEmpty(), cEmpty()), tr(cEmpty(), cEmpty(), cEmpty()), tr(cEmpty(), cEmpty(), cEmpty()))).node

    @Sendable func cs(_ a: Int, _ h: Int) -> CellSelection { CellSelection.create(grid, a, h) as! CellSelection }
    test("PM CellSelection: head/anchor around the head cell") {
        var s = cs(2, 24); try expectEqual(s.anchor, 25); try expectEqual(s.head, 27)
        s = cs(24, 2); try expectEqual(s.anchor, 3); try expectEqual(s.head, 5)
        s = cs(10, 30); try expectEqual(s.anchor, 31); try expectEqual(s.head, 33)
        s = cs(30, 10); try expectEqual(s.anchor, 11); try expectEqual(s.head, 13)
    }

    @Sendable func run(_ anchor: Int, _ head: Int, _ command: @escaping Command) -> EditorState {
        var state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: grid, selection: CellSelection.create(grid, anchor, head)))
        _ = command(state, { tr in state = state.apply(tr) }, nil)
        return state
    }
    test("PM CellSelection: extends a row selection when adding a row") {
        var sel = run(34, 6, addRowBefore).selection as? CellSelection
        try expectEqual(sel?.anchorCell.pos, 48); try expectEqual(sel?.headCell.pos, 6)
        sel = run(6, 30, addRowAfter).selection as? CellSelection
        try expectEqual(sel?.anchorCell.pos, 6); try expectEqual(sel?.headCell.pos, 44)
    }
    test("PM CellSelection: extends a col selection when adding a column") {
        var sel = run(16, 24, addColumnAfter).selection as? CellSelection
        try expectEqual(sel?.anchorCell.pos, 20); try expectEqual(sel?.headCell.pos, 32)
        sel = run(24, 30, addColumnBefore).selection as? CellSelection
        try expectEqual(sel?.anchorCell.pos, 32); try expectEqual(sel?.headCell.pos, 38)
    }

    // MARK: CellSelection.content
    func contentCase(_ name: String, _ sel: TaggedNode, _ expectedTable: TaggedNode) {
        test("PM CellSelection content: \(name)") {
            let s = selectionFor(sel)
            try expect(s is CellSelection, "expected a CellSelection")
            try expectEqual(s.content(), Slice(content: expectedTable.node.content, openStart: 1, openEnd: 1))
        }
    }
    contentCase("only the selected cells",
                table(tr(c11(), cAnchor(), cEmpty()), tr(c11(), cEmpty(), cHead()), tr(c11(), c11(), c11())),
                table(tr(c11(), cEmpty()), tr(cEmpty(), c11())))
    contentCase("understands spanning cells",
                table(tr(cAnchor(), cell(2, 2), c11(), c11()), tr(c11(), cHead(), c11(), c11())),
                table(tr(c11(), cell(2, 2), c11()), tr(c11(), c11())))
    contentCase("cuts off cells sticking out horizontally",
                table(tr(c11(), cAnchor(), cell(2, 1)), tr(cell(4, 1)), tr(cell(2, 1), cHead(), c11())),
                table(tr(c11(), c11()), tr(tdAttrs(["colspan": .int(2)], p())), tr(cEmpty(), c11())))
    contentCase("cuts off cells sticking out vertically",
                table(tr(c11(), cell(1, 4), cell(1, 2)), tr(cAnchor()), tr(cell(1, 2), cHead()), tr(c11())),
                table(tr(c11(), tdAttrs(["rowspan": .int(2)], p()), cEmpty()), tr(c11(), c11())))
    contentCase("preserves column widths",
                table(tr(c11(), cAnchor(), c11()), tr(tdAttrs(["colspan": .int(3), "colwidth": .array([.int(100), .int(200), .int(300)])], p("x"))), tr(c11(), cHead(), c11())),
                table(tr(c11()), tr(tdAttrs(["colwidth": .array([.int(200)])], p())), tr(c11())))

    // MARK: fixTables
    @Sendable func fix(_ node: TaggedNode) -> Node? {
        let isDoc = node.node.type.name == "doc"
        let d = isDoc ? node.node : doc(node).node
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: d))
        guard let tr = fixTables(state, nil) else { return nil }
        return isDoc ? tr.doc : tr.doc.firstChild
    }
    func fixCase(_ name: String, _ input: TaggedNode, _ expected: TaggedNode?) {
        test("PM fixTable: \(name)") {
            let result = fix(input)
            if let expected { try expectEqual(result, expected.node) }
            else { try expect(result == nil, "expected no fix") }
        }
    }
    fixCase("doesn't touch correct tables", table(tr(c11(), c11(), cell(1, 2)), tr(c11(), c11())), nil)
    fixCase("adds trivially missing cells", table(tr(c11(), c11(), cell(1, 2)), tr(c11())),
            table(tr(c11(), c11(), cell(1, 2)), tr(c11(), cEmpty())))
    fixCase("can add to multiple rows", table(tr(c11()), tr(c11(), c11()), tr(cell(3, 1))),
            table(tr(c11(), cEmpty(), cEmpty()), tr(cEmpty(), c11(), c11()), tr(cell(3, 1))))
    fixCase("adds at the start of the first row", table(tr(c11()), tr(c11(), c11())),
            table(tr(cEmpty(), c11()), tr(c11(), c11())))
    fixCase("adds at the end of the non-first row", table(tr(c11(), c11()), tr(c11())),
            table(tr(c11(), c11()), tr(c11(), cEmpty())))
    fixCase("fixes overlapping cells", table(tr(c11(), cell(1, 2), c11()), tr(cell(2, 1))),
            table(tr(c11(), cell(1, 2), c11()), tr(c11(), cEmpty(), cEmpty())))
    fixCase("fixes a rowspan sticking out of the table", table(tr(c11(), c11()), tr(cell(1, 2), c11())),
            table(tr(c11(), c11()), tr(c11(), c11())))
    fixCase("makes column widths coherent", table(tr(c11(), c11(), cw(200)), tr(cw(100), c11(), c11())),
            table(tr(cw(100), c11(), cw(200)), tr(cw(100), c11(), cw(200))))
    fixCase("respects table role when inserting a cell", table(tr(h11()), tr(c11(), c11()), tr(cell(3, 1))),
            table(tr(h11(), hEmpty(), hEmpty()), tr(cEmpty(), c11(), c11()), tr(cell(3, 1))))
    fixCase("removes a zero-sized table", doc(table(tr()), table(tr(c11()))), doc(table(tr(c11()))))
    // Guards the walk's textblock prune: the descent must still pass through
    // table → row → cell to reach a table nested inside a cell.
    fixCase("fixes a table nested inside a cell",
            table(tr(td(p("x"), table(tr(c11(), c11()), tr(c11()))), c11())),
            table(tr(td(p("x"), table(tr(c11(), c11()), tr(c11(), cEmpty()))), c11())))

    test("PM fixTables: a selection-only transaction skips the fix pass") {
        // The fix pass walks the document, and it runs from appendTransaction —
        // on every transaction, including each tick of a selection drag. Only a
        // doc change can leave a table malformed, so a selection-only
        // transaction must not pay for (or perform) the walk. Observable from
        // outside: a malformed doc stays malformed across a selection change,
        // and is repaired by the first transaction that edits the document.
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func cell() throws -> Node {
            try s.node("tableCell", [:], content: Fragment.from([try s.node("paragraph")]))
        }
        let malformed = try s.node("doc", [:], content: Fragment.from([
            try s.node("table", [:], content: Fragment.from([
                try s.node("tableRow", [:], content: Fragment.from([cell(), cell()])),
                try s.node("tableRow", [:], content: Fragment.from([cell()])),
            ])),
            try s.node("paragraph", [:], content: Fragment.from([s.text("after")])),
        ]))
        let state = EditorState.create(EditorStateConfig(schema: s, doc: malformed,
                                                         plugins: editor.state.plugins))
        try expect(fixTables(state, nil) != nil, "the fixture must actually be malformed")

        let end = state.doc.content.size
        let selOnly = state.applyTransaction(
            state.tr.setSelection(TextSelection.create(state.doc, end - 2))).state
        try expectEqual(selOnly.doc, malformed, "a selection move must not rewrite the document")

        let tr = selOnly.tr
        _ = try tr.insertText("x", end - 2, end - 2)
        let edited = selOnly.applyTransaction(tr).state
        try expect(fixTables(edited, nil) == nil, "the first edit repairs the table")
    }

    // MARK: normalizeSelection (node-selection → cell-selection)
    let nt = doc(table(tr(c11(), c11(), c11()), tr(c11(), c11(), c11()), tr(c11(), c11(), c11()))).node
    @Sendable func normalize(_ sel: Selection, _ allow: Bool = false) -> Selection {
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: nt, selection: sel))
        return normalizeSelection(state, nil, allow)?.selection ?? state.selection
    }
    test("PM normalizeSelection: table node selection → all cells") {
        try expect(normalize(NodeSelection.create(nt, 0)).eq(CellSelection.create(nt, 2, 46)))
    }
    test("PM normalizeSelection: retains table node selection when allowed") {
        try expect(normalize(NodeSelection.create(nt, 0), true).eq(NodeSelection.create(nt, 0)))
    }
    test("PM normalizeSelection: row node selection → cell selection") {
        try expect(normalize(NodeSelection.create(nt, 1)).eq(CellSelection.create(nt, 2, 12)))
    }
    test("PM normalizeSelection: cell node selection → cell selection") {
        try expect(normalize(NodeSelection.create(nt, 2)).eq(CellSelection.create(nt, 2, 2)))
    }
}
