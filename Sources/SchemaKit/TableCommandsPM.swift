public import DocumentModel
import DocumentTransform
public import EditorStateKit
public import EditorCommands

// Table commands ported from prosemirror-tables' commands.ts — spanning-aware,
// operating on TableMap + CellSelection.

public typealias TableDirection = Int

/// The selected rectangle in a table, plus its map/node/start for convenience.
public struct SelectedRect {
    public var left, top, right, bottom: Int
    public var tableStart: Int
    public var map: TableMap
    public var table: Node
}

public func selectedRect(_ state: EditorState) -> SelectedRect? {
    let sel = state.selection
    guard let cell = selectionCell(state) else { return nil }
    let table = cell.node(-1)
    let tableStart = cell.start(-1)
    let map = TableMap.get(table)
    let rect: TableRect
    if let cs = sel as? CellSelection {
        rect = map.rectBetween(cs.anchorCell.pos - tableStart, cs.headCell.pos - tableStart)
    } else {
        rect = map.findCell(cell.pos - tableStart)
    }
    return SelectedRect(left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
                        tableStart: tableStart, map: map, table: table)
}

// MARK: - Columns

@discardableResult
public func addColumn(_ tr: Transaction, _ rect: SelectedRect, _ col: Int) -> Transaction {
    let map = rect.map, table = rect.table, tableStart = rect.tableStart
    var refColumn: Int? = col > 0 ? -1 : 0
    if let rc = refColumn, columnIsHeader(map, table, col + rc) {
        refColumn = (col == 0 || col == map.width) ? nil : 0
    }
    var row = 0
    while row < map.height {
        let index = row * map.width + col
        if col > 0, col < map.width, map.map[index - 1] == map.map[index] {
            let pos = map.map[index]
            let cell = table.nodeAt(pos)!
            _ = try? tr.setNodeMarkup(tr.mapping.map(tableStart + pos), nil,
                                      addColSpan(cell.attrs, col - map.colCount(pos)))
            row += cellRowspan(cell) - 1
        } else {
            let type: NodeType = refColumn == nil
                ? tableNodeTypes(table.type.schema)["cell"]!
                : table.nodeAt(map.map[index + refColumn!])!.type
            let pos = map.positionAt(row, col, table)
            _ = try? tr.insert(tr.mapping.map(tableStart + pos), type.createAndFill()!)
        }
        row += 1
    }
    return tr
}

public let addColumnBefore: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    if let dispatch, let rect = selectedRect(state) { dispatch(addColumn(state.tr, rect, rect.left)) }
    return true
}
public let addColumnAfter: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    if let dispatch, let rect = selectedRect(state) { dispatch(addColumn(state.tr, rect, rect.right)) }
    return true
}

func removeColumn(_ tr: Transaction, _ rect: SelectedRect, _ col: Int) {
    let map = rect.map, table = rect.table, tableStart = rect.tableStart
    let mapStart = tr.mapping.maps.count
    var row = 0
    while row < map.height {
        let index = row * map.width + col
        let pos = map.map[index]
        let cell = table.nodeAt(pos)!
        let attrs = cell.attrs
        if (col > 0 && map.map[index - 1] == pos) || (col < map.width - 1 && map.map[index + 1] == pos) {
            _ = try? tr.setNodeMarkup(tr.mapping.slice(mapStart).map(tableStart + pos), nil,
                                      removeColSpan(attrs, col - map.colCount(pos)))
        } else {
            let start = tr.mapping.slice(mapStart).map(tableStart + pos)
            _ = try? tr.delete(start, start + cell.nodeSize)
        }
        row += cellRowspan(cell)
    }
}

public let deleteColumn: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    if let dispatch {
        guard var rect = selectedRect(state) else { return false }
        let tr = state.tr
        if rect.left == 0 && rect.right == rect.map.width { return false }
        var i = rect.right - 1
        while true {
            removeColumn(tr, rect, i)
            if i == rect.left { break }
            let table = rect.tableStart != 0 ? tr.doc.nodeAt(rect.tableStart - 1) : tr.doc
            guard let table else { return false }
            rect.table = table
            rect.map = TableMap.get(table)
            i -= 1
        }
        dispatch(tr)
    }
    return true
}

// MARK: - Rows

public func rowIsHeader(_ map: TableMap, _ table: Node, _ row: Int) -> Bool {
    let headerCell = tableNodeTypes(table.type.schema)["header_cell"]
    for col in 0..<map.width {
        if table.nodeAt(map.map[col + row * map.width])?.type !== headerCell { return false }
    }
    return true
}

@discardableResult
public func addRow(_ tr: Transaction, _ rect: SelectedRect, _ row: Int) -> Transaction {
    let map = rect.map, table = rect.table, tableStart = rect.tableStart
    var rowPos = tableStart
    for i in 0..<row { rowPos += table.child(i).nodeSize }
    var cells: [Node] = []
    var refRow: Int? = row > 0 ? -1 : 0
    if let rr = refRow, rowIsHeader(map, table, row + rr) {
        refRow = (row == 0 || row == map.height) ? nil : 0
    }
    var col = 0
    var index = map.width * row
    while col < map.width {
        if row > 0, row < map.height, map.map[index] == map.map[index - map.width] {
            let pos = map.map[index]
            var attrs = table.nodeAt(pos)!.attrs
            attrs["rowspan"] = .int((attrs["rowspan"]?.intValue ?? 1) + 1)
            _ = try? tr.setNodeMarkup(tableStart + pos, nil, attrs)
            col += (attrs["colspan"]?.intValue ?? 1) - 1
        } else {
            let type: NodeType? = refRow == nil
                ? tableNodeTypes(table.type.schema)["cell"]
                : table.nodeAt(map.map[index + refRow! * map.width])?.type
            if let node = type?.createAndFill() { cells.append(node) }
        }
        col += 1; index += 1
    }
    let rowType = tableNodeTypes(table.type.schema)["row"]!
    if let row = try? rowType.create([:], content: Fragment.from(cells)) {
        _ = try? tr.insert(rowPos, row)
    }
    return tr
}

public let addRowBefore: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    if let dispatch, let rect = selectedRect(state) { dispatch(addRow(state.tr, rect, rect.top)) }
    return true
}
public let addRowAfter: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    if let dispatch, let rect = selectedRect(state) { dispatch(addRow(state.tr, rect, rect.bottom)) }
    return true
}

func removeRow(_ tr: Transaction, _ rect: SelectedRect, _ row: Int) {
    let map = rect.map, table = rect.table, tableStart = rect.tableStart
    var rowPos = 0
    for i in 0..<row { rowPos += table.child(i).nodeSize }
    let nextRow = rowPos + table.child(row).nodeSize
    let mapFrom = tr.mapping.maps.count
    _ = try? tr.delete(rowPos + tableStart, nextRow + tableStart)
    var seen = Set<Int>()
    var col = 0
    var index = row * map.width
    while col < map.width {
        let pos = map.map[index]
        defer { col += 1; index += 1 }
        if seen.contains(pos) { continue }
        seen.insert(pos)
        if row > 0, pos == map.map[index - map.width] {
            var attrs = table.nodeAt(pos)!.attrs
            attrs["rowspan"] = .int((attrs["rowspan"]?.intValue ?? 1) - 1)
            _ = try? tr.setNodeMarkup(tr.mapping.slice(mapFrom).map(pos + tableStart), nil, attrs)
            col += (attrs["colspan"]?.intValue ?? 1) - 1
        } else if row < map.height, pos == (index + map.width < map.map.count ? map.map[index + map.width] : -1) {
            let cell = table.nodeAt(pos)!
            var attrs = cell.attrs
            attrs["rowspan"] = .int((attrs["rowspan"]?.intValue ?? 1) - 1)
            if let copy = try? cell.type.create(attrs, content: cell.content) {
                let newPos = map.positionAt(row + 1, col, table)
                _ = try? tr.insert(tr.mapping.slice(mapFrom).map(tableStart + newPos), copy)
            }
            col += (cell.attrs["colspan"]?.intValue ?? 1) - 1
        }
    }
}

public let deleteRow: Command = { state, dispatch, _ in
    guard isInTable(state) else { return false }
    if let dispatch {
        guard var rect = selectedRect(state) else { return false }
        let tr = state.tr
        if rect.top == 0 && rect.bottom == rect.map.height { return false }
        var i = rect.bottom - 1
        while true {
            removeRow(tr, rect, i)
            if i == rect.top { break }
            let table = rect.tableStart != 0 ? tr.doc.nodeAt(rect.tableStart - 1) : tr.doc
            guard let table else { return false }
            rect.table = table
            rect.map = TableMap.get(table)
            i -= 1
        }
        dispatch(tr)
    }
    return true
}

// MARK: - Merge / split

private func isEmptyCell(_ cell: Node) -> Bool {
    let c = cell.content
    return c.childCount == 1 && c.child(0).isTextblock && c.child(0).childCount == 0
}

private func cellsOverlapRectangle(_ map: TableMap, _ rect: TableRect) -> Bool {
    let width = map.width, height = map.height, m = map.map
    var indexTop = rect.top * width + rect.left
    var indexLeft = indexTop
    var indexBottom = (rect.bottom - 1) * width + rect.left
    var indexRight = indexTop + (rect.right - rect.left - 1)
    for _ in rect.top..<rect.bottom {
        if (rect.left > 0 && m[indexLeft] == m[indexLeft - 1]) ||
            (rect.right < width && m[indexRight] == m[indexRight + 1]) { return true }
        indexLeft += width; indexRight += width
    }
    for _ in rect.left..<rect.right {
        if (rect.top > 0 && m[indexTop] == m[indexTop - width]) ||
            (rect.bottom < height && m[indexBottom] == m[indexBottom + width]) { return true }
        indexTop += 1; indexBottom += 1
    }
    return false
}

public let mergeCells: Command = { state, dispatch, _ in
    guard let sel = state.selection as? CellSelection, sel.anchorCell.pos != sel.headCell.pos else { return false }
    guard let rect = selectedRect(state) else { return false }
    let map = rect.map
    if cellsOverlapRectangle(map, TableRect(left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom)) { return false }
    if let dispatch {
        let tr = state.tr
        var seen = Set<Int>()
        var content = Fragment.empty
        var mergedPos: Int?
        var mergedCell: Node?
        for row in rect.top..<rect.bottom {
            for col in rect.left..<rect.right {
                let cellPos = map.map[row * map.width + col]
                guard let cell = rect.table.nodeAt(cellPos), !seen.contains(cellPos) else { continue }
                seen.insert(cellPos)
                if mergedPos == nil { mergedPos = cellPos; mergedCell = cell }
                else {
                    if !isEmptyCell(cell) { content = content.append(cell.content) }
                    let mapped = tr.mapping.map(cellPos + rect.tableStart)
                    _ = try? tr.delete(mapped, mapped + cell.nodeSize)
                }
            }
        }
        guard let mergedPos, let mergedCell else { return true }
        var attrs = addColSpan(mergedCell.attrs, mergedCell.attrs["colspan"]?.intValue ?? 1,
                               rect.right - rect.left - (mergedCell.attrs["colspan"]?.intValue ?? 1))
        attrs["rowspan"] = .int(rect.bottom - rect.top)
        _ = try? tr.setNodeMarkup(mergedPos + rect.tableStart, nil, attrs)
        if content.size > 0 {
            let end = mergedPos + 1 + mergedCell.content.size
            let start = isEmptyCell(mergedCell) ? mergedPos + 1 : end
            _ = try? tr.replaceWith(start + rect.tableStart, end + rect.tableStart, content)
        }
        tr.setSelection(CellSelection(tr.doc.resolve(mergedPos + rect.tableStart)))
        dispatch(tr)
    }
    return true
}

public func splitCellWithType(_ getCellType: @escaping @Sendable (Node, Int, Int) -> NodeType) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        var cellNode: Node?
        var cellPos: Int?
        if let cs = sel as? CellSelection {
            if cs.anchorCell.pos != cs.headCell.pos { return false }
            cellNode = cs.anchorCell.nodeAfter
            cellPos = cs.anchorCell.pos
        } else {
            cellNode = cellWrapping(sel.resolvedFrom)
            if cellNode == nil { return false }
            cellPos = cellAround(sel.resolvedFrom)?.pos
        }
        guard let cellNode, let cellPos else { return false }
        if (cellNode.attrs["colspan"]?.intValue ?? 1) == 1 && (cellNode.attrs["rowspan"]?.intValue ?? 1) == 1 { return false }
        if let dispatch {
            var baseAttrs = cellNode.attrs
            let colwidth = cellColwidth(cellNode)
            if (baseAttrs["rowspan"]?.intValue ?? 1) > 1 { baseAttrs["rowspan"] = .int(1) }
            if (baseAttrs["colspan"]?.intValue ?? 1) > 1 { baseAttrs["colspan"] = .int(1) }
            guard let rect = selectedRect(state) else { return false }
            let tr = state.tr
            var attrs: [Attrs] = []
            for i in 0..<(rect.right - rect.left) {
                if let colwidth, i < colwidth.count, colwidth[i] != 0 {
                    var a = baseAttrs; a["colwidth"] = .array([.int(colwidth[i])]); attrs.append(a)
                } else {
                    var a = baseAttrs; a["colwidth"] = .null; attrs.append(a)
                }
            }
            var lastCell: Int?
            for row in rect.top..<rect.bottom {
                var pos = rect.map.positionAt(row, rect.left, rect.table)
                if row == rect.top { pos += cellNode.nodeSize }
                var col = rect.left, i = 0
                while col < rect.right {
                    defer { col += 1; i += 1 }
                    if col == rect.left && row == rect.top { continue }
                    let at = tr.mapping.map(pos + rect.tableStart, 1)
                    lastCell = at
                    _ = try? tr.insert(at, getCellType(cellNode, row, col).createAndFill(attrs[i])!)
                }
            }
            _ = try? tr.setNodeMarkup(cellPos, getCellType(cellNode, rect.top, rect.left), attrs[0])
            if let cs = sel as? CellSelection {
                tr.setSelection(CellSelection(tr.doc.resolve(cs.anchorCell.pos), lastCell.map { tr.doc.resolve($0) }))
            }
            dispatch(tr)
        }
        return true
    }
}

public let splitCell: Command = { state, dispatch, host in
    splitCellWithType { node, _, _ in
        let types = tableNodeTypes(node.type.schema)
        return types[tableRole(node.type) ?? "cell"] ?? types["cell"]!
    }(state, dispatch, host)
}

/// Merge the selected cells, or split the one under the cursor — whichever the
/// selection allows. One button can then do both, which is how a toolbar wants
/// to spell it: with several cells selected there is nothing to split, and with
/// one spanning cell there is nothing to merge.
///
/// Merging is tried first, so a selection covering a spanning cell merges it
/// into its neighbours rather than splitting it apart.
public let mergeOrSplit: Command = { state, dispatch, host in
    if mergeCells(state, dispatch, host) { return true }
    return splitCell(state, dispatch, host)
}

// MARK: - Cell attrs / header

public func setCellAttr(_ name: String, _ value: AttributeValue) -> Command {
    { state, dispatch, _ in
        guard isInTable(state), let cell = selectionCell(state) else { return false }
        if cell.nodeAfter?.attrs[name] == value { return false }
        if let dispatch {
            let tr = state.tr
            if let cs = state.selection as? CellSelection {
                cs.forEachCell { node, pos in
                    if node.attrs[name] != value {
                        var a = node.attrs; a[name] = value
                        _ = try? tr.setNodeMarkup(pos, nil, a)
                    }
                }
            } else if let after = cell.nodeAfter {
                var a = after.attrs; a[name] = value
                _ = try? tr.setNodeMarkup(cell.pos, nil, a)
            }
            dispatch(tr)
        }
        return true
    }
}

public enum ToggleHeaderType: String, Sendable { case column, row, cell }

private func deprecatedToggleHeader(_ type: ToggleHeaderType) -> Command {
    { state, dispatch, _ in
        guard isInTable(state) else { return false }
        if let dispatch {
            let types = tableNodeTypes(state.schema)
            guard let rect = selectedRect(state) else { return false }
            let tr = state.tr
            let area: TableRect
            switch type {
            case .column: area = TableRect(left: rect.left, top: 0, right: rect.right, bottom: rect.map.height)
            case .row: area = TableRect(left: 0, top: rect.top, right: rect.map.width, bottom: rect.bottom)
            case .cell: area = TableRect(left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom)
            }
            let cells = rect.map.cellsInRect(area)
            let nodes = cells.map { rect.table.nodeAt($0)! }
            for i in cells.indices where nodes[i].type === types["header_cell"] {
                _ = try? tr.setNodeMarkup(rect.tableStart + cells[i], types["cell"], nodes[i].attrs)
            }
            if tr.steps.isEmpty {
                for i in cells.indices {
                    _ = try? tr.setNodeMarkup(rect.tableStart + cells[i], types["header_cell"], nodes[i].attrs)
                }
            }
            dispatch(tr)
        }
        return true
    }
}

private func isHeaderEnabledByType(_ type: String, _ rect: SelectedRect, _ types: [String: NodeType]) -> Bool {
    let cells = rect.map.cellsInRect(TableRect(left: 0, top: 0,
                                               right: type == "row" ? rect.map.width : 1,
                                               bottom: type == "column" ? rect.map.height : 1))
    for pos in cells {
        if let cell = rect.table.nodeAt(pos), cell.type !== types["header_cell"] { return false }
    }
    return true
}

public func toggleHeader(_ type: ToggleHeaderType) -> Command {
    { state, dispatch, _ in
        guard isInTable(state) else { return false }
        if let dispatch {
            let types = tableNodeTypes(state.schema)
            guard let rect = selectedRect(state) else { return false }
            let tr = state.tr
            let isHeaderRowEnabled = isHeaderEnabledByType("row", rect, types)
            let isHeaderColumnEnabled = isHeaderEnabledByType("column", rect, types)
            let isHeaderEnabled = type == .column ? isHeaderRowEnabled : (type == .row ? isHeaderColumnEnabled : false)
            let start = isHeaderEnabled ? 1 : 0
            let cellsRect: TableRect
            switch type {
            case .column: cellsRect = TableRect(left: 0, top: start, right: 1, bottom: rect.map.height)
            case .row: cellsRect = TableRect(left: start, top: 0, right: rect.map.width, bottom: 1)
            case .cell: cellsRect = TableRect(left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom)
            }
            let newType: NodeType
            switch type {
            case .column: newType = isHeaderColumnEnabled ? types["cell"]! : types["header_cell"]!
            case .row: newType = isHeaderRowEnabled ? types["cell"]! : types["header_cell"]!
            case .cell: newType = types["cell"]!
            }
            for relPos in rect.map.cellsInRect(cellsRect) {
                let cellPos = relPos + rect.tableStart
                if let cell = tr.doc.nodeAt(cellPos) { _ = try? tr.setNodeMarkup(cellPos, newType, cell.attrs) }
            }
            dispatch(tr)
        }
        return true
    }
}
public let toggleHeaderRow: Command = deprecatedToggleHeader(.row)
public let toggleHeaderColumn: Command = deprecatedToggleHeader(.column)
public let toggleHeaderCell: Command = deprecatedToggleHeader(.cell)

// MARK: - Navigation

private func findNextCell(_ cell: ResolvedPos, _ dir: TableDirection) -> Int? {
    if dir < 0 {
        if let before = cell.nodeBefore { return cell.pos - before.nodeSize }
        var row = cell.index(-1) - 1
        var rowEnd = cell.before()
        while row >= 0 {
            let rowNode = cell.node(-1).child(row)
            if let lastChild = rowNode.lastChild { return rowEnd - 1 - lastChild.nodeSize }
            rowEnd -= rowNode.nodeSize
            row -= 1
        }
    } else {
        if cell.index() < cell.parent.childCount - 1 { return cell.pos + (cell.nodeAfter?.nodeSize ?? 0) }
        let table = cell.node(-1)
        var row = cell.indexAfter(-1)
        var rowStart = cell.after()
        while row < table.childCount {
            let rowNode = table.child(row)
            if rowNode.childCount != 0 { return rowStart + 1 }
            rowStart += rowNode.nodeSize
            row += 1
        }
    }
    return nil
}

public func goToNextCell(_ direction: TableDirection) -> Command {
    { state, dispatch, _ in
        guard isInTable(state), let cell = selectionCell(state) else { return false }
        guard let next = findNextCell(cell, direction) else { return false }
        if let dispatch {
            let resolved = state.doc.resolve(next)
            dispatch(state.tr.setSelection(TextSelection.between(resolved, moveCellForward(resolved))).scrollIntoView())
        }
        return true
    }
}

/// Tab inside a table: move to the next cell, or — when already in the last
/// cell — append a row and land in its first cell. Mirrors Apple Notes (and the
/// prosemirror-tables demo), where tabbing off the end grows the table rather
/// than escaping it.
public let goToNextCellOrAddRow: Command = { state, dispatch, host in
    // A next cell exists: ordinary forward navigation.
    if goToNextCell(1)(state, dispatch, host) { return true }
    // Otherwise we're in the last cell — append a row and select its first cell.
    guard isInTable(state), let rect = selectedRect(state) else { return false }
    if let dispatch {
        let tr = addRow(state.tr, rect, rect.bottom)
        // `addRow` inserts the new row at `rect.bottom`; recompute that position
        // (start-of-table + every preceding row) to point at the new row's first
        // cell, then select inside it the same way `goToNextCell` does.
        var rowPos = rect.tableStart
        for i in 0..<rect.bottom { rowPos += rect.table.child(i).nodeSize }
        let resolved = tr.doc.resolve(rowPos + 1)
        dispatch(tr.setSelection(TextSelection.between(resolved, moveCellForward(resolved))).scrollIntoView())
    }
    return true
}
