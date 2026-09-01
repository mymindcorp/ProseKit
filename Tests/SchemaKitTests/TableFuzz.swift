import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for the table map, and for the promise `fixTables` makes.
//
// Every table command, every cell selection and every column resize reads the
// document through `TableMap`: a grid of cell offsets that `findCell`,
// `nextCell`, `cellsInRect` and `positionAt` all do arithmetic on. The map has
// no checks of its own beyond the `problems` it reports, and two of its readers
// end in `fatalError`. So the map is asked to agree with the table it was built
// from, cell by cell — and, after every edit an editor can make, every table
// in the document is asked to have no problems left, which is what the
// `fixTables` plugin exists to guarantee.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerTableFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("table fuzz: the map of every generated table agrees with the table") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 60) {
            try eachTable(in: doc) { table, pos in
                try checkTableMap(table, "table at \(pos) in \(seed)")
            }
        }
    }

    test("table fuzz: after every edit, every table is square and its map holds") {
        // A table-biased session: the general driver, with a table put in first
        // and table commands run about half the time, so cells get merged,
        // split, added and deleted around the other edits rather than only
        // beside them.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 43 &+ 5)
            let editor = try Editor(extensions: fuzzKit())
            var log: [String] = []

            _ = editor.insertTable(rows: Int.random(in: 1 ... 4, using: &rng),
                                   cols: Int.random(in: 1 ... 4, using: &rng),
                                   withHeaderRow: Bool.random(using: &rng))
            for _ in 0 ..< fuzzOpCount {
                if Bool.random(using: &rng) {
                    let cells = fuzzCellPositions(editor.doc)
                    if cells.count >= 2, Int.random(in: 0 ..< 3, using: &rng) == 0 {
                        let a = cells.randomElement(using: &rng)!, b = cells.randomElement(using: &rng)!
                        editor.dispatch(editor.state.tr.setSelection(CellSelection.create(editor.doc, a, b)))
                        log.append("cellSelect(\(a), \(b))")
                    } else if let cell = cells.randomElement(using: &rng) {
                        editor.dispatch(editor.state.tr.setSelection(
                            Selection.near(editor.doc.resolve(Swift.min(cell + 2, editor.doc.content.size)))))
                        log.append("cursor(\(cell + 2))")
                    }
                    switch Int.random(in: 0 ..< 6, using: &rng) {
                    case 0 where !cells.isEmpty:
                        // Move a row or a column, by index, from the table
                        // under a random cell.
                        let cell = cells.randomElement(using: &rng)!
                        // `cell` is the position in front of the cell, inside
                        // its row, so the table is one level up from there.
                        let map = TableMap.get(editor.doc.resolve(cell).node(-1))
                        let rows = Bool.random(using: &rng)
                        let count = rows ? map.height : map.width
                        let origin = Int.random(in: 0 ..< Swift.max(1, count), using: &rng)
                        let target = Int.random(in: 0 ..< Swift.max(1, count), using: &rng)
                        let tr = editor.state.tr
                        let ok = rows ? moveRow(tr, originIndex: origin, targetIndex: target, pos: cell + 1)
                                      : moveColumn(tr, originIndex: origin, targetIndex: target, pos: cell + 1)
                        if ok { editor.dispatch(tr) }
                        log.append("move\(rows ? "Row" : "Column")(\(origin) → \(target)) -> \(ok)")
                    case 1 where !cells.isEmpty:
                        // A column width on one cell — sometimes one that
                        // doesn't match its colspan, which is a `problem` the
                        // fixer has to square up.
                        let cell = cells.randomElement(using: &rng)!
                        let widths: AttributeValue = [.null, .array([.int(100)]), .array([.int(80), .int(120)]),
                                                      .array([]), .array([.int(0)]), .array([.int(-5)])].randomElement(using: &rng)!
                        let tr = editor.state.tr
                        _ = try? tr.setNodeAttribute(cell, "colwidth", widths)
                        editor.dispatch(tr)
                        log.append("colwidth(\(cell)) = \(widths)")
                    default:
                        let cmd = tableFuzzCommands.randomElement(using: &rng)!
                        log.append("run(\(cmd)) -> \(editor.run(cmd))")
                    }
                } else {
                    log.append(fuzzStep(editor, &rng))
                }
                let ctx = "seed \(seed) — \(log.suffix(4).joined(separator: " | "))"
                var invalid: (any Error)?
                do { try editor.doc.check() } catch { invalid = error }
                try expect(invalid == nil, "an invalid document at \(ctx): \(invalid.map { "\($0)" } ?? "")")
                try eachTable(in: editor.doc) { table, pos in
                    let map = TableMap.get(table)
                    try expect(map.problems?.isEmpty ?? true,
                               "fixTables left a table with problems \(map.problems ?? []) at \(pos) — \(ctx)\n\(fuzzOutline(table))")
                    try checkTableMap(table, "table at \(pos) — \(ctx)")
                }
                try checkSelectionValid(editor.state.selection, in: editor.doc, ctx)
            }
        }
    }
}

private let tableFuzzCommands = [
    "addColumnBefore", "addColumnAfter", "deleteColumn", "addRowBefore", "addRowAfter", "deleteRow",
    "mergeCells", "splitCell", "mergeOrSplit", "toggleHeaderRow", "toggleHeaderColumn", "toggleHeaderCell",
    "goToNextCell", "goToPreviousCell", "deleteTable",
]

private func eachTable(in doc: Node, _ body: (Node, Int) throws -> Void) throws {
    var tables: [(Node, Int)] = []
    doc.descendants { node, pos, _, _ in
        if node.type.name == "table" { tables.append((node, pos)) }
        return true
    }
    for (table, pos) in tables { try body(table, pos) }
}

/// Everything the map has to say about the table it came from.
func checkTableMap(_ table: Node, _ ctx: @autoclosure () -> String) throws {
    let map = TableMap.get(table)
    let what = "\(map.width)x\(map.height) map — \(ctx())"
    try expectEqual(map.height, table.childCount, "the map's height is not the row count: \(what)")
    try expectEqual(map.map.count, map.width * map.height, "the grid is the wrong size: \(what)")
    guard map.width > 0, map.height > 0 else { return }

    // The cells the table actually holds, as offsets from the table's start —
    // the coordinate the map speaks in.
    var cells: [Int: Node] = [:]
    var ordered: [Int] = []
    var offset = 0
    for r in 0 ..< table.childCount {
        let row = table.child(r)
        var cellOffset = offset + 1
        for c in 0 ..< row.childCount {
            let cell = row.child(c)
            cells[cellOffset] = cell
            ordered.append(cellOffset)
            cellOffset += cell.nodeSize
        }
        offset += row.nodeSize
    }

    // Every grid entry is a cell, and every cell is in the grid.
    let entries = Set(map.map)
    for entry in entries {
        try expect(cells[entry] != nil, "grid entry \(entry) is not a cell of the table: \(what)")
        try expect(table.nodeAt(entry).map { fuzzCellTypeNames.contains($0.type.name) } == true,
                   "nodeAt(\(entry)) is not a cell: \(what)")
    }
    let clean = map.problems?.isEmpty ?? true
    if clean {
        for pos in ordered {
            try expect(entries.contains(pos), "cell at \(pos) is missing from the grid: \(what)")
        }
    }

    for pos in ordered where entries.contains(pos) {
        let rect = map.findCell(pos)
        let cell = cells[pos]!
        let where_ = "cell at \(pos) [\(rect.left),\(rect.top))–(\(rect.right),\(rect.bottom)] — \(what)"
        try expect(rect.left >= 0 && rect.left < rect.right && rect.right <= map.width, "bad columns: \(where_)")
        try expect(rect.top >= 0 && rect.top < rect.bottom && rect.bottom <= map.height, "bad rows: \(where_)")
        try expectEqual(map.map[rect.top * map.width + rect.left], pos, "the rect's corner is a different cell: \(where_)")
        try expectEqual(map.colCount(pos), rect.left, "colCount disagrees with findCell: \(where_)")
        if clean {
            try expectEqual(rect.right - rect.left, cell.attrs["colspan"]?.intValue ?? 1, "rect width is not the colspan: \(where_)")
            try expectEqual(rect.bottom - rect.top, cell.attrs["rowspan"]?.intValue ?? 1, "rect height is not the rowspan: \(where_)")
            // Every grid slot the rect covers is this cell, and nothing else is.
            for row in 0 ..< map.height {
                for col in 0 ..< map.width {
                    let inside = row >= rect.top && row < rect.bottom && col >= rect.left && col < rect.right
                    try expectEqual(map.map[row * map.width + col] == pos, inside,
                                    "grid slot (\(col),\(row)) disagrees with the rect: \(where_)")
                }
            }
        }
        for axis in [TableAxis.horiz, .vert] {
            for dir in [-1, 1] {
                if let next = map.nextCell(pos, axis, dir) {
                    try expect(entries.contains(next), "nextCell gave \(next), which is not a cell: \(where_)")
                    try expect(next != pos, "nextCell stayed on the same cell: \(where_)")
                }
            }
        }
    }

    // The whole rectangle lists every cell once, in reading order.
    let all = map.cellsInRect(TableRect(left: 0, top: 0, right: map.width, bottom: map.height))
    try expectEqual(Set(all).count, all.count, "cellsInRect repeats a cell: \(what)")
    if clean {
        try expectEqual(all, ordered.filter { entries.contains($0) }, "cellsInRect is not the table's cells in order: \(what)")
    }

    // Every row/column has a position, inside the table, that is a cell start
    // or the end of its row.
    for row in 0 ..< map.height {
        for col in 0 ... map.width {
            let pos = map.positionAt(row, Swift.min(col, map.width), table)
            try expect(pos >= 0 && pos <= table.content.size, "positionAt(\(row), \(col)) = \(pos) is outside the table: \(what)")
        }
    }
}
