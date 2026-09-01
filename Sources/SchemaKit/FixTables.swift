public import DocumentModel
import DocumentTransform
public import EditorStateKit

// Ported from prosemirror-tables' fixtables.ts — normalizes tables so no cells
// overlap and every row has the same width, using the problems TableMap reports.
// Wired as the table extension's appendTransaction plugin so tables stay
// rectangular after every edit (the invariant our commands assume).

/// Inspect every table in the state and return a transaction that fixes any
/// malformed ones, or nil if all are already well-formed.
public func fixTables(_ state: EditorState, _ oldState: EditorState?) -> Transaction? {
    var tr: Transaction?
    state.doc.descendants { node, pos, _, _ in
        if node.type.name == "table" { tr = fixTable(state, node, pos, tr) }
        // A textblock holds inline content, and a table is not inline: nothing
        // below one can be a table, so don't walk the document's actual text.
        // Tables themselves are still descended into — a cell can nest one.
        return !node.isTextblock
    }
    return tr
}

/// Fix a single table, appending to `tr0` (or creating one) if it has problems.
public func fixTable(_ state: EditorState, _ table: Node, _ tablePos: Int, _ tr0: Transaction?) -> Transaction? {
    let map = TableMap.get(table)
    guard let problems = map.problems, !problems.isEmpty else { return tr0 }
    let tr = tr0 ?? state.tr

    var mustAdd = [Int](repeating: 0, count: map.height)
    for prob in problems {
        switch prob {
        case let .collision(pos, row, n):
            guard let cell = table.nodeAt(pos) else { continue }
            for j in 0..<cellRowspan(cell) where row + j < mustAdd.count { mustAdd[row + j] += n }
            _ = try? tr.setNodeMarkup(tr.mapping.map(tablePos + 1 + pos), nil,
                                      removeColSpan(cell.attrs, cellColspan(cell) - n, n))
        case let .missing(row, n):
            mustAdd[row] += n
        case let .overlongRowspan(pos, n):
            guard let cell = table.nodeAt(pos) else { continue }
            var attrs = cell.attrs
            attrs["rowspan"] = .int(cellRowspan(cell) - n)
            _ = try? tr.setNodeMarkup(tr.mapping.map(tablePos + 1 + pos), nil, attrs)
        case let .colwidthMismatch(pos, colwidth):
            guard let cell = table.nodeAt(pos) else { continue }
            var attrs = cell.attrs
            attrs["colwidth"] = .array(colwidth.map { .int($0) })
            _ = try? tr.setNodeMarkup(tr.mapping.map(tablePos + 1 + pos), nil, attrs)
        case .zeroSized:
            let pos = tr.mapping.map(tablePos)
            _ = try? tr.delete(pos, pos + table.nodeSize)
        }
    }

    var first: Int?
    var last: Int?
    for i in mustAdd.indices where mustAdd[i] != 0 {
        if first == nil { first = i }
        last = i
    }
    // Add the cells each row is missing, biasing toward the start of the row
    // after a "bite" out of the table, otherwise the end.
    var pos = tablePos + 1
    for i in 0..<map.height {
        let row = table.child(i)
        let end = pos + row.nodeSize
        let add = mustAdd[i]
        if add > 0 {
            let cellType = row.firstChild?.type ?? tableNodeTypes(state.schema)["cell"]!
            var nodes: [Node] = []
            for _ in 0..<add { if let node = cellType.createAndFill() { nodes.append(node) } }
            let side = (i == 0 || first == i - 1) && last == i ? pos + 1 : end - 1
            _ = try? tr.insert(tr.mapping.map(side), Fragment.from(nodes))
        }
        pos = end
    }
    // Then square the widths up on the table as it now is. The cells just
    // added carry no width, so a column that had one is contested again — and
    // the plugin is never re-asked about its own appended transaction, which is
    // how a mismatch used to survive until the next edit and, when that edit
    // bit the table again, the one after that. One more pass, on the fixed
    // table, closes it; there is nothing structural left for it to disturb.
    if !mustAdd.contains(where: { $0 != 0 }) { return tr }
    let fixedPos = tr.mapping.map(tablePos)
    guard let fixed = tr.doc.nodeAt(fixedPos), fixed.type.name == "table" else { return tr }
    for case let .colwidthMismatch(pos, colwidth) in TableMap.get(fixed).problems ?? [] {
        guard let cell = fixed.nodeAt(pos) else { continue }
        var attrs = cell.attrs
        attrs["colwidth"] = .array(colwidth.map { .int($0) })
        _ = try? tr.setNodeMarkup(fixedPos + 1 + pos, nil, attrs)
    }
    return tr
}
