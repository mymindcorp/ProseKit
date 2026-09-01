import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for decorations mapped through edits.
//
// Search highlights, suggestion markers and collaborators' carets are all
// decorations, and none of them is rebuilt on every keystroke — they are
// *mapped* through the transaction and drawn where they land. A decoration
// that lands outside the document is a crash in the renderer; an inline one
// that lands inverted is a range nothing can draw; a node decoration that
// stops spanning exactly one node is styling applied to half a paragraph.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerDecorationFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("decoration fuzz: decorations survive mapping through random edits") {
        let schema = try fuzzSchema()
        var rng = SelRNG(89)
        for (seed, doc) in fuzzCorpus(schema, count: 30) {
            let state = fuzzState(doc, schema)
            let set = everyDecoration(in: doc)

            // Mapping through nothing changes nothing.
            let same = set.map(Mapping())
            try expectEqual(same.decorations.count, set.decorations.count, "an empty mapping dropped decorations at \(seed)")
            for (a, b) in zip(set.decorations, same.decorations) {
                try expect(a.from == b.from && a.to == b.to && a.kind == b.kind, "an empty mapping moved a decoration at \(seed)")
            }

            for _ in 0 ..< 10 {
                let tr = state.tr
                let size = doc.content.size
                let a = Int.random(in: 0 ... size, using: &rng), b = Int.random(in: 0 ... size, using: &rng)
                let what: String
                switch Int.random(in: 0 ..< 4, using: &rng) {
                case 0: what = "insertText at \(a)"; _ = try? tr.insertText("xy", a)
                case 1: what = "delete \(Swift.min(a, b))..\(Swift.max(a, b))"; _ = try? tr.delete(Swift.min(a, b), Swift.max(a, b))
                case 2: what = "split at \(a)"; _ = try? tr.split(a)
                default:
                    what = "replace \(Swift.min(a, b))..\(Swift.max(a, b)) with a paragraph"
                    if let p = schema.nodes["paragraph"]?.createAndFill([:], content: Fragment.from(schema.text("z"))) {
                        _ = try? tr.replaceWith(Swift.min(a, b), Swift.max(a, b), p)
                    }
                }
                guard tr.docChanged else { continue }
                let ctx = "\(seed) through \(what)"
                let newDoc = tr.doc
                let mapped = set.map(tr.mapping, doc: newDoc)
                // And without the document, the ends alone still have to be
                // in range and in order — only the one-node promise needs it.
                for d in set.map(tr.mapping).decorations {
                    try expect(d.from >= 0 && d.to <= newDoc.content.size && d.from <= d.to,
                               "mapped without a doc, a decoration left the document or inverted: \(d.from)..\(d.to) — \(ctx)")
                }
                var previousFrom = -1
                for d in mapped.decorations {
                    let where_ = "\(d.kind) \(d.from)..\(d.to) — \(ctx)"
                    try expect(d.from >= 0 && d.to <= newDoc.content.size, "a decoration left the document: \(where_)")
                    try expect(d.from <= d.to, "an inverted decoration: \(where_)")
                    switch d.kind {
                    case .inline:
                        try expect(d.from < d.to, "an empty inline decoration survived: \(where_)")
                    case .widget:
                        try expectEqual(d.from, d.to, "a widget grew a width: \(where_)")
                    case .node:
                        // The documented contract: `[from, to)` spans exactly one node.
                        let node = newDoc.resolve(d.from).nodeAfter
                        try expect(node != nil && d.from + node!.nodeSize == d.to,
                                   "a node decoration no longer spans one node: \(where_)")
                    }
                    try expect(d.from >= previousFrom, "mapping reordered decorations: \(where_)")
                    previousFrom = d.from
                }
                // Nothing before the edit moved at all. Matched by id rather than
                // by index — mapping drops what the edit deleted, so the two
                // lists don't line up — and "before the edit" is read off the
                // step maps, not the positions asked for: the fitter is allowed
                // to widen a replace to a block boundary.
                var editStart = size
                for map in tr.mapping.maps { map.forEach { fromA, _, _, _ in editStart = Swift.min(editStart, fromA) } }
                let after = Dictionary(mapped.decorations.map { ($0.attributes["id"]!, $0) }, uniquingKeysWith: { a, _ in a })
                for before in set.decorations where before.to < editStart {
                    guard let moved = after[before.attributes["id"]!] else {
                        try expect(false, "a decoration before the edit was dropped: \(before.kind) \(before.from)..\(before.to) — \(ctx)")
                        continue
                    }
                    try expect(before.from == moved.from && before.to == moved.to,
                               "a decoration before the edit moved: \(before.from)..\(before.to) → \(moved.from)..\(moved.to) — \(ctx)")
                }
            }
        }
    }
}

/// A widget at every position, an inline decoration over every short range,
/// and a node decoration on every node — in document order.
private func everyDecoration(in doc: Node) -> DecorationSet {
    var out: [Decoration] = []
    let size = doc.content.size
    var next = 0
    func id() -> [String: String] { next += 1; return ["id": "\(next)"] }
    for pos in 0 ... size {
        out.append(Decoration.widget(pos, id()))
        if pos < size, doc.resolve(pos).parent.inlineContent {
            out.append(Decoration.inline(pos, Swift.min(pos + 2, size), id()))
        }
    }
    doc.descendants { node, pos, _, _ in
        out.append(Decoration.node(pos, pos + node.nodeSize, id()))
        return true
    }
    return DecorationSet(out.sorted { $0.from < $1.from || ($0.from == $1.from && $0.to < $1.to) })
}
