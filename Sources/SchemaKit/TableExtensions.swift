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
    // How the cell's text is set: "left", "center", "right", or null for
    // whatever the reading direction gives. Per cell rather than per column
    // because that is where the column commands already carry attributes —
    // add/remove/move a column and this rides along with `colwidth` — and
    // because HTML says it per cell too. A pipe table can only spell one
    // alignment per column, so a column whose cells disagree is written as
    // HTML instead, the same as a colspan or a stored width.
    "align": AttributeSpec(default: .null),
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
    // Indent code and list items inside cells before navigating between cells.
    public let priority = 90
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
        var plugins: [Plugin] = [Plugin(key: "fixTables", appendTransaction: { trs, oldState, newState in
            // Only a doc change can leave a table malformed, so a selection-only
            // transaction (every tick of a selection drag) skips the document
            // walk — as upstream does. Normalizing node selections into cell
            // selections still runs: that is about the selection, not the doc.
            let docChanged = trs.contains { $0.docChanged }
            return normalizeSelection(newState, docChanged ? fixTables(newState, oldState) : nil,
                                      allowNodeSelection)
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
    guard rows > 0, cols > 0,
          let tableType = schema.nodes["table"],
          let rowType = schema.nodes["tableRow"],
          let cellType = schema.nodes["tableCell"],
          let firstRowType = withHeaderRow ? schema.nodes["tableHeader"] : cellType else { return nil }
    var rowNodes: [Node] = []
    for r in 0..<rows {
        let type = r == 0 ? firstRowType : cellType
        var cells: [Node] = []
        for _ in 0..<cols {
            guard let cell = type.createAndFill() else { return nil }
            cells.append(cell)
        }
        guard let row = try? rowType.createChecked([:], content: Fragment.from(cells)) else { return nil }
        rowNodes.append(row)
    }
    return try? tableType.createChecked([:], content: Fragment.from(rowNodes))
}

private struct TableContext {
    let table: Node
    let tablePos: Int
}

private func tableContext(_ state: EditorState) -> TableContext? {
    guard let type = state.schema.nodes["table"],
          let target = selectedNodeOrAncestor(state, type) else { return nil }
    return TableContext(table: target.node, tablePos: target.pos)
}

// MARK: - Commands

/// Insert a `rows`×`cols` table (with a header row) at the selection.
public func insertTable(rows: Int = 3, cols: Int = 3, withHeaderRow: Bool = true) -> Command {
    { state, dispatch, _ in
        guard let table = createTable(state.schema, rows: rows, cols: cols, withHeaderRow: withHeaderRow) else { return false }
        let tr = state.tr.replaceSelectionWith(table, inheritMarks: false)
        // Fitting may discard a table wrapper that the destination forbids.
        // Confirm the complete table survived before publishing the replacement.
        var insertedAt: Int?
        for (index, map) in tr.mapping.maps.enumerated() {
            let after = tr.mapping.slice(index + 1)
            map.forEach { _, _, newStart, newEnd in
                let from = after.map(newStart, -1), to = after.map(newEnd, 1)
                tr.doc.nodesBetween(from, to, { node, pos, _, _ in
                    if insertedAt == nil, pos >= from, pos + node.nodeSize <= to, node == table {
                        insertedAt = pos
                        return false
                    }
                    return insertedAt == nil
                })
            }
        }
        guard let insertedAt else { return false }
        // Use the actual fitted location: insertion can split the textblock.
        tr.setSelection(Selection.near(tr.doc.resolve(insertedAt + 3)))
        dispatch?(tr.scrollIntoView())
        return true
    }
}

/// Delete the whole table containing the selection.
public let deleteTable: Command = { state, dispatch, _ in
    guard let ctx = tableContext(state) else { return false }
    let tr = state.tr
    guard (try? tr.delete(ctx.tablePos, ctx.tablePos + ctx.table.nodeSize)) != nil else { return false }
    // A schema may require a table, in which case fitting synthesizes an
    // empty replacement. Do not publish a content wipe as successful deletion.
    // Include nested tables in the target: they disappear with their parent.
    func tableCount(_ node: Node) -> Int {
        var count = node.type === ctx.table.type ? 1 : 0
        node.descendants { child, _, _, _ in
            if child.type === ctx.table.type { count += 1 }
            return true
        }
        return count
    }
    guard tableCount(tr.doc) == tableCount(state.doc) - tableCount(ctx.table) else { return false }
    dispatch?(tr.scrollIntoView())
    return true
}

public extension Editor {
    @discardableResult
    func insertTable(rows: Int = 3, cols: Int = 3, withHeaderRow: Bool = true) -> Bool {
        run(SchemaKit.insertTable(rows: rows, cols: cols, withHeaderRow: withHeaderRow))
    }
}
