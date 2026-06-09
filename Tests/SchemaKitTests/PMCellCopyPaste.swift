import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestHarness

// Ported from prosemirror-tables/test/copypaste.test.ts.

private func rowsEqual(_ result: CellArea, _ content: [[TaggedNode]]) throws {
    for (i, row) in result.rows.enumerated() {
        try expectEqual(row, Fragment.from(content[i].map { $0.node }))
    }
}

func registerPMCellCopyPasteTests() {
    // MARK: pastedCells
    func pc(_ name: String, _ slice: TaggedNode, _ width: Int?, _ height: Int?, _ content: [[TaggedNode]]? = nil) {
        test("PM pastedCells: \(name)") {
            let result = pastedCells(slice.node.slice(tag(slice, "a"), tag(slice, "b")))
            if width == nil { try expect(result == nil, "expected nil"); return }
            try expect(result != nil, "expected cells")
            let r = result!
            try expectEqual(r.rows.count, r.height)
            try expectEqual(r.width, width!)
            try expectEqual(r.height, height!)
            if let content { try rowsEqual(r, content) }
        }
    }
    pc("simple cells", doc(table(tr("<a>", cEmpty(), cEmpty(), "<b>"))), 2, 1, [[cEmpty(), cEmpty()]])
    pc("cells wrapped in a row", table("<a>", tr(cEmpty(), cEmpty()), "<b>"), 2, 1, [[cEmpty(), cEmpty()]])
    pc("cursor inside cells", table(tr(td(p("<a>foo")), td(p("<b>bar")))), 2, 1, [[td(p("foo")), cEmpty()]])
    pc("multiple rows", table(tr("<a>", cEmpty(), cEmpty()), tr(cEmpty(), c11()), "<b>"), 2, 2, [[cEmpty(), cEmpty()], [cEmpty(), c11()]])
    pc("fully selected table", doc("<a>", table(tr(c11())), "<b>"), 1, 1, [[c11()]])
    pc("normalize a partially-selected row", table(tr(td(p(), "<a>"), cEmpty(), c11()), tr(c11(), c11()), "<b>"), 2, 2,
       [[cEmpty(), c11()], [c11(), c11()]])
    pc("rectangular result", table("<a>", tr(cell(2, 2), c11()), tr(), tr(c11(), c11()), "<b>"), 3, 3,
       [[cell(2, 2), c11()], [cEmpty()], [c11(), c11(), cEmpty()]])
    pc("rowspans sticking out", table("<a>", tr(cell(1, 3), c11()), "<b>"), 2, 3, [[cell(1, 3), c11()], [cEmpty()], [cEmpty()]])
    pc("null for non-cell selection", doc(p("foo<a>bar"), p("baz<b>")), nil, nil, nil)

    // MARK: clipCells
    func cc(_ name: String, _ slice: TaggedNode, _ width: Int, _ height: Int, _ content: [[TaggedNode]]) {
        test("PM clipCells: \(name)") {
            let r = clipCells(pastedCells(slice.node.slice(tag(slice, "a"), tag(slice, "b")))!, width, height)
            try expectEqual(r.rows.count, r.height)
            try expectEqual(r.width, width)
            try expectEqual(r.height, height)
            try rowsEqual(r, content)
        }
    }
    cc("clip off excess cells", table("<a>", tr(cEmpty(), c11()), tr(c11(), c11()), "<b>"), 1, 1, [[cEmpty()]])
    cc("pad by repeating cells", table("<a>", tr(cEmpty(), c11()), tr(c11(), cEmpty()), "<b>"), 4, 4,
       [[cEmpty(), c11(), cEmpty(), c11()], [c11(), cEmpty(), c11(), cEmpty()],
        [cEmpty(), c11(), cEmpty(), c11()], [c11(), cEmpty(), c11(), cEmpty()]])
    cc("rowspan counts toward width", table("<a>", tr(cell(2, 2), c11()), tr(c11()), "<b>"), 6, 2,
       [[cell(2, 2), c11(), cell(2, 2), c11()], [c11(), c11()]])
    cc("clip excess colspan", table("<a>", tr(cell(2, 2), c11()), tr(c11()), "<b>"), 4, 2,
       [[cell(2, 2), c11(), cell(1, 2)], [c11()]])
    cc("clip excess rowspan", table("<a>", tr(cell(2, 2), c11()), tr(c11()), "<b>"), 2, 3,
       [[cell(2, 2)], [], [cell(2, 1)]])

    // MARK: insertCells
    func ic(_ name: String, _ docN: TaggedNode, _ cellsN: TaggedNode, _ result: TaggedNode) {
        test("PM insertCells: \(name)") {
            var state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: docN.node))
            guard let cell = cellAround(docN.node.resolve(tag(docN, "anchor"))) else { try expect(false, "no cell"); return }
            var table: Node?
            var tableStart = 0
            docN.node.descendants { node, pos, _, _ in
                if node.type.name == "table" { table = node; tableStart = pos + 1 }
                return table == nil
            }
            guard let table else { try expect(false, "no table"); return }
            let map = TableMap.get(table)
            let cells = pastedCells(cellsN.node.slice(tag(cellsN, "a"), tag(cellsN, "b")))!
            insertCells(state, { tr in state = state.apply(tr) }, tableStart, map.findCell(cell.pos - tableStart), cells)
            try expectEqual(state.doc, result.node)
        }
    }
    ic("keeps the original cells",
       doc(table(tr(cAnchor(), c11(), c11()), tr(c11(), c11(), c11()))),
       doc(table(tr(td(p("<a>foo")), cEmpty()), tr(cell(2, 1), "<b>"))),
       doc(table(tr(td(p("foo")), cEmpty(), c11()), tr(cell(2, 1), c11()))))
    ic("makes the table big enough",
       doc(table(tr(cAnchor()))),
       doc(table(tr(td(p("<a>foo")), cEmpty()), tr(cell(2, 1), "<b>"))),
       doc(table(tr(td(p("foo")), cEmpty()), tr(cell(2, 1)))))
    ic("preserves headers while growing",
       doc(table(tr(h11(), h11(), h11()), tr(h11(), c11(), c11()), tr(h11(), c11(), cAnchor()))),
       doc(table(tr(td(p("<a>foo")), cEmpty()), tr(c11(), c11(), "<b>"))),
       doc(table(tr(h11(), h11(), h11(), hEmpty()), tr(h11(), c11(), c11(), cEmpty()),
                 tr(h11(), c11(), td(p("foo")), cEmpty()), tr(hEmpty(), cEmpty(), c11(), c11()))))
    ic("splits interfering rowspan cells",
       doc(table(tr(c11(), cell(1, 4), c11()), tr(cAnchor(), c11()), tr(c11(), c11()), tr(c11(), c11()))),
       doc(table(tr("<a>", cEmpty(), cEmpty(), cEmpty(), "<b>"))),
       doc(table(tr(c11(), c11(), c11()), tr(cEmpty(), cEmpty(), cEmpty()),
                 tr(c11(), tdAttrs(["rowspan": .int(2)], p()), c11()), tr(c11(), c11()))))
    ic("splits interfering colspan cells",
       doc(table(tr(c11(), cAnchor(), c11()), tr(cell(2, 1), c11()), tr(c11(), cell(2, 1)))),
       doc(table("<a>", tr(cEmpty()), tr(cEmpty()), tr(cEmpty()), "<b>")),
       doc(table(tr(c11(), cEmpty(), c11()), tr(c11(), cEmpty(), c11()), tr(c11(), cEmpty(), cEmpty()))))
}
