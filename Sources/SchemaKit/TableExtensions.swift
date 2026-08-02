public import DocumentModel
import DocumentTransform
public import EditorStateKit
public import EditorCommands

// Table support. The schema + structural commands match prosemirror-tables
// (spanning-aware via TableMap/CellSelection — see TableMap.swift / TableUtil.swift
// / CellSelection.swift / TableCommandsPM.swift).

private let cellAttrs: [String: AttributeSpec] = [
    "colspan": AttributeSpec(default: .int(1)),
    "rowspan": AttributeSpec(default: .int(1)),
    "colwidth": AttributeSpec(default: .null),
]

/// How a table behaves, beyond its schema.
///
/// `resizable` defaults to on, unlike Tiptap, where it is off until asked for:
/// this renderer has always resized columns and turning that off by default
/// would take a working feature away from every existing host.
public struct TableOptions: Equatable, Sendable {
    /// Whether columns may be dragged wider or narrower.
    public var resizable: Bool
    /// The grab area and minimum width used while dragging.
    public var columnResizing: ColumnResizingOptions
    /// Whether a table may be selected as a whole node. Off, as upstream has
    /// it: a table node-selection is normalized to a selection of its cells,
    /// which is what the commands and the renderer expect to find.
    public var allowTableNodeSelection: Bool

    public init(resizable: Bool = true,
                columnResizing: ColumnResizingOptions = ColumnResizingOptions(),
                allowTableNodeSelection: Bool = false) {
        self.resizable = resizable
        self.columnResizing = columnResizing
        self.allowTableNodeSelection = allowTableNodeSelection
    }
}

public final class TableExtension: NodeExtension {
    public let name = "table"
    public let options: TableOptions
    public init(options: TableOptions = TableOptions()) { self.options = options }
    public var nodeSpec: NodeSpec { NodeSpec(content: "tableRow+", group: "block", isolating: true) }
    public var html: HTMLSpec { HTMLSpec(tag: "table") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        ["deleteTable": deleteTable, "goToNextCell": goToNextCell(1), "goToPreviousCell": goToNextCell(-1),
         "addColumnBefore": addColumnBefore, "addColumnAfter": addColumnAfter, "deleteColumn": deleteColumn,
         "addRowBefore": addRowBefore, "addRowAfter": addRowAfter, "deleteRow": deleteRow,
         "mergeCells": mergeCells, "splitCell": splitCell, "mergeOrSplit": mergeOrSplit,
         "toggleHeaderRow": toggleHeaderRow, "toggleHeaderColumn": toggleHeaderColumn, "toggleHeaderCell": toggleHeaderCell]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        ["Tab": goToNextCellOrAddRow, "Shift-Tab": goToNextCell(-1),
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
        let allowNodeSelection = options.allowTableNodeSelection
        var plugins: [Plugin] = [Plugin(key: "fixTables", appendTransaction: { _, oldState, newState in
            normalizeSelection(newState, fixTables(newState, oldState), allowNodeSelection)
        })]
        // Left out entirely when resizing is off: the view takes the plugin's
        // absence as the answer, so there is one place to ask.
        if options.resizable { plugins.append(columnResizing(options: options.columnResizing)) }
        return plugins
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
public func tableExtensions(options: TableOptions = TableOptions()) -> [any Extension] {
    [TableExtension(options: options), TableRowExtension(), TableCellExtension(), TableHeaderExtension()]
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
        if let dispatch {
            // Where the first cell's content will be, measured before the
            // insert: one step into the table, one into its first row, one into
            // the cell. Without this the caret lands *after* the table — typing
            // then writes below it, and a table command has no cell to act on.
            let inFirstCell = state.selection.from + 3
            let tr = state.tr.replaceSelectionWith(table).scrollIntoView()
            tr.setSelection(Selection.near(tr.doc.resolve(min(inFirstCell, tr.doc.content.size))))
            dispatch(tr)
        }
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
