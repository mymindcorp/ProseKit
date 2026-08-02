public import DocumentModel
public import EditorStateKit

// Helpers ported from prosemirror-tables' util.ts. ProseMirror identifies table
// nodes via a `tableRole` node-spec field; our schema uses fixed type names, so
// we map name → role here.

func tableRole(_ type: NodeType) -> String? {
    switch type.name {
    case "table": return "table"
    case "tableRow": return "row"
    case "tableCell": return "cell"
    case "tableHeader": return "header_cell"
    default: return nil
    }
}
func tableRole(_ node: Node) -> String? { tableRole(node.type) }

func tableNodeTypes(_ schema: Schema) -> [String: NodeType] {
    var result: [String: NodeType] = [:]
    for (_, type) in schema.nodes { if let role = tableRole(type) { result[role] = type } }
    return result
}

/// A resolved position in front of the cell containing `pos`, if any.
public func cellAround(_ pos: ResolvedPos) -> ResolvedPos? {
    var d = pos.depth - 1
    while d > 0 {
        if tableRole(pos.node(d)) == "row" { return pos.node(0).resolve(pos.before(d + 1)) }
        d -= 1
    }
    return nil
}

func cellWrapping(_ pos: ResolvedPos) -> Node? {
    var d = pos.depth
    while d > 0 {
        let role = tableRole(pos.node(d))
        if role == "cell" || role == "header_cell" { return pos.node(d) }
        d -= 1
    }
    return nil
}

public func isInTable(_ state: EditorState) -> Bool {
    let head = state.selection.resolvedHead
    var d = head.depth
    while d > 0 { if tableRole(head.node(d)) == "row" { return true }; d -= 1 }
    return false
}

/// A resolved position in front of the cell the selection's "active" side is in.
func selectionCell(_ state: EditorState) -> ResolvedPos? {
    let sel = state.selection
    if let cs = sel as? CellSelection {
        return cs.anchorCell.pos > cs.headCell.pos ? cs.anchorCell : cs.headCell
    }
    if let ns = sel as? NodeSelection, tableRole(ns.node) == "cell" {
        return ns.resolvedAnchor
    }
    return cellAround(sel.resolvedHead) ?? cellNear(sel.resolvedHead)
}

func cellNear(_ pos: ResolvedPos) -> ResolvedPos? {
    var after = pos.nodeAfter
    var p = pos.pos
    while let a = after {
        let role = tableRole(a)
        if role == "cell" || role == "header_cell" { return pos.doc.resolve(p) }
        after = a.firstChild; p += 1
    }
    var before = pos.nodeBefore
    p = pos.pos
    while let b = before {
        let role = tableRole(b)
        if role == "cell" || role == "header_cell" { return pos.doc.resolve(p - b.nodeSize) }
        before = b.lastChild; p -= 1
    }
    return nil
}

func pointsAtCell(_ pos: ResolvedPos) -> Bool {
    tableRole(pos.parent) == "row" && pos.nodeAfter != nil
}

func moveCellForward(_ pos: ResolvedPos) -> ResolvedPos {
    pos.node(0).resolve(pos.pos + (pos.nodeAfter?.nodeSize ?? 0))
}

public func inSameTable(_ a: ResolvedPos, _ b: ResolvedPos) -> Bool {
    a.depth == b.depth && a.pos >= b.start(-1) && a.pos <= b.end(-1)
}

public func findCell(_ pos: ResolvedPos) -> TableRect {
    TableMap.get(pos.node(-1)).findCell(pos.pos - pos.start(-1))
}
public func colCount(_ pos: ResolvedPos) -> Int {
    TableMap.get(pos.node(-1)).colCount(pos.pos - pos.start(-1))
}
public func nextCell(_ pos: ResolvedPos, _ axis: TableAxis, _ dir: Int) -> ResolvedPos? {
    let table = pos.node(-1)
    let map = TableMap.get(table)
    let tableStart = pos.start(-1)
    guard let moved = map.nextCell(pos.pos - tableStart, axis, dir) else { return nil }
    return pos.node(0).resolve(tableStart + moved)
}

/// Decrease a cell's colspan, dropping the matching column widths.
func removeColSpan(_ attrs: Attrs, _ pos: Int, _ n: Int = 1) -> Attrs {
    var result = attrs
    result["colspan"] = .int((attrs["colspan"]?.intValue ?? 1) - n)
    if case let .array(cw)? = attrs["colwidth"], !cw.isEmpty {
        var arr = cw
        arr.removeSubrange(min(pos, arr.count)..<min(pos + n, arr.count))
        result["colwidth"] = arr.contains(where: { ($0.intValue ?? 0) > 0 }) ? .array(arr) : .null
    }
    return result
}
/// Increase a cell's colspan, inserting zero column widths.
func addColSpan(_ attrs: Attrs, _ pos: Int, _ n: Int = 1) -> Attrs {
    var result = attrs
    result["colspan"] = .int((attrs["colspan"]?.intValue ?? 1) + n)
    if case let .array(cw)? = attrs["colwidth"], !cw.isEmpty {
        var arr = cw
        for _ in 0..<n { arr.insert(.int(0), at: min(pos, arr.count)) }
        result["colwidth"] = .array(arr)
    }
    return result
}

func columnIsHeader(_ map: TableMap, _ table: Node, _ col: Int) -> Bool {
    let headerCell = unsafe tableNodeTypes(table.type.schema)["header_cell"]
    for row in 0..<map.height {
        if table.nodeAt(map.map[col + row * map.width])?.type !== headerCell { return false }
    }
    return true
}
