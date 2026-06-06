import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands

/// A logical view of a table for selection math: every cell with its grid
/// coordinates and the document position just before it. Assumes non-spanning
/// cells (the common case; spanning would need a full TableMap).
struct TableGrid {
    struct Cell { var pos: Int; var row: Int; var col: Int; var node: Node }
    let table: Node
    let posBeforeTable: Int
    let cells: [Cell]
    let rows: Int
    let cols: Int

    init(table: Node, posBeforeTable: Int) {
        self.table = table
        self.posBeforeTable = posBeforeTable
        var cells: [Cell] = []
        var maxCols = 0
        var pos = posBeforeTable + 1 // inside the table, before the first row
        for r in 0..<table.childCount {
            let row = table.child(r)
            var cpos = pos + 1 // inside the row, before the first cell
            for c in 0..<row.childCount {
                cells.append(Cell(pos: cpos, row: r, col: c, node: row.child(c)))
                cpos += row.child(c).nodeSize
            }
            maxCols = Swift.max(maxCols, row.childCount)
            pos += row.nodeSize
        }
        self.cells = cells
        self.rows = table.childCount
        self.cols = maxCols
    }

    func cell(row: Int, col: Int) -> Cell? {
        cells.first { $0.row == row && $0.col == col }
    }

    func coordinate(ofCellAt pos: Int) -> (row: Int, col: Int)? {
        cells.first { $0.pos == pos }.map { ($0.row, $0.col) }
    }
}

/// Resolve the table containing a "before a cell" position, returning its node
/// and the document position before the table.
private func tableAround(_ cellPos: ResolvedPos) -> (table: Node, posBeforeTable: Int)? {
    let rowDepth = cellPos.depth
    guard rowDepth >= 1 else { return nil }
    let table = cellPos.node(rowDepth - 1)
    guard table.type.name == "table" else { return nil }
    return (table, cellPos.before(rowDepth - 1))
}

private func isCellPosition(_ pos: ResolvedPos) -> Bool {
    guard let after = pos.nodeAfter else { return false }
    return after.type.name == "tableCell" || after.type.name == "tableHeader"
}

/// A selection of a rectangular block of table cells.
public final class CellSelection: Selection {
    /// The resolved position before the anchor cell.
    public let anchorCell: ResolvedPos
    /// The resolved position before the head cell.
    public let headCell: ResolvedPos

    public init(_ anchorCell: ResolvedPos, _ headCell: ResolvedPos) {
        self.anchorCell = anchorCell
        self.headCell = headCell
        let ranges = CellSelection.computeRanges(anchorCell, headCell)
        super.init(anchorCell, headCell, ranges: ranges)
    }

    /// Build a CellSelection if both positions are cells of the same table;
    /// otherwise fall back to a text selection between them.
    public static func create(_ doc: Node, anchorCellPos: Int, headCellPos: Int) -> Selection {
        let anchor = doc.resolve(anchorCellPos)
        let head = doc.resolve(headCellPos)
        if isCellPosition(anchor), isCellPosition(head),
           let a = tableAround(anchor), let h = tableAround(head), a.posBeforeTable == h.posBeforeTable {
            return CellSelection(anchor, head)
        }
        return TextSelection.between(anchor, head)
    }

    private static func computeRanges(_ anchorCell: ResolvedPos, _ headCell: ResolvedPos) -> [SelectionRange] {
        guard let info = tableAround(anchorCell) else { return [SelectionRange(anchorCell, anchorCell)] }
        let grid = TableGrid(table: info.table, posBeforeTable: info.posBeforeTable)
        guard let a = grid.coordinate(ofCellAt: anchorCell.pos),
              let h = grid.coordinate(ofCellAt: headCell.pos) else {
            return [SelectionRange(anchorCell, anchorCell)]
        }
        let r0 = min(a.row, h.row), r1 = max(a.row, h.row)
        let c0 = min(a.col, h.col), c1 = max(a.col, h.col)
        let doc = anchorCell.doc
        var ranges: [SelectionRange] = []
        for r in r0...r1 {
            for c in c0...c1 {
                guard let cell = grid.cell(row: r, col: c) else { continue }
                ranges.append(SelectionRange(doc.resolve(cell.pos), doc.resolve(cell.pos + cell.node.nodeSize)))
            }
        }
        return ranges.isEmpty ? [SelectionRange(anchorCell, anchorCell)] : ranges
    }

    /// The selected cells (top-left to bottom-right), used for content/commands.
    public var selectedCellPositions: [Int] {
        guard let info = tableAround(anchorCell) else { return [anchorCell.pos] }
        let grid = TableGrid(table: info.table, posBeforeTable: info.posBeforeTable)
        guard let a = grid.coordinate(ofCellAt: anchorCell.pos),
              let h = grid.coordinate(ofCellAt: headCell.pos) else { return [anchorCell.pos] }
        let r0 = min(a.row, h.row), r1 = max(a.row, h.row)
        let c0 = min(a.col, h.col), c1 = max(a.col, h.col)
        var result: [Int] = []
        for r in r0...r1 { for c in c0...c1 { if let cell = grid.cell(row: r, col: c) { result.append(cell.pos) } } }
        return result
    }

    public override var empty: Bool { false }

    public override func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        let anchor = doc.resolve(mapping.map(anchorCell.pos))
        let head = doc.resolve(mapping.map(headCell.pos))
        if isCellPosition(anchor), isCellPosition(head),
           let a = tableAround(anchor), let h = tableAround(head), a.posBeforeTable == h.posBeforeTable {
            return CellSelection(anchor, head)
        }
        return Selection.near(head)
    }

    public override func content() -> Slice {
        guard let info = tableAround(anchorCell) else { return super.content() }
        let grid = TableGrid(table: info.table, posBeforeTable: info.posBeforeTable)
        guard let a = grid.coordinate(ofCellAt: anchorCell.pos),
              let h = grid.coordinate(ofCellAt: headCell.pos),
              let schema = info.table.type.schema,
              let rowType = schema.nodes["tableRow"] else { return super.content() }
        let r0 = min(a.row, h.row), r1 = max(a.row, h.row)
        let c0 = min(a.col, h.col), c1 = max(a.col, h.col)
        var rowNodes: [Node] = []
        for r in r0...r1 {
            var cells: [Node] = []
            for c in c0...c1 { if let cell = grid.cell(row: r, col: c) { cells.append(cell.node) } }
            if let row = try? rowType.create([:], content: Fragment.from(cells)) { rowNodes.append(row) }
        }
        let copy = info.table.copy(content: Fragment.from(rowNodes))
        return Slice(content: Fragment.from(copy), openStart: 0, openEnd: 0)
    }

    public override func eq(_ other: Selection) -> Bool {
        guard let o = other as? CellSelection else { return false }
        return o.anchorCell.pos == anchorCell.pos && o.headCell.pos == headCell.pos
    }

    public override func toJSON() -> [String: AttributeValue] {
        ["type": "cell", "anchor": .int(anchorCell.pos), "head": .int(headCell.pos)]
    }
}

/// Clear the content of every cell in a cell selection (the table-aware delete).
public let deleteCellSelectionContent: Command = { state, dispatch, _ in
    guard let selection = state.selection as? CellSelection else { return false }
    if let dispatch {
        let tr = state.tr
        // Replace each cell's content with an empty fillable block, back to front.
        for pos in selection.selectedCellPositions.sorted(by: >) {
            guard let cell = state.doc.nodeAt(pos),
                  let filled = cell.type.createAndFill() else { continue }
            _ = try? tr.replaceWith(pos, pos + cell.nodeSize, filled)
        }
        tr.setSelection(Selection.near(tr.doc.resolve(min(selection.anchorCell.pos + 2, tr.doc.content.size))))
        dispatch(tr.scrollIntoView())
    }
    return true
}
