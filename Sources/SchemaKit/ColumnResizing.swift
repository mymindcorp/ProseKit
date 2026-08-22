import DocumentModel
import DocumentTransform
public import EditorStateKit

// A port of prosemirror-tables' columnresizing plugin — the headless core:
// ResizeState (active handle + dragging, driven by metas and remapped through
// doc changes), the handle decorations, and the colwidth-updating transaction.
// Upstream's DOM pieces (mouse handlers, TableView node view, live width
// display) are the view layer's job here: the renderer's drag gesture drives
// the same metas via `setResizeHandle`/`setResizeDragging` and applies
// `updateColumnWidth` on release.

/// An in-progress column drag: where it started and the column's start width.
public struct ColumnDragging: Equatable, Sendable {
    public let startX: Double
    public let startWidth: Double
    public init(startX: Double, startWidth: Double) {
        self.startX = startX
        self.startWidth = startWidth
    }
}

/// How the view should treat a column border, carried in the plugin's state so
/// the renderer reads it from the editor rather than being told separately.
///
/// The defaults are the ones the renderer already used, not upstream's: a 6pt
/// grab area suits a fingertip where the web's 5px suits a mouse, and 24pt is
/// the narrowest column the cell padding leaves room for. prosemirror-tables
/// uses 5 and 25.
public struct ColumnResizingOptions: Equatable, Sendable {
    /// How far from a border a press still counts as grabbing it, in points.
    public var handleWidth: Double
    /// The narrowest a column may be dragged, in points.
    public var cellMinWidth: Double

    public init(handleWidth: Double = 6, cellMinWidth: Double = 24) {
        self.handleWidth = handleWidth
        self.cellMinWidth = cellMinWidth
    }
}

/// The column-resizing plugin's state.
public final class ResizeState {
    /// The position of the cell whose right edge the pointer is over (-1 = none).
    public let activeHandle: Int
    public let dragging: ColumnDragging?
    /// The options the plugin was created with; constant for its lifetime.
    public let options: ColumnResizingOptions

    init(activeHandle: Int, dragging: ColumnDragging?, options: ColumnResizingOptions) {
        self.activeHandle = activeHandle
        self.dragging = dragging
        self.options = options
    }

    func apply(_ tr: Transaction) -> ResizeState {
        if let action = tr.getMeta(columnResizingMeta) as? ResizeAction {
            switch action {
            case .setHandle(let value):
                return ResizeState(activeHandle: value, dragging: nil, options: options)
            case .setDragging(let dragging):
                return ResizeState(activeHandle: activeHandle, dragging: dragging, options: options)
            }
        }
        if activeHandle > -1, tr.docChanged {
            var handle = tr.mapping.map(activeHandle, -1)
            if !pointsAtCell(tr.doc.resolve(min(max(0, handle), tr.doc.content.size))) { handle = -1 }
            return ResizeState(activeHandle: handle, dragging: dragging, options: options)
        }
        return self
    }
}

public let columnResizingKey = PluginKey<ResizeState>("tableColumnResizing")
private let columnResizingMeta = "tableColumnResizing$"

private enum ResizeAction {
    case setHandle(Int)
    case setDragging(ColumnDragging?)
}

/// Mark a transaction as moving the resize handle (-1 = none).
@discardableResult
public func setResizeHandle(_ tr: Transaction, _ value: Int) -> Transaction {
    tr.setMeta(columnResizingMeta, ResizeAction.setHandle(value))
}

/// Mark a transaction as starting/ending a column drag.
@discardableResult
public func setResizeDragging(_ tr: Transaction, _ dragging: ColumnDragging?) -> Transaction {
    tr.setMeta(columnResizingMeta, ResizeAction.setDragging(dragging))
}

/// Create the column-resizing plugin.
///
/// Its presence is what tells the view that columns may be resized at all: a
/// table configured `resizable: false` leaves the plugin out, and the renderer
/// finds no state to read.
public func columnResizing(options: ColumnResizingOptions = ColumnResizingOptions()) -> Plugin {
    Plugin(
        key: columnResizingKey.key,
        stateField: PluginStateField(
            initialize: { _, _ in ResizeState(activeHandle: -1, dragging: nil, options: options) },
            apply: { tr, value, _, _ in (value as! ResizeState).apply(tr) }),
        props: PluginProps(decorations: { state in
            guard let pluginState = columnResizingKey.getState(state), pluginState.activeHandle > -1
            else { return nil }
            return handleDecorations(state, pluginState.activeHandle)
        }))
}

/// The decorations for the resize handle at `cell`: a widget at the right edge
/// of every cell ending the hovered column (and, while dragging, a highlight
/// over those cells). Returns empty for a position that isn't a cell.
public func handleDecorations(_ state: EditorState, _ cell: Int) -> DecorationSet {
    guard cell >= 0, cell <= state.doc.content.size else { return .empty }
    let resolvedCell = state.doc.resolve(cell)
    guard pointsAtCell(resolvedCell), resolvedCell.depth >= 1 else { return .empty }
    let table = resolvedCell.node(-1)
    guard tableRole(table) == "table" else { return .empty }

    var decorations: [Decoration] = []
    let map = TableMap.get(table)
    let start = resolvedCell.start(-1)
    let col = map.colCount(resolvedCell.pos - start) + cellColspan(resolvedCell.nodeAfter!) - 1

    for row in 0..<map.height {
        let index = col + row * map.width
        // Add a handle for positions with a different cell (or the table edge)
        // to the right, and the table top or a different cell above.
        if (col == map.width - 1 || map.map[index] != map.map[index + 1])
            && (row == 0 || map.map[index] != map.map[index - map.width]) {
            let cellPos = map.map[index]
            let pos = start + cellPos + table.nodeAt(cellPos)!.nodeSize - 1
            if columnResizingKey.getState(state)?.dragging != nil {
                decorations.append(.node(start + cellPos, start + cellPos + table.nodeAt(cellPos)!.nodeSize,
                                         ["class": "column-resize-dragging"]))
            }
            decorations.append(.widget(pos, ["class": "column-resize-handle"]))
        }
    }
    return DecorationSet(decorations)
}

/// Set the width of the column ending at `cell`'s right edge: writes `width`
/// into the right `colwidth` slot of every cell spanning that column.
public func updateColumnWidth(_ tr: Transaction, _ cell: Int, _ width: Int) {
    // `cell` is supplied by the UI drag handler and may be stale if the document
    // changed mid-drag; guard like `handleDecorations` rather than force-unwrap.
    guard cell >= 0, cell <= tr.doc.content.size else { return }
    let resolvedCell = tr.doc.resolve(cell)
    guard pointsAtCell(resolvedCell), resolvedCell.depth >= 1,
          let cellAfter = resolvedCell.nodeAfter else { return }
    let table = resolvedCell.node(-1)
    guard tableRole(table) == "table" else { return }
    let map = TableMap.get(table)
    let start = resolvedCell.start(-1)
    let col = map.colCount(resolvedCell.pos - start) + cellColspan(cellAfter) - 1
    for row in 0..<map.height {
        let mapIndex = row * map.width + col
        // Rowspanning cell that has already been handled.
        if row > 0, map.map[mapIndex] == map.map[mapIndex - map.width] { continue }
        let pos = map.map[mapIndex]
        guard let cellNode = table.nodeAt(pos) else { continue }
        let colspan = cellColspan(cellNode)
        let index = colspan == 1 ? 0 : col - map.colCount(pos)
        if let colwidth = cellColwidth(cellNode), colwidth[index] == width { continue }
        var colwidth = cellColwidth(cellNode) ?? Array(repeating: 0, count: colspan)
        colwidth[index] = width
        var attrs = cellNode.attrs
        attrs["colwidth"] = .array(colwidth.map { .int($0) })
        _ = try? tr.setNodeMarkup(start + pos, nil, attrs)
    }
}
