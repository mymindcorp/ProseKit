public import DocumentModel
import DocumentTransform
public import EditorStateKit

// Cell copy/paste, ported from prosemirror-tables' copypaste.ts. Pasting cells
// into a table places the block so its top-left aligns with the target cell
// (growing the table if needed); pasting into a cell selection clips/repeats the
// pasted cells to the selection rectangle.

/// A rectangular block of pasted cells (one Fragment of cells per row).
public struct CellArea {
    public let width: Int
    public let height: Int
    public let rows: [Fragment]
}

/// Extract a rectangular area of cells from a slice, or nil if its outer nodes
/// aren't table cells/rows.
public func pastedCells(_ slice: Slice) -> CellArea? {
    if slice.size == 0 { return nil }
    var content = slice.content
    var openStart = slice.openStart, openEnd = slice.openEnd
    while content.childCount == 1 && ((openStart > 0 && openEnd > 0) || tableRole(content.child(0)) == "table") {
        openStart -= 1; openEnd -= 1
        content = content.child(0).content
    }
    let first = content.child(0)
    let role = tableRole(first)
    let schema = first.type.schema!
    var rows: [Fragment] = []
    if role == "row" {
        for i in 0..<content.childCount {
            var cells = content.child(i).content
            let left = i != 0 ? 0 : max(0, openStart - 1)
            let right = i < content.childCount - 1 ? 0 : max(0, openEnd - 1)
            if left != 0 || right != 0 {
                cells = fitSlice(tableNodeTypes(schema)["row"]!, Slice(content: cells, openStart: left, openEnd: right)).content
            }
            rows.append(cells)
        }
    } else if role == "cell" || role == "header_cell" {
        rows.append(openStart != 0 || openEnd != 0
            ? fitSlice(tableNodeTypes(schema)["row"]!, Slice(content: content, openStart: openStart, openEnd: openEnd)).content
            : content)
    } else {
        return nil
    }
    return ensureRectangular(schema, rows)
}

private func ensureRectangular(_ schema: Schema, _ rows0: [Fragment]) -> CellArea {
    var rows = rows0
    var widths: [Int] = []
    func ensureW(_ i: Int) { while widths.count <= i { widths.append(0) } }
    for i in 0..<rows.count {
        let row = rows[i]
        var j = row.childCount - 1
        while j >= 0 {
            let cell = row.child(j)
            for r in i..<(i + cellRowspan(cell)) { ensureW(r); widths[r] += cellColspan(cell) }
            j -= 1
        }
    }
    var width = 0
    for w in widths { width = max(width, w) }
    for r in 0..<widths.count {
        if r >= rows.count { rows.append(Fragment.empty) }
        if widths[r] < width {
            let empty = tableNodeTypes(schema)["cell"]!.createAndFill()!
            var cells: [Node] = []
            for _ in widths[r]..<width { cells.append(empty) }
            rows[r] = rows[r].append(Fragment.from(cells))
        }
    }
    return CellArea(width: width, height: rows.count, rows: rows)
}

public func fitSlice(_ nodeType: NodeType, _ slice: Slice) -> Node {
    let node = nodeType.createAndFill()!
    let tr = Transform(node)
    _ = try? tr.replace(0, node.content.size, slice)
    return tr.doc
}

/// Clip or repeat the cells to cover the given width/height, clipping spans that
/// stick out at the edges.
public func clipCells(_ area: CellArea, _ newWidth: Int, _ newHeight: Int) -> CellArea {
    var width = area.width, height = area.height, rows = area.rows
    if width != newWidth {
        var added: [Int] = []
        func addedAt(_ i: Int) -> Int { i < added.count ? added[i] : 0 }
        func bumpAdded(_ i: Int, _ by: Int) { while added.count <= i { added.append(0) }; added[i] += by }
        var newRows: [Fragment] = []
        for row in 0..<rows.count {
            let frag = rows[row]
            var cells: [Node] = []
            var col = addedAt(row)
            var i = 0
            while col < newWidth {
                var cell = frag.child(i % frag.childCount)
                if col + cellColspan(cell) > newWidth {
                    cell = (try? cell.type.createChecked(removeColSpan(cell.attrs, cellColspan(cell), col + cellColspan(cell) - newWidth), content: cell.content)) ?? cell
                }
                cells.append(cell)
                col += cellColspan(cell)
                for j in 1..<max(1, cellRowspan(cell)) { bumpAdded(row + j, cellColspan(cell)) }
                i += 1
            }
            newRows.append(Fragment.from(cells))
        }
        rows = newRows; width = newWidth
    }
    if height != newHeight {
        var newRows: [Fragment] = []
        for row in 0..<newHeight {
            let source = rows[row % height]
            var cells: [Node] = []
            for j in 0..<source.childCount {
                var cell = source.child(j)
                if row + cellRowspan(cell) > newHeight {
                    var attrs = cell.attrs
                    attrs["rowspan"] = .int(max(1, newHeight - cellRowspan(cell)))
                    cell = (try? cell.type.create(attrs, content: cell.content)) ?? cell
                }
                cells.append(cell)
            }
            newRows.append(Fragment.from(cells))
        }
        rows = newRows; height = newHeight
    }
    return CellArea(width: width, height: height, rows: rows)
}

private func growTable(_ tr: Transaction, _ map: TableMap, _ table: Node, _ start: Int, _ width: Int, _ height: Int, _ mapFrom: Int) -> Bool {
    let types = tableNodeTypes(tr.doc.type.schema)
    var empty: Node?
    var emptyHead: Node?
    // Lazily build (and cache) a blank body/header cell; nil if the schema can't
    // fill one, in which case the caller simply skips growing that dimension.
    func cell() -> Node? { if empty == nil { empty = types["cell"]?.createAndFill() }; return empty }
    func headerCell() -> Node? { if emptyHead == nil { emptyHead = types["header_cell"]?.createAndFill() }; return emptyHead }
    if width > map.width {
        var rowEnd = 0
        for row in 0..<map.height {
            let rowNode = table.child(row)
            rowEnd += rowNode.nodeSize
            let isBodyCell = rowNode.lastChild == nil || rowNode.lastChild?.type === types["cell"]
            guard let add = isBodyCell ? cell() : headerCell() else { continue }
            var cells: [Node] = []
            for _ in map.width..<width { cells.append(add) }
            _ = try? tr.insert(tr.mapping.slice(mapFrom).map(rowEnd - 1 + start), Fragment.from(cells))
        }
    }
    if height > map.height {
        var cells: [Node] = []
        let startIndex = (map.height - 1) * map.width
        for i in 0..<max(map.width, width) {
            let header = i >= map.width ? false : (table.nodeAt(map.map[startIndex + i])?.type === types["header_cell"])
            guard let made = header ? headerCell() : cell() else { continue }
            cells.append(made)
        }
        if let rowType = types["row"], let emptyRow = try? rowType.create([:], content: Fragment.from(cells)) {
            var rows: [Node] = []
            for _ in map.height..<height { rows.append(emptyRow) }
            // NB: append at the end of the table content (tableStart-relative), not
            // the map index used above for the header check.
            _ = try? tr.insert(tr.mapping.slice(mapFrom).map(start + table.nodeSize - 2), Fragment.from(rows))
        }
    }
    return empty != nil || emptyHead != nil
}

private func isolateHorizontal(_ tr: Transaction, _ map: TableMap, _ table: Node, _ start: Int, _ left: Int, _ right: Int, _ top: Int, _ mapFrom: Int) -> Bool {
    if top == 0 || top == map.height { return false }
    var found = false
    var col = left
    while col < right {
        let index = top * map.width + col
        let pos = map.map[index]
        if map.map[index - map.width] == pos {
            found = true
            let cell = table.nodeAt(pos)!
            let cr = map.findCell(pos)
            var attrs = cell.attrs; attrs["rowspan"] = .int(top - cr.top)
            _ = try? tr.setNodeMarkup(tr.mapping.slice(mapFrom).map(pos + start), nil, attrs)
            var below = cell.attrs; below["rowspan"] = .int(cr.top + cellRowspan(cell) - top)
            _ = try? tr.insert(tr.mapping.slice(mapFrom).map(map.positionAt(top, cr.left, table)),
                               cell.type.createAndFill(below)!)
            col += cellColspan(cell) - 1
        }
        col += 1
    }
    return found
}

private func isolateVertical(_ tr: Transaction, _ map: TableMap, _ table: Node, _ start: Int, _ top: Int, _ bottom: Int, _ left: Int, _ mapFrom: Int) -> Bool {
    if left == 0 || left == map.width { return false }
    var found = false
    var row = top
    while row < bottom {
        let index = row * map.width + left
        let pos = map.map[index]
        if map.map[index - 1] == pos {
            found = true
            let cell = table.nodeAt(pos)!
            let cellLeft = map.colCount(pos)
            let updatePos = tr.mapping.slice(mapFrom).map(pos + start)
            _ = try? tr.setNodeMarkup(updatePos, nil, removeColSpan(cell.attrs, left - cellLeft, cellColspan(cell) - (left - cellLeft)))
            _ = try? tr.insert(updatePos + cell.nodeSize, cell.type.createAndFill(removeColSpan(cell.attrs, 0, left - cellLeft))!)
            row += cellRowspan(cell) - 1
        }
        row += 1
    }
    return found
}

/// Insert pasted cells into a table at the position pointed at by `rect`.
public func insertCells(_ state: EditorState, _ dispatch: (Transaction) -> Void, _ tableStart: Int, _ rect: TableRect, _ cells: CellArea) {
    var table = tableStart != 0 ? state.doc.nodeAt(tableStart - 1) : state.doc
    guard table != nil else { return }
    var map = TableMap.get(table!)
    let top = rect.top, left = rect.left
    let right = left + cells.width, bottom = top + cells.height
    let tr = state.tr
    var mapFrom = 0
    // Re-fetch the table after a structural step. Returns false (so the caller
    // bails, dispatching what's done) if the table node vanished — otherwise the
    // `table!` uses below would crash on a malformed table/position.
    func recomp() -> Bool {
        table = tableStart != 0 ? tr.doc.nodeAt(tableStart - 1) : tr.doc
        guard let t = table else { return false }
        map = TableMap.get(t)
        mapFrom = tr.mapping.maps.count
        return true
    }
    if growTable(tr, map, table!, tableStart, right, bottom, mapFrom), !recomp() { dispatch(tr); return }
    if isolateHorizontal(tr, map, table!, tableStart, left, right, top, mapFrom), !recomp() { dispatch(tr); return }
    if isolateHorizontal(tr, map, table!, tableStart, left, right, bottom, mapFrom), !recomp() { dispatch(tr); return }
    if isolateVertical(tr, map, table!, tableStart, top, bottom, left, mapFrom), !recomp() { dispatch(tr); return }
    if isolateVertical(tr, map, table!, tableStart, top, bottom, right, mapFrom), !recomp() { dispatch(tr); return }
    for row in top..<bottom {
        let from = map.positionAt(row, left, table!)
        let to = map.positionAt(row, right, table!)
        _ = try? tr.replace(tr.mapping.slice(mapFrom).map(from + tableStart),
                            tr.mapping.slice(mapFrom).map(to + tableStart),
                            Slice(content: cells.rows[row - top], openStart: 0, openEnd: 0))
    }
    guard recomp() else { dispatch(tr); return }
    tr.setSelection(CellSelection(tr.doc.resolve(tableStart + map.positionAt(top, left, table!)),
                                  tr.doc.resolve(tableStart + map.positionAt(bottom - 1, right - 1, table!))))
    dispatch(tr)
}
