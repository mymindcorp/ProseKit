import DocumentModel
import DocumentTransform
import EditorStateKit

// Row/column move, ported from prosemirror-tables src/utils/{move-row,
// move-column, selection-range, get-cells, query}.ts (official ProseMirror).

/// The closest parent matching a predicate: its node, the position before it,
/// its start, and its depth (prosemirror-tables' FindNodeResult).
struct FoundNode {
    let node: Node
    let pos: Int
    let start: Int
    let depth: Int
}

func findParentNode(_ predicate: (Node) -> Bool, _ pos: ResolvedPos) -> FoundNode? {
    var depth = pos.depth
    while depth >= 0 {
        let node = pos.node(depth)
        if predicate(node) {
            return FoundNode(node: node,
                             pos: depth == 0 ? 0 : pos.before(depth),
                             start: pos.start(depth),
                             depth: depth)
        }
        depth -= 1
    }
    return nil
}

/// Find the closest table around a position.
func findTable(_ pos: ResolvedPos) -> FoundNode? {
    findParentNode({ tableRole($0) == "table" }, pos)
}

/// The cells (with absolute positions) in the column at `columnIndex` of the
/// table around the selection.
func getCellsInColumn(_ columnIndex: Int, _ tr: Transaction) -> [FoundNode]? {
    cells(tr, columnIndex, isColumn: true)
}

/// The cells (with absolute positions) in the row at `rowIndex`.
func getCellsInRow(_ rowIndex: Int, _ tr: Transaction) -> [FoundNode]? {
    cells(tr, rowIndex, isColumn: false)
}

private func cells(_ tr: Transaction, _ index: Int, isColumn: Bool) -> [FoundNode]? {
    guard let table = findTable(tr.doc.resolve(tr.selection.from)) else { return nil }
    let map = TableMap.get(table.node)
    if isColumn {
        guard index >= 0, index <= map.width - 1 else { return nil }
    } else {
        guard index >= 0, index <= map.height - 1 else { return nil }
    }
    let rect = isColumn
        ? TableRect(left: index, top: 0, right: index + 1, bottom: map.height)
        : TableRect(left: 0, top: index, right: map.width, bottom: index + 1)
    return map.cellsInRect(rect).map { nodePos in
        let node = table.node.nodeAt(nodePos)!
        let pos = nodePos + table.start
        return FoundNode(node: node, pos: pos, start: pos + 1, depth: table.depth + 2)
    }
}

/// A rectangular selection range spanning all merged cells around a row or
/// column: anchor/head cell positions plus the covered indexes.
struct CellSelectionRange {
    let anchor: ResolvedPos
    let head: ResolvedPos
    let indexes: [Int]
}

/// The selection range around the column at `startColIndex`, widened over
/// merged cells (prosemirror-tables getSelectionRangeInColumn).
func getSelectionRangeInColumn(_ tr: Transaction, _ startColIndex: Int) -> CellSelectionRange? {
    selectionRange(tr, startColIndex, isColumn: true)
}

/// The selection range around the row at `startRowIndex`, widened over merged
/// cells (prosemirror-tables getSelectionRangeInRow).
func getSelectionRangeInRow(_ tr: Transaction, _ startRowIndex: Int) -> CellSelectionRange? {
    selectionRange(tr, startRowIndex, isColumn: false)
}

private func selectionRange(_ tr: Transaction, _ startIdx: Int, isColumn: Bool) -> CellSelectionRange? {
    func cellsAt(_ i: Int) -> [FoundNode]? {
        isColumn ? getCellsInColumn(i, tr) : getCellsInRow(i, tr)
    }
    func span(_ node: Node) -> Int { isColumn ? cellColspan(node) : cellRowspan(node) }

    var startIndex = startIdx
    var endIndex = startIdx
    // Walk back to the start of any merged block covering startIdx...
    var i = startIdx
    while i >= 0 {
        if let found = cellsAt(i) {
            for cell in found {
                let maybeEnd = span(cell.node) + i - 1
                if maybeEnd >= startIndex { startIndex = i }
                if maybeEnd > endIndex { endIndex = maybeEnd }
            }
        }
        i -= 1
    }
    // ...then forward to its end.
    i = startIdx
    while i <= endIndex {
        if let found = cellsAt(i) {
            for cell in found where span(cell.node) > 1 {
                let maybeEnd = span(cell.node) + i - 1
                if maybeEnd > endIndex { endIndex = maybeEnd }
            }
        }
        i += 1
    }
    // Filter out rows/columns without their own cells (fully covered by spans).
    var indexes: [Int] = []
    for j in startIndex...endIndex where !(cellsAt(j) ?? []).isEmpty { indexes.append(j) }
    guard let first = indexes.first, let last = indexes.last else { return nil }
    startIndex = first
    endIndex = last

    guard let firstSelected = cellsAt(startIndex), !firstSelected.isEmpty,
          let firstPerpendicular = isColumn ? getCellsInRow(0, tr) : getCellsInColumn(0, tr)
    else { return nil }

    let anchor = tr.doc.resolve(firstSelected[firstSelected.count - 1].pos)

    var headCell: FoundNode?
    var k = endIndex
    outer: while k >= startIndex {
        if let found = cellsAt(k), !found.isEmpty {
            for perp in firstPerpendicular.reversed() where perp.pos == found[0].pos {
                headCell = found[0]
                break outer
            }
        }
        k -= 1
    }
    guard let headCell else { return nil }
    return CellSelectionRange(anchor: anchor, head: tr.doc.resolve(headCell.pos), indexes: indexes)
}

/// Move the row at `originIndex` to `targetIndex` in the table around `pos`,
/// mutating `tr`. Merged blocks move as units; a move into the middle of a
/// merged block, out of the table, or onto itself returns false with `tr`
/// untouched. With `select`, the moved row ends up selected.
@discardableResult
public func moveRow(_ tr: Transaction, originIndex: Int, targetIndex: Int,
                    select: Bool = true, pos: Int) -> Bool {
    guard let table = findTable(tr.doc.resolve(pos)),
          let indexesOrigin = getSelectionRangeInRow(tr, originIndex)?.indexes,
          let indexesTarget = getSelectionRangeInRow(tr, targetIndex)?.indexes,
          !indexesOrigin.contains(targetIndex)
    else { return false }

    let rows = moveRowInArrayOfRows(convertTableNodeToArrayOfRows(table.node),
                                    indexesOrigin, indexesTarget, 0)
    guard let newTable = convertArrayOfRowsToTableNode(table.node, rows),
          (try? tr.replaceWith(table.pos, table.pos + table.node.nodeSize, newTable)) != nil
    else { return false }

    if select {
        // Upstream uses positionAt(row, width-1), but that returns a row-end
        // (non-cell) position when the edge slot is covered by a span from
        // another row; selecting the row's real cells is span-safe.
        let map = TableMap.get(newTable)
        let cells = map.cellsInRect(TableRect(left: 0, top: targetIndex, right: map.width, bottom: targetIndex + 1))
        if let first = cells.first, let last = cells.last {
            tr.setSelection(CellSelection.rowSelection(tr.doc.resolve(table.start + last),
                                                       tr.doc.resolve(table.start + first)))
        }
    }
    return true
}

/// Move the column at `originIndex` to `targetIndex` (see `moveRow`).
@discardableResult
public func moveColumn(_ tr: Transaction, originIndex: Int, targetIndex: Int,
                       select: Bool = true, pos: Int) -> Bool {
    guard let table = findTable(tr.doc.resolve(pos)),
          let indexesOrigin = getSelectionRangeInColumn(tr, originIndex)?.indexes,
          let indexesTarget = getSelectionRangeInColumn(tr, targetIndex)?.indexes,
          !indexesOrigin.contains(targetIndex)
    else { return false }

    let columns = moveRowInArrayOfRows(transpose(convertTableNodeToArrayOfRows(table.node)),
                                       indexesOrigin, indexesTarget, 0)
    guard let newTable = convertArrayOfRowsToTableNode(table.node, transpose(columns)),
          (try? tr.replaceWith(table.pos, table.pos + table.node.nodeSize, newTable)) != nil
    else { return false }

    if select {
        // Span-safe column selection (see moveRow).
        let map = TableMap.get(newTable)
        let cells = map.cellsInRect(TableRect(left: targetIndex, top: 0, right: targetIndex + 1, bottom: map.height))
        if let first = cells.first, let last = cells.last {
            tr.setSelection(CellSelection.colSelection(tr.doc.resolve(table.start + last),
                                                       tr.doc.resolve(table.start + first)))
        }
    }
    return true
}
