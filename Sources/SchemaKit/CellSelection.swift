public import DocumentModel
public import DocumentTransform
public import EditorStateKit
public import EditorCommands

// A Selection subclass modelling a rectangular selection of table cells, ported
// from prosemirror-tables' cellselection.ts (minus the view-layer decoration
// drawing, which our renderer handles itself). Spanning-aware via TableMap.

public final class CellSelection: Selection {
    /// Resolved position in front of the anchor cell (the fixed corner).
    public let anchorCell: ResolvedPos
    /// Resolved position in front of the head cell (the moving corner).
    public let headCell: ResolvedPos

    public init(_ anchorCell: ResolvedPos, _ headCell: ResolvedPos? = nil) {
        let head = headCell ?? anchorCell
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let rect = map.rectBetween(anchorCell.pos - tableStart, head.pos - tableStart)
        let doc = anchorCell.node(0)
        var cells = map.cellsInRect(rect).filter { $0 != head.pos - tableStart }
        cells.insert(head.pos - tableStart, at: 0) // head cell is the primary range
        let ranges = cells.map { off -> SelectionRange in
            let cell = table.nodeAt(off)!
            let from = tableStart + off + 1
            return SelectionRange(doc.resolve(from), doc.resolve(from + cell.content.size))
        }
        self.anchorCell = anchorCell
        self.headCell = head
        super.init(ranges[0].from, ranges[0].to, ranges: ranges)
    }

    public override var empty: Bool { false }

    public override func map(_ doc: Node, _ mapping: any Mappable) -> Selection {
        let aCell = doc.resolve(mapping.map(anchorCell.pos))
        let hCell = doc.resolve(mapping.map(headCell.pos))
        if pointsAtCell(aCell), pointsAtCell(hCell), inSameTable(aCell, hCell) {
            let tableChanged = anchorCell.node(-1) != aCell.node(-1)
            if tableChanged, isRowSelection() { return CellSelection.rowSelection(aCell, hCell) }
            if tableChanged, isColSelection() { return CellSelection.colSelection(aCell, hCell) }
            return CellSelection(aCell, hCell)
        }
        return TextSelection.between(aCell, hCell)
    }

    /// A rectangular slice of table rows covering the selected cells.
    public override func content() -> Slice {
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let rect = map.rectBetween(anchorCell.pos - tableStart, headCell.pos - tableStart)
        var seen = Set<Int>()
        var rows: [Node] = []
        for row in rect.top..<rect.bottom {
            var rowContent: [Node] = []
            var index = row * map.width + rect.left
            var col = rect.left
            while col < rect.right {
                let pos = map.map[index]
                defer { col += 1; index += 1 }
                if seen.contains(pos) { continue }
                seen.insert(pos)
                let cellRect = map.findCell(pos)
                var cell = table.nodeAt(pos)!
                let extraLeft = rect.left - cellRect.left
                let extraRight = cellRect.right - rect.right
                if extraLeft > 0 || extraRight > 0 {
                    var attrs = cell.attrs
                    if extraLeft > 0 { attrs = removeColSpan(attrs, 0, extraLeft) }
                    if extraRight > 0 { attrs = removeColSpan(attrs, (attrs["colspan"]?.intValue ?? 1) - extraRight, extraRight) }
                    if cellRect.left < rect.left { cell = cell.type.createAndFill(attrs) ?? cell }
                    else { cell = (try? cell.type.create(attrs, content: cell.content)) ?? cell }
                }
                if cellRect.top < rect.top || cellRect.bottom > rect.bottom {
                    var attrs = cell.attrs
                    attrs["rowspan"] = .int(min(cellRect.bottom, rect.bottom) - max(cellRect.top, rect.top))
                    if cellRect.top < rect.top { cell = cell.type.createAndFill(attrs) ?? cell }
                    else { cell = (try? cell.type.create(attrs, content: cell.content)) ?? cell }
                }
                rowContent.append(cell)
            }
            rows.append(table.child(row).copy(content: Fragment.from(rowContent)))
        }
        let fragment = (isColSelection() && isRowSelection()) ? Fragment.from(table) : Fragment.from(rows)
        return Slice(content: fragment, openStart: 1, openEnd: 1)
    }

    public override func replace(_ tr: Transaction, _ content: Slice = .empty) {
        let mapFrom = tr.steps.count
        for (i, range) in ranges.enumerated() {
            let mapping = tr.mapping.slice(mapFrom)
            _ = try? tr.replace(mapping.map(range.from.pos), mapping.map(range.to.pos), i == 0 ? content : .empty)
        }
        let mapped = tr.mapping.slice(mapFrom).map(to)
        if let sel = Selection.findFrom(tr.doc.resolve(mapped), -1) { _ = tr.setSelection(sel) }
    }

    public override func replaceWith(_ tr: Transaction, _ node: Node) {
        replace(tr, Slice(content: Fragment.from(node), openStart: 0, openEnd: 0))
    }

    public func forEachCell(_ f: (Node, Int) -> Void) {
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let cells = map.cellsInRect(map.rectBetween(anchorCell.pos - tableStart, headCell.pos - tableStart))
        for off in cells { f(table.nodeAt(off)!, tableStart + off) }
    }

    /// Positions of all selected cells (compat with the previous renderer API).
    public var selectedCellPositions: [Int] {
        var result: [Int] = []
        forEachCell { _, pos in result.append(pos) }
        return result
    }

    /// True if the selection spans full columns (top to bottom).
    public func isColSelection() -> Bool {
        let anchorTop = anchorCell.index(-1)
        let headTop = headCell.index(-1)
        if min(anchorTop, headTop) > 0 { return false }
        let anchorBottom = anchorTop + (anchorCell.nodeAfter.map { cellRowspan($0) } ?? 1)
        let headBottom = headTop + (headCell.nodeAfter.map { cellRowspan($0) } ?? 1)
        return max(anchorBottom, headBottom) == headCell.node(-1).childCount
    }

    /// True if the selection spans full rows (left to right).
    public func isRowSelection() -> Bool {
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let anchorLeft = map.colCount(anchorCell.pos - tableStart)
        let headLeft = map.colCount(headCell.pos - tableStart)
        if min(anchorLeft, headLeft) > 0 { return false }
        let anchorRight = anchorLeft + (anchorCell.nodeAfter.map { cellColspan($0) } ?? 1)
        let headRight = headLeft + (headCell.nodeAfter.map { cellColspan($0) } ?? 1)
        return max(anchorRight, headRight) == map.width
    }

    public override func eq(_ other: Selection) -> Bool {
        guard let o = other as? CellSelection else { return false }
        return o.anchorCell.pos == anchorCell.pos && o.headCell.pos == headCell.pos
    }

    public override func toJSON() -> [String: AttributeValue] {
        ["type": .string("cell"), "anchor": .int(anchorCell.pos), "head": .int(headCell.pos)]
    }

    public override func getBookmark() -> any SelectionBookmark { CellBookmark(anchor: anchorCell.pos, head: headCell.pos) }

    /// The cell the map holds at `index`, if the position it gives really is a
    /// cell of this table.
    ///
    /// Every caller below computes a position out of map arithmetic and then
    /// resolves it. That is safe for a rectangular table, but a document is
    /// briefly ragged mid-transaction — the selection is mapped before
    /// `fixTables` squares the table up — and an index can then land outside it.
    /// Resolving that and handing it to `CellSelection.init` trapped, because a
    /// table map cannot be built from the document node.
    private static func cell(_ doc: Node, _ map: TableMap, _ tableStart: Int, _ index: Int) -> ResolvedPos? {
        guard index >= 0, index < map.map.count else { return nil }
        let pos = tableStart + map.map[index]
        guard pos >= 0, pos <= doc.content.size else { return nil }
        let resolved = doc.resolve(pos)
        return pointsAtCell(resolved) ? resolved : nil
    }

    /// The smallest column selection covering the two cells.
    public static func colSelection(_ anchorCell0: ResolvedPos, _ headCell0: ResolvedPos? = nil) -> CellSelection {
        var anchorCell = anchorCell0
        var headCell = headCell0 ?? anchorCell0
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let anchorRect = map.findCell(anchorCell.pos - tableStart)
        let headRect = map.findCell(headCell.pos - tableStart)
        let doc = anchorCell.node(0)
        if anchorRect.top <= headRect.top {
            if anchorRect.top > 0, let c = cell(doc, map, tableStart, anchorRect.left) { anchorCell = c }
            if headRect.bottom < map.height,
               let c = cell(doc, map, tableStart, map.width * (map.height - 1) + headRect.right - 1) { headCell = c }
        } else {
            if headRect.top > 0, let c = cell(doc, map, tableStart, headRect.left) { headCell = c }
            if anchorRect.bottom < map.height,
               let c = cell(doc, map, tableStart, map.width * (map.height - 1) + anchorRect.right - 1) { anchorCell = c }
        }
        return CellSelection(anchorCell, headCell)
    }

    /// The smallest row selection covering the two cells.
    public static func rowSelection(_ anchorCell0: ResolvedPos, _ headCell0: ResolvedPos? = nil) -> CellSelection {
        var anchorCell = anchorCell0
        var headCell = headCell0 ?? anchorCell0
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let anchorRect = map.findCell(anchorCell.pos - tableStart)
        let headRect = map.findCell(headCell.pos - tableStart)
        let doc = anchorCell.node(0)
        if anchorRect.left <= headRect.left {
            if anchorRect.left > 0, let c = cell(doc, map, tableStart, anchorRect.top * map.width) { anchorCell = c }
            if headRect.right < map.width,
               let c = cell(doc, map, tableStart, map.width * (headRect.top + 1) - 1) { headCell = c }
        } else {
            if headRect.left > 0, let c = cell(doc, map, tableStart, headRect.top * map.width) { headCell = c }
            if anchorRect.right < map.width,
               let c = cell(doc, map, tableStart, map.width * (anchorRect.top + 1) - 1) { anchorCell = c }
        }
        return CellSelection(anchorCell, headCell)
    }

    /// Create a CellSelection (falling back to a text selection if the positions
    /// aren't cells of the same table).
    public static func create(_ doc: Node, _ anchorCell: Int, _ headCell: Int? = nil) -> Selection {
        let a = doc.resolve(anchorCell), h = doc.resolve(headCell ?? anchorCell)
        if pointsAtCell(a), pointsAtCell(h), inSameTable(a, h) { return CellSelection(a, h) }
        return TextSelection.between(a, h)
    }

    /// Compatibility overload (previous labelled signature).
    public static func create(_ doc: Node, anchorCellPos: Int, headCellPos: Int) -> Selection {
        create(doc, anchorCellPos, headCellPos)
    }

    /// A cell selection from JSON, or a plain text selection when the positions
    /// don't describe two cells of one table.
    ///
    /// Both guards matter for JSON that came from outside: `resolve` traps
    /// outside the document, and `CellSelection.init` builds a table map from
    /// whatever it finds at the position — which is a precondition failure when
    /// that isn't a table. `create` already answers both questions.
    public static func fromCellJSON(_ doc: Node, _ json: [String: AttributeValue]) -> Selection {
        let size = doc.content.size
        func clamped(_ key: String) -> Int { min(max(json[key]?.intValue ?? 0, 0), size) }
        return create(doc, clamped("anchor"), clamped("head"))
    }
}

public struct CellBookmark: SelectionBookmark {
    public let anchor: Int
    public let head: Int
    public init(anchor: Int, head: Int) { self.anchor = anchor; self.head = head }

    public func map(_ mapping: any Mappable) -> any SelectionBookmark {
        CellBookmark(anchor: mapping.map(anchor), head: mapping.map(head))
    }
    public func resolve(_ doc: Node) -> Selection {
        let aCell = doc.resolve(anchor), hCell = doc.resolve(head)
        if tableRole(aCell.parent) == "row", tableRole(hCell.parent) == "row",
           aCell.index() < aCell.parent.childCount, hCell.index() < hCell.parent.childCount,
           inSameTable(aCell, hCell) {
            return CellSelection(aCell, hCell)
        }
        return Selection.near(hCell, 1)
    }
}

/// Convert a NodeSelection of a cell/row/table into the matching CellSelection.
public func normalizeSelection(_ state: EditorState, _ tr0: Transaction?, _ allowTableNodeSelection: Bool) -> Transaction? {
    // Read through `tr0` when there is one; otherwise straight off the state —
    // `state.tr` would build a fresh Transaction just to ask it these.
    let sel = tr0?.selection ?? state.selection
    let doc = tr0?.doc ?? state.doc
    var tr = tr0
    var normalize: Selection?
    if let ns = sel as? NodeSelection, let role = tableRole(ns.node) {
        if role == "cell" || role == "header_cell" {
            normalize = CellSelection.create(doc, ns.from)
        } else if role == "row" {
            let cell = doc.resolve(ns.from + 1)
            normalize = CellSelection.rowSelection(cell, cell)
        } else if !allowTableNodeSelection {
            let map = TableMap.get(ns.node)
            // A well-formed table always has ≥1 cell; guard a degenerate (empty)
            // map so `width * height - 1` can't index out of bounds.
            if !map.map.isEmpty {
                let start = ns.from + 1
                let lastCell = start + map.map[map.width * map.height - 1]
                normalize = CellSelection.create(doc, start + 1, lastCell)
            }
        }
    }
    if let normalize {
        if tr == nil { tr = state.tr }
        _ = tr!.setSelection(normalize)
    }
    return tr
}

/// Clear the content of every cell in a cell selection (the table-aware delete).
public let deleteCellSelectionContent: Command = { state, dispatch, _ in
    guard let selection = state.selection as? CellSelection else { return false }
    if let dispatch {
        let tr = state.tr
        for pos in selection.selectedCellPositions.sorted(by: >) {
            guard let cell = state.doc.nodeAt(pos), let filled = cell.type.createAndFill() else { continue }
            _ = try? tr.replaceWith(pos, pos + cell.nodeSize, filled)
        }
        tr.setSelection(Selection.near(tr.doc.resolve(min(selection.anchorCell.pos + 2, tr.doc.content.size))))
        dispatch(tr.scrollIntoView())
    }
    return true
}
