import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands

// Table support. Schema mirrors prosemirror-tables; the structural commands use
// a grid rebuild that is correct for non-spanning tables (the common case).
// colspan/rowspan attributes are preserved in the schema for future spanning
// support.

private let cellAttrs: [String: AttributeSpec] = [
    "colspan": AttributeSpec(default: .int(1)),
    "rowspan": AttributeSpec(default: .int(1)),
    "colwidth": AttributeSpec(default: .null),
]

public final class TableExtension: NodeExtension {
    public let name = "table"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "tableRow+", group: "block", isolating: true) }
    public var html: HTMLSpec { HTMLSpec(tag: "table") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        ["deleteTable": deleteTable, "goToNextCell": goToNextCell(.forward), "goToPreviousCell": goToNextCell(.backward)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        ["Tab": goToNextCell(.forward), "Shift-Tab": goToNextCell(.backward)]
    }
}

public final class TableRowExtension: NodeExtension {
    public let name = "tableRow"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "(tableCell | tableHeader)+") }
    public var html: HTMLSpec { HTMLSpec(tag: "tr") }
}

public final class TableCellExtension: NodeExtension {
    public let name = "tableCell"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "block+", attrs: cellAttrs, isolating: true) }
    public var html: HTMLSpec { HTMLSpec(tag: "td") }
}

public final class TableHeaderExtension: NodeExtension {
    public let name = "tableHeader"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "block+", attrs: cellAttrs, isolating: true) }
    public var html: HTMLSpec { HTMLSpec(tag: "th") }
}

/// The full set of table extensions.
public func tableExtensions() -> [Extension] {
    [TableExtension(), TableRowExtension(), TableCellExtension(), TableHeaderExtension()]
}

// MARK: - Construction

/// Create a `rows` × `cols` table node (optionally with a header row).
public func createTable(_ schema: Schema, rows: Int, cols: Int, withHeaderRow: Bool = true) -> Node? {
    guard let tableType = schema.nodes["table"],
          let rowType = schema.nodes["tableRow"],
          let cellType = schema.nodes["tableCell"],
          let headerType = schema.nodes["tableHeader"] else { return nil }
    var rowNodes: [Node] = []
    for r in 0..<rows {
        let type = (withHeaderRow && r == 0) ? headerType : cellType
        var cells: [Node] = []
        for _ in 0..<cols {
            guard let cell = type.createAndFill() else { return nil }
            cells.append(cell)
        }
        guard let row = try? rowType.create([:], content: Fragment.from(cells)) else { return nil }
        rowNodes.append(row)
    }
    return try? tableType.create([:], content: Fragment.from(rowNodes))
}

// MARK: - Grid helpers

private func isCell(_ node: Node) -> Bool {
    node.type.name == "tableCell" || node.type.name == "tableHeader"
}

private struct TableContext {
    var table: Node
    var tablePos: Int     // position before the table
    var rowIndex: Int
    var colIndex: Int
    var tableDepth: Int
}

private func tableContext(_ state: EditorState) -> TableContext? {
    let from = state.selection.resolvedFrom
    var cellDepth = -1
    var d = from.depth
    while d >= 0 {
        if isCell(from.node(d)) { cellDepth = d; break }
        d -= 1
    }
    guard cellDepth >= 2 else { return nil }
    let rowDepth = cellDepth - 1
    let tableDepth = cellDepth - 2
    return TableContext(
        table: from.node(tableDepth),
        tablePos: from.before(tableDepth),
        rowIndex: from.index(tableDepth),
        colIndex: from.index(rowDepth),
        tableDepth: tableDepth)
}

private func grid(of table: Node) -> [[Node]] {
    var rows: [[Node]] = []
    for r in 0..<table.childCount {
        let row = table.child(r)
        rows.append((0..<row.childCount).map { row.child($0) })
    }
    return rows
}

private func buildTable(_ schema: Schema, like table: Node, _ grid: [[Node]]) -> Node? {
    guard let rowType = schema.nodes["tableRow"] else { return nil }
    var rowNodes: [Node] = []
    for cells in grid {
        guard let row = try? rowType.create([:], content: Fragment.from(cells)) else { return nil }
        rowNodes.append(row)
    }
    return table.copy(content: Fragment.from(rowNodes))
}

private func emptyCell(like template: Node) -> Node? {
    template.type.createAndFill([:])
}

private func replaceTable(_ state: EditorState, _ ctx: TableContext, _ newGrid: [[Node]], _ dispatch: Dispatch?) -> Bool {
    guard let newTable = buildTable(state.schema, like: ctx.table, newGrid) else { return false }
    if let dispatch {
        let tr = state.tr
        _ = try? tr.replaceWith(ctx.tablePos, ctx.tablePos + ctx.table.nodeSize, newTable)
        // Keep the cursor near where it was.
        let target = min(ctx.tablePos + 2, tr.doc.content.size)
        tr.setSelection(Selection.near(tr.doc.resolve(target)))
        dispatch(tr.scrollIntoView())
    }
    return true
}

// MARK: - Commands

/// Insert a 3×3 table (with a header row) at the selection.
public func insertTable(rows: Int = 3, cols: Int = 3, withHeaderRow: Bool = true) -> Command {
    { state, dispatch, _ in
        guard let table = createTable(state.schema, rows: rows, cols: cols, withHeaderRow: withHeaderRow) else { return false }
        dispatch?(state.tr.replaceSelectionWith(table).scrollIntoView())
        return true
    }
}

private func addColumn(after: Bool) -> Command {
    { state, dispatch, _ in
        guard let ctx = tableContext(state) else { return false }
        var g = grid(of: ctx.table)
        let at = after ? ctx.colIndex + 1 : ctx.colIndex
        for r in g.indices {
            guard let template = g[r].first, let cell = emptyCell(like: template) else { return false }
            g[r].insert(cell, at: min(at, g[r].count))
        }
        return replaceTable(state, ctx, g, dispatch)
    }
}

public let addColumnAfter: Command = addColumn(after: true)
public let addColumnBefore: Command = addColumn(after: false)

public let deleteColumn: Command = { state, dispatch, _ in
    guard let ctx = tableContext(state) else { return false }
    var g = grid(of: ctx.table)
    guard g.first.map({ $0.count > 1 }) ?? false else { return false }
    for r in g.indices where ctx.colIndex < g[r].count {
        g[r].remove(at: ctx.colIndex)
    }
    return replaceTable(state, ctx, g, dispatch)
}

private func addRow(after: Bool) -> Command {
    { state, dispatch, _ in
        guard let ctx = tableContext(state) else { return false }
        var g = grid(of: ctx.table)
        let cols = g.first?.count ?? 0
        guard cols > 0 else { return false }
        // Build a new row using the body cell type.
        let template = g.last?.first ?? g[0][0]
        var newRow: [Node] = []
        for _ in 0..<cols {
            guard let cell = emptyCell(like: template) else { return false }
            newRow.append(cell)
        }
        let at = after ? ctx.rowIndex + 1 : ctx.rowIndex
        g.insert(newRow, at: min(at, g.count))
        return replaceTable(state, ctx, g, dispatch)
    }
}

public let addRowAfter: Command = addRow(after: true)
public let addRowBefore: Command = addRow(after: false)

public let deleteRow: Command = { state, dispatch, _ in
    guard let ctx = tableContext(state) else { return false }
    var g = grid(of: ctx.table)
    guard g.count > 1, ctx.rowIndex < g.count else { return false }
    g.remove(at: ctx.rowIndex)
    return replaceTable(state, ctx, g, dispatch)
}

/// Delete the whole table containing the selection.
public let deleteTable: Command = { state, dispatch, _ in
    guard let ctx = tableContext(state) else { return false }
    if let dispatch {
        try? dispatch(state.tr.delete(ctx.tablePos, ctx.tablePos + ctx.table.nodeSize).scrollIntoView())
    }
    return true
}

/// Move the selection to the next/previous table cell (Tab / Shift-Tab),
/// wrapping across rows. No-op (returns false) outside a table.
public func goToNextCell(_ direction: TextDirection) -> Command {
    { state, dispatch, _ in
        guard let ctx = tableContext(state) else { return false }
        let cols = ctx.table.firstChild?.childCount ?? 0
        let rows = ctx.table.childCount
        guard cols > 0 else { return false }
        let linear = ctx.rowIndex * cols + ctx.colIndex + direction.sign
        guard linear >= 0, linear < rows * cols else { return false } // at a table edge
        let targetRow = linear / cols
        let targetCol = linear % cols
        guard let pos = cellContentPosition(table: ctx.table, tableContentStart: ctx.tablePos + 1, row: targetRow, col: targetCol) else {
            return false
        }
        if let dispatch {
            dispatch(state.tr.setSelection(Selection.near(state.doc.resolve(min(pos, state.doc.content.size)))).scrollIntoView())
        }
        return true
    }
}

/// The document position of a cursor inside the first textblock of cell (row, col).
private func cellContentPosition(table: Node, tableContentStart: Int, row: Int, col: Int) -> Int? {
    var pos = tableContentStart
    for r in 0..<table.childCount {
        let rowNode = table.child(r)
        if r == row {
            var cellStart = pos + 1 // step inside the row
            for c in 0..<rowNode.childCount {
                if c == col { return cellStart + 2 } // inside the cell, inside its first block
                cellStart += rowNode.child(c).nodeSize
            }
            return nil
        }
        pos += rowNode.nodeSize
    }
    return nil
}

public extension Editor {
    @discardableResult
    func insertTable(rows: Int = 3, cols: Int = 3, withHeaderRow: Bool = true) -> Bool {
        run(SchemaKit.insertTable(rows: rows, cols: cols, withHeaderRow: withHeaderRow))
    }
}
