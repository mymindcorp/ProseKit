import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands

// Table support. The schema + structural commands match prosemirror-tables
// (spanning-aware via TableMap/CellSelection — see TableMap.swift / TableUtil.swift
// / CellSelection.swift / TableCommandsPM.swift).

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
        ["deleteTable": deleteTable, "goToNextCell": goToNextCell(1), "goToPreviousCell": goToNextCell(-1),
         "addColumnBefore": addColumnBefore, "addColumnAfter": addColumnAfter, "deleteColumn": deleteColumn,
         "addRowBefore": addRowBefore, "addRowAfter": addRowAfter, "deleteRow": deleteRow,
         "mergeCells": mergeCells, "splitCell": splitCell,
         "toggleHeaderRow": toggleHeaderRow, "toggleHeaderColumn": toggleHeaderColumn, "toggleHeaderCell": toggleHeaderCell]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        ["Tab": goToNextCell(1), "Shift-Tab": goToNextCell(-1),
         "ArrowLeft": tableArrow(.horiz, -1), "ArrowRight": tableArrow(.horiz, 1),
         "ArrowUp": tableArrow(.vert, -1), "ArrowDown": tableArrow(.vert, 1),
         "Shift-ArrowLeft": tableShiftArrow(.horiz, -1), "Shift-ArrowRight": tableShiftArrow(.horiz, 1),
         "Shift-ArrowUp": tableShiftArrow(.vert, -1), "Shift-ArrowDown": tableShiftArrow(.vert, 1),
         "Backspace": deleteCellSelectionContent, "Mod-Backspace": deleteCellSelectionContent,
         "Delete": deleteCellSelectionContent, "Mod-Delete": deleteCellSelectionContent]
    }
    public func plugins(_ ctx: ExtensionContext) -> [Plugin] {
        // Keep tables rectangular after every edit (the invariant the commands
        // and TableMap assume) and normalize cell/row/table node-selections into
        // CellSelections — mirroring prosemirror-tables' fixTables + normalizeSelection.
        [Plugin(key: "fixTables", appendTransaction: { _, oldState, newState in
            normalizeSelection(newState, fixTables(newState, oldState), false)
        })]
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

private func isCell(_ node: Node) -> Bool {
    node.type.name == "tableCell" || node.type.name == "tableHeader"
}

private struct TableContext {
    var table: Node
    var tablePos: Int
}

private func tableContext(_ state: EditorState) -> TableContext? {
    let from = state.selection.resolvedFrom
    var d = from.depth
    while d >= 0 {
        if from.node(d).type.name == "table" { return TableContext(table: from.node(d), tablePos: from.before(d)) }
        d -= 1
    }
    return nil
}

// MARK: - Commands

/// Insert a `rows`×`cols` table (with a header row) at the selection.
public func insertTable(rows: Int = 3, cols: Int = 3, withHeaderRow: Bool = true) -> Command {
    { state, dispatch, _ in
        guard let table = createTable(state.schema, rows: rows, cols: cols, withHeaderRow: withHeaderRow) else { return false }
        dispatch?(state.tr.replaceSelectionWith(table).scrollIntoView())
        return true
    }
}

/// Delete the whole table containing the selection.
public let deleteTable: Command = { state, dispatch, _ in
    guard let ctx = tableContext(state) else { return false }
    if let dispatch {
        _ = try? dispatch(state.tr.delete(ctx.tablePos, ctx.tablePos + ctx.table.nodeSize).scrollIntoView())
    }
    return true
}

public extension Editor {
    @discardableResult
    func insertTable(rows: Int = 3, cols: Int = 3, withHeaderRow: Bool = true) -> Bool {
        run(SchemaKit.insertTable(rows: rows, cols: cols, withHeaderRow: withHeaderRow))
    }
}
