import DocumentModel

// Row/column reordering helpers, ported from prosemirror-tables' utils
// (transpose / convert / move-row-in-array-of-rows). Pure data transforms over a
// table's cell matrix; `moveColumn` reuses them by transposing first.

/// Transpose a 2D array (flip rows ↔ columns). Ragged input doesn't trap:
/// rows shorter than the first simply don't contribute to later columns.
public func transpose<T>(_ array: [[T]]) -> [[T]] {
    guard let first = array.first else { return [] }
    return first.indices.map { i in
        array.filter { i < $0.count }.map { $0[i] }
    }
}

/// A table node → matrix of rows×columns, with `nil` where a spanning cell from
/// above/left covers the slot.
public func convertTableNodeToArrayOfRows(_ tableNode: Node) -> [[Node?]] {
    let map = TableMap.get(tableNode)
    var rows: [[Node?]] = []
    for rowIndex in 0..<map.height {
        var row: [Node?] = []
        for colIndex in 0..<map.width {
            let cellIndex = rowIndex * map.width + colIndex
            let cellPos = map.map[cellIndex]
            if rowIndex > 0, map.map[cellIndex - map.width] == cellPos { row.append(nil); continue }
            if colIndex > 0, map.map[cellIndex - 1] == cellPos { row.append(nil); continue }
            row.append(tableNode.nodeAt(cellPos))
        }
        rows.append(row)
    }
    return rows
}

/// The inverse: a matrix of cells (nils skipped) back into a table node, keeping
/// the original row/table attrs. Returns nil if any cell, row, or the table
/// fails validation — the move must succeed whole or fail whole (upstream lets
/// createChecked throw); silently dropping a cell would corrupt the table.
public func convertArrayOfRowsToTableNode(_ tableNode: Node, _ arrayOfNodes: [[Node?]]) -> Node? {
    let map = TableMap.get(tableNode)
    var newRows: [Node] = []
    for rowIndex in 0..<map.height {
        let oldRow = tableNode.child(rowIndex)
        var newCells: [Node] = []
        for colIndex in 0..<map.width {
            guard rowIndex < arrayOfNodes.count, colIndex < arrayOfNodes[rowIndex].count,
                  let cell = arrayOfNodes[rowIndex][colIndex] else { continue }
            let cellPos = map.map[rowIndex * map.width + colIndex]
            guard let oldCell = tableNode.nodeAt(cellPos),
                  let newCell = try? oldCell.type.createChecked(cell.attrs, content: cell.content, marks: cell.marks)
            else { return nil }
            newCells.append(newCell)
        }
        guard let newRow = try? oldRow.type.createChecked(oldRow.attrs, content: Fragment.from(newCells), marks: oldRow.marks)
        else { return nil }
        newRows.append(newRow)
    }
    return try? tableNode.type.createChecked(tableNode.attrs, content: Fragment.from(newRows), marks: tableNode.marks)
}

/// Move the rows at `indexesOrigin` to `indexesTarget` within an array of rows.
public func moveRowInArrayOfRows<T>(_ rows: [T], _ indexesOrigin: [Int], _ indexesTarget: [Int], _ directionOverride: Int) -> [T] {
    guard let originStart = indexesOrigin.first, let targetStart = indexesTarget.first,
          let targetEnd = indexesTarget.last else { return rows }
    var rows = rows
    let direction = originStart > targetStart ? -1 : 1
    let removeEnd = min(originStart + indexesOrigin.count, rows.count)
    guard originStart >= 0, originStart <= removeEnd else { return rows }
    let rowsExtracted = Array(rows[originStart..<removeEnd])
    rows.removeSubrange(originStart..<removeEnd)
    let positionOffset = rowsExtracted.count % 2 == 0 ? 1 : 0
    let target: Int
    if directionOverride == -1, direction == 1 { target = targetStart - 1 }
    else if directionOverride == 1, direction == -1 { target = targetEnd - positionOffset + 1 }
    else { target = direction == -1 ? targetStart : targetEnd - positionOffset }
    rows.insert(contentsOf: rowsExtracted, at: max(0, min(target, rows.count)))
    return rows
}
