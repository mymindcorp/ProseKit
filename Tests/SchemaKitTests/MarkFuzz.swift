import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for marks: adding one over a range, and taking it off again.
//
// The two mark transforms split text nodes, merge them back, and negotiate the
// schema's exclusion rules (a code mark throws the others out) — all over a
// range that can start in one block and end three levels deeper in another.
// The hand-written tests cover a paragraph. This puts every mark type over
// ranges cut from every generated document and asks for the three things a
// mark transform owes: the document is still valid, the mark is on everything
// it could go on, and removing it puts things back the way they were.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerMarkFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("mark fuzz: a mark added over a range covers what it can, and comes off cleanly") {
        let schema = try fuzzSchema()
        var rng = SelRNG(83)
        for (seed, doc) in fuzzCorpus(schema, count: 30) {
            let base = fuzzState(doc, schema)
            let size = doc.content.size
            guard size > 0 else { continue }
            for typeName in schema.markSpecOrder {
                guard let type = schema.marks[typeName] else { continue }
                var attrs: Attrs = [:]
                if type.attrs["href"] != nil { attrs["href"] = .string("https://example.com/m") }
                if type.attrs["color"] != nil { attrs["color"] = .string("#123456") }
                let mark = schema.mark(type, attrs)

                var ranges: [(Int, Int)] = [(0, size)]
                for _ in 0 ..< 5 {
                    let a = Int.random(in: 0 ... size, using: &rng), b = Int.random(in: 0 ... size, using: &rng)
                    ranges.append((Swift.min(a, b), Swift.max(a, b)))
                }
                for (from, to) in ranges {
                    let ctx = "\(typeName) over \(from)..\(to) in \(seed)"

                    // The mark goes on.
                    let add = base.tr
                    guard (try? add.addMark(from, to, mark)) != nil else {
                        try expect(false, "addMark threw — \(ctx)")
                        continue
                    }
                    try checkValid(add.doc, "after addMark — \(ctx)")
                    try expectEqual(add.doc.content.size, size, "addMark changed the document's size — \(ctx)")
                    // Every text node inside the range whose parent takes the mark
                    // now carries it — unless something already on it excludes it
                    // *and wins*, which is the one case `addToSet` decides.
                    var missing: [String] = []
                    add.doc.nodesBetween(from, to) { node, pos, parent, _ in
                        guard node.isText, pos >= from, pos + node.nodeSize <= to,
                              let parent, parent.type.allowsMarkType(type) else { return true }
                        let expected = mark.addToSet(node.marks).contains { $0.eq(mark) }
                        if expected, !node.marks.contains(where: { $0.eq(mark) }) {
                            missing.append("\(node.text ?? "") at \(pos)")
                        }
                        return true
                    }
                    try expect(missing.isEmpty, "addMark skipped \(missing) — \(ctx)")
                    missing = []

                    // And comes off, restoring the original where the original had
                    // nothing this mark would have thrown out.
                    let remove = base.apply(add).tr
                    guard (try? remove.removeMark(from, to, type)) != nil else {
                        try expect(false, "removeMark threw — \(ctx)")
                        continue
                    }
                    try checkValid(remove.doc, "after removeMark — \(ctx)")
                    remove.doc.nodesBetween(from, to) { node, pos, _, _ in
                        if node.isText, pos >= from, pos + node.nodeSize <= to,
                           node.marks.contains(where: { $0.type === type }) {
                            missing.append("still marked at \(pos)")
                        }
                        return true
                    }
                    try expect(missing.isEmpty, "removeMark left the mark on \(missing) — \(ctx)")
                    missing = []

                    if !rangeIsDisturbed(doc, from, to, by: mark) {
                        try expect(remove.doc == doc,
                                   "add then remove didn't restore the document — \(ctx)\n  before:\n\(fuzzOutline(doc))  after:\n\(fuzzOutline(remove.doc))")
                    }

                    // Removing a mark that isn't there is a no-op.
                    if !rangeHasMark(doc, from, to, type) {
                        let noop = base.tr
                        _ = try? noop.removeMark(from, to, type)
                        try expect(!noop.docChanged, "removing an absent mark changed the document — \(ctx)")
                    }
                }
            }
        }
    }
}

private func checkValid(_ doc: Node, _ ctx: @autoclosure () -> String) throws {
    var invalid: (any Error)?
    do { try doc.check() } catch { invalid = error }
    try expect(invalid == nil, "invalid document \(ctx()): \(invalid.map { "\($0)" } ?? "")")
}

/// Whether adding `mark` over the range touches anything that was already
/// there: a mark of the same type (removal would take the original off too, so
/// add-then-remove can't restore it) or one the new mark excludes (it is
/// dropped on add and not put back on remove). Where either is true,
/// add-then-remove has no reason to be an identity.
private func rangeIsDisturbed(_ doc: Node, _ from: Int, _ to: Int, by mark: Mark) -> Bool {
    var disturbed = false
    doc.nodesBetween(from, to) { node, _, _, _ in
        guard node.isText else { return true }
        if node.marks.contains(where: { $0.type === mark.type }) { disturbed = true }
        let after = mark.addToSet(node.marks)
        for old in node.marks where !after.contains(where: { $0.eq(old) }) { disturbed = true }
        return !disturbed
    }
    return disturbed
}

private func rangeHasMark(_ doc: Node, _ from: Int, _ to: Int, _ type: MarkType) -> Bool {
    var found = false
    doc.nodesBetween(from, to) { node, _, _, _ in
        if node.marks.contains(where: { $0.type === type }) { found = true }
        return !found
    }
    return found
}
