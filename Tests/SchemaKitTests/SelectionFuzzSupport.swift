import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

/// A deterministic corpus of documents for the fuzz sweeps.
func fuzzCorpus(_ schema: Schema, count: Int) -> [(seed: String, doc: Node)] {
    generatedCorpus(schema, count: count)
}

/// The richest schema in the package: everything `fullKit` registers, plus the
/// two opt-in node families, so the corpus really does cover every node type.
func fuzzSchema() throws -> Schema {
    try Editor(extensions: fullKit() + figureExtensions() + footnoteExtensions()).schema
}

/// The generator's RNG, reused by the sweeps for their own random choices.
typealias SelRNG = SeededRNG

import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestHarness

// A fuzzer for the selection layer.
//
// It builds random *schema-valid* documents out of every node type the kit
// defines, puts a selection at every position in each one, and checks the three
// things a selection is supposed to guarantee:
//
//   1. it lands somewhere a caret can actually be (a text selection's endpoints
//      are in inline content, a node selection's node is selectable, a gap
//      cursor's position is a valid gap),
//   2. it reports the positions it was asked for — `near` at a spot that
//      already takes a caret stays put, a forward search never moves backwards,
//      JSON and bookmarks round-trip to the same selection,
//   3. it never modifies the document.
//
// Documents come from walking each node type's content expression rather than a
// hand-written list, so the coverage grows by itself as extensions are added —
// and the first test asserts that every node type reachable from `doc` really
// did show up in the corpus.
//
// The sweeps are exhaustive and cost more than the rest of the suite put
// together, so they are opt-in:
//
//     PROSEKIT_FUZZ=1 swift run SchemaKitTests
//     PROSEKIT_FUZZ=1 PROSEKIT_FUZZ_DOCS=2000 swift run SchemaKitTests   # deeper

// MARK: - Invariants

let fuzzCellTypeNames: Set<String> = ["tableCell", "tableHeader"]

/// An independent restatement of what makes a gap cursor a gap: it may not sit
/// next to something a text caret can already reach. If the node right before
/// (or after) it is an ordinary textblock the caret goes in there and there is
/// no gap — an atom or an isolating node is exactly the case gap cursors exist
/// for. Deliberately not phrased in terms of `GapCursor.valid`, which is the
/// thing under test.
private func gapNeighboursAreClosed(_ pos: ResolvedPos) -> Bool {
    func closed(_ node: Node?) -> Bool {
        guard let node else { return true }
        return node.isAtom || node.type.spec.isolating || !node.inlineContent
    }
    return closed(pos.nodeBefore) && closed(pos.nodeAfter)
}

/// Whether every row of a table holds the same number of columns. A table can
/// be ragged for a moment — inserting into the gap between two rows wraps the
/// content in a one-cell row of its own — and `fixTables` squares it up in an
/// appended transaction. `TableMap` reads a ragged table as best it can, so the
/// positions it hands back are only meaningful once the table is square again.
private func tableIsRectangular(_ table: Node) -> Bool {
    var width: Int?
    for r in 0 ..< table.childCount {
        let row = table.child(r)
        var cols = 0
        for c in 0 ..< row.childCount { cols += row.child(c).attrs["colspan"]?.intValue ?? 1 }
        if let width, width != cols { return false }
        width = cols
    }
    return true
}

func describeSelection(_ sel: Selection) -> String {
    if let cs = sel as? CellSelection {
        return "CellSelection(anchorCell: \(cs.anchorCell.pos), headCell: \(cs.headCell.pos))"
    }
    return "\(type(of: sel))(anchor: \(sel.anchor), head: \(sel.head))"
}

/// Everything that must hold of a selection the library *produced*. (Not of one
/// a caller forced with `TextSelection.create`, which takes the positions it is
/// given — that is what `Selection.near` and `TextSelection.between` are for.)
func checkSelectionValid(_ sel: Selection, in doc: Node, _ ctx: @autoclosure () -> String) throws {
    let size = doc.content.size
    let what = "\(describeSelection(sel)) — \(ctx())"
    try expect(sel.from >= 0 && sel.to <= size, "out of range \(sel.from)..\(sel.to) in a doc of \(size): \(what)")
    try expect(sel.from <= sel.to, "inverted range \(sel.from)..\(sel.to): \(what)")
    try expectEqual(sel.from, Swift.min(sel.anchor, sel.head), "from is not min(anchor, head): \(what)")
    try expectEqual(sel.to, Swift.max(sel.anchor, sel.head), "to is not max(anchor, head): \(what)")
    try expectEqual(sel.resolvedAnchor.pos, sel.anchor, "resolvedAnchor disagrees with anchor: \(what)")
    try expectEqual(sel.resolvedHead.pos, sel.head, "resolvedHead disagrees with head: \(what)")
    try expectEqual(sel.resolvedFrom.pos, sel.from, "resolvedFrom disagrees with from: \(what)")
    try expectEqual(sel.resolvedTo.pos, sel.to, "resolvedTo disagrees with to: \(what)")
    try expect(sel.resolvedAnchor.doc == doc, "anchor resolved against a different document: \(what)")
    try expect(sel.resolvedHead.doc == doc, "head resolved against a different document: \(what)")
    if sel.empty { try expectEqual(sel.from, sel.to, "an empty selection spans a range: \(what)") }

    switch sel {
    case let ts as TextSelection:
        try expect(ts.resolvedAnchor.parent.inlineContent,
                   "text selection anchor is in \(ts.resolvedAnchor.parent.type.name), which takes no text: \(what)")
        try expect(ts.resolvedHead.parent.inlineContent,
                   "text selection head is in \(ts.resolvedHead.parent.type.name), which takes no text: \(what)")
        try expectEqual(ts.cursor?.pos, ts.anchor == ts.head ? ts.head : nil, "cursor disagrees with anchor/head: \(what)")
    case let ns as NodeSelection:
        try expect(ns.resolvedAnchor.nodeAfter != nil, "node selection with no node after it: \(what)")
        guard let after = ns.resolvedAnchor.nodeAfter else { break }
        try expect(NodeSelection.isSelectable(after), "node selection on unselectable \(after.type.name): \(what)")
        try expect(ns.node == after, "node selection's node is not the node at its anchor: \(what)")
        try expectEqual(ns.head, ns.anchor + after.nodeSize, "node selection doesn't span its node: \(what)")
        try expect(!ns.empty, "a node selection reports itself empty: \(what)")
    case let gc as GapCursor:
        try expect(GapCursor.valid(gc.resolvedHead), "gap cursor at a position that isn't a gap: \(what)")
        try expect(gapNeighboursAreClosed(gc.resolvedHead),
                   "gap cursor next to \(gc.resolvedHead.nodeBefore?.type.name ?? "-")/\(gc.resolvedHead.nodeAfter?.type.name ?? "-"), which a caret can already reach: \(what)")
        try expect(gc.empty && gc.anchor == gc.head, "gap cursor is not a collapsed point: \(what)")
    case let cs as CellSelection:
        try expect(fuzzCellTypeNames.contains(cs.anchorCell.nodeAfter?.type.name ?? ""), "anchorCell is not a cell: \(what)")
        try expect(fuzzCellTypeNames.contains(cs.headCell.nodeAfter?.type.name ?? ""), "headCell is not a cell: \(what)")
        var visited = 0
        cs.forEachCell { node, pos in
            visited += 1
            _ = node
            _ = pos
        }
        try expect(visited > 0, "cell selection covers no cells: \(what)")
        try expectEqual(cs.selectedCellPositions.count, visited, "selectedCellPositions disagrees with forEachCell: \(what)")
        if tableIsRectangular(cs.anchorCell.node(-1)) {
            for pos in cs.selectedCellPositions {
                try expect(fuzzCellTypeNames.contains(doc.resolve(pos).nodeAfter?.type.name ?? ""),
                           "a selected position is not a cell: \(what)")
            }
        }
    case is AllSelection:
        try expectEqual(sel.from, 0, "AllSelection doesn't start at 0: \(what)")
        try expectEqual(sel.to, size, "AllSelection doesn't end at the document end: \(what)")
    default:
        break
    }
}

/// JSON, bookmarks and an empty mapping must all come back with the very same
/// selection. (`Selection.fromJSON` doesn't know about cell selections — the
/// table layer decodes those, so route them the way a host would.)
func checkSelectionRoundTrips(_ sel: Selection, in doc: Node, _ ctx: @autoclosure () -> String) throws {
    let what = "\(describeSelection(sel)) — \(ctx())"
    try expect(sel.eq(sel), "a selection is not equal to itself: \(what)")

    let json = sel.toJSON()
    let decoded = json["type"]?.stringValue == "cell"
        ? CellSelection.fromCellJSON(doc, json)
        : try Selection.fromJSON(doc, json)
    try expect(decoded.eq(sel), "JSON round-trip changed the selection to \(describeSelection(decoded)): \(what)")
    try checkSelectionValid(decoded, in: doc, "decoded from JSON — \(ctx())")

    let remapped = sel.getBookmark().map(Mapping()).resolve(doc)
    try expect(remapped.eq(sel), "mapping a bookmark through an empty mapping changed the selection to \(describeSelection(remapped)): \(what)")

    let bookmarked = sel.getBookmark().resolve(doc)
    try expect(bookmarked.eq(sel), "bookmark round-trip changed the selection to \(describeSelection(bookmarked)): \(what)")
    try checkSelectionValid(bookmarked, in: doc, "resolved from a bookmark — \(ctx())")

    let mapped = sel.map(doc, Mapping())
    try expect(mapped.eq(sel), "mapping through an empty mapping changed the selection to \(describeSelection(mapped)): \(what)")
    try checkSelectionValid(mapped, in: doc, "mapped through an empty mapping — \(ctx())")
}

/// A selection is a read of the document. Building one, asking it for its
/// content, and putting it on a transaction must all leave the doc alone.
func checkSelectionDoesNotModify(_ sel: Selection, _ state: EditorState, _ ctx: @autoclosure () -> String) throws {
    let doc = state.doc
    let what = "\(describeSelection(sel)) — \(ctx())"

    let content = sel.content()
    try expect(content.openStart >= 0 && content.openEnd >= 0, "negative open depth on selection content: \(what)")
    try expect(state.doc == doc, "asking a selection for its content changed the document: \(what)")

    let tr = state.tr.setSelection(sel)
    try expect(!tr.docChanged, "setting a selection produced \(tr.steps.count) step(s): \(what)")
    try expect(tr.doc == doc, "setting a selection changed the transaction's document: \(what)")
    try expect(tr.selection.eq(sel), "the transaction lost the selection it was given: \(what)")

    let applied = state.apply(tr)
    try expect(applied.doc == doc, "applying a selection-only transaction changed the document: \(what)")
    try expect(applied.selection.eq(sel), "applying a selection-only transaction changed the selection to \(describeSelection(applied.selection)): \(what)")
}

// MARK: - Building selections

func fuzzState(_ doc: Node, _ schema: Schema) -> EditorState {
    EditorState.create(EditorStateConfig(schema: schema, doc: doc))
}

/// Every kind of selection the library will build for a document, at every
/// position it will build one — the input set for the round-trip and
/// immutability sweeps.
func everySelection(in doc: Node) -> [Selection] {
    var out: [Selection] = [AllSelection(doc), Selection.atStart(doc), Selection.atEnd(doc)]
    for pos in 0 ... doc.content.size {
        let resolved = doc.resolve(pos)
        out.append(Selection.near(resolved, 1))
        out.append(Selection.near(resolved, -1))
        out.append(NodeSelection.create(doc, pos))
        if GapCursor.valid(resolved) { out.append(GapCursor(resolved)) }
        if resolved.parent.inlineContent {
            out.append(TextSelection.between(resolved, doc.resolve(Swift.min(pos + 1, doc.content.size))))
        }
    }
    var cells: [Int] = []
    doc.descendants { node, pos, _, _ in
        if fuzzCellTypeNames.contains(node.type.name) { cells.append(pos) }
        return true
    }
    for a in cells { for b in cells { out.append(CellSelection.create(doc, a, b)) } }
    return out
}
