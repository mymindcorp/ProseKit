import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for the structural transforms and the predicates that gate them.
//
// Every command asks before it acts: `canSplit` before `split`, `canJoin`
// before `join`, `liftTarget` before `lift`, `findWrappingForRange` before
// `wrap`. A predicate that says yes to something the operation then throws
// on is a command that reports success and does nothing; one that produces an
// invalid document is worse. So, at every position of every generated
// document, each predicate is held to its word — and the model's own promises
// underneath are checked while we are there: a resolved position knows where
// it is, and a slice cut out of a document puts the document back.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerStructureFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("structure fuzz: canSplit, canJoin and joinPoint keep their word at every position") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 30) {
            for pos in 0 ... doc.content.size {
                let ctx = "\(seed) pos \(pos)"
                for depth in 1 ... 3 {
                    if canSplit(doc, pos, depth) {
                        let tr = Transform(doc)
                        do { _ = try tr.split(pos, depth) } catch {
                            try expect(false, "canSplit said yes but split threw at depth \(depth) — \(ctx): \(error)")
                            continue
                        }
                        try checkValid(tr.doc, "after split(\(pos), \(depth)) — \(ctx)")
                        try expectEqual(tr.doc.content.size, doc.content.size + 2 * depth, "split grew the document by the wrong amount — \(ctx)")
                    }
                }
                if canJoin(doc, pos) {
                    let tr = Transform(doc)
                    do { _ = try tr.join(pos) } catch {
                        try expect(false, "canJoin said yes but join threw — \(ctx): \(error)")
                        continue
                    }
                    try checkValid(tr.doc, "after join(\(pos)) — \(ctx)")
                    try expectEqual(tr.doc.content.size, doc.content.size - 2, "join shrank the document by the wrong amount — \(ctx)")
                }
                for dir in [-1, 1] {
                    if let jp = joinPoint(doc, pos, dir) {
                        try expect(jp >= 0 && jp <= doc.content.size, "joinPoint left the document: \(jp) — \(ctx)")
                        try expect(canJoin(doc, jp), "joinPoint gave \(jp), where canJoin says no — \(ctx)")
                    }
                }
                // Anywhere a paragraph can be inserted, it can be.
                if let para = schema.nodes["paragraph"], let ip = insertPoint(doc, pos, para) {
                    try expect(ip >= 0 && ip <= doc.content.size, "insertPoint left the document: \(ip) — \(ctx)")
                    let r = doc.resolve(ip)
                    try expect(r.parent.canReplaceWith(r.index(), r.index(), para),
                               "insertPoint gave \(ip), where a paragraph can't go — \(ctx)")
                }
            }
        }
    }

    test("structure fuzz: liftTarget and findWrappingForRange keep their word for every block range") {
        let schema = try fuzzSchema()
        var rng = SelRNG(137)
        let wrappers = ["blockquote", "bulletList", "orderedList", "taskList", "details", "figure"].compactMap { schema.nodes[$0] }
        for (seed, doc) in fuzzCorpus(schema, count: 25) {
            let size = doc.content.size
            var pairs: [(Int, Int)] = (0 ... size).map { ($0, $0) }
            for _ in 0 ..< 40 {
                let a = Int.random(in: 0 ... size, using: &rng), b = Int.random(in: 0 ... size, using: &rng)
                pairs.append((Swift.min(a, b), Swift.max(a, b)))
            }
            for (from, to) in pairs {
                guard let range = doc.resolve(from).blockRange(doc.resolve(to)) else { continue }
                let ctx = "\(seed) range \(from)..\(to) (in \(range.parent.type.name))"
                if let target = liftTarget(range) {
                    let tr = Transform(doc)
                    do { _ = try tr.lift(range, target) } catch {
                        try expect(false, "liftTarget said \(target) but lift threw — \(ctx): \(error)")
                        continue
                    }
                    try checkValid(tr.doc, "after lift to \(target) — \(ctx)")
                    // The lifted blocks now sit directly in the target node —
                    // the document need not shrink, since lifting out of the
                    // middle of a wrapper splits the wrapper in two.
                    let landed = tr.doc.resolve(tr.mapping.map(range.start, 1))
                    try expectEqual(landed.depth, target, "lift landed at the wrong depth — \(ctx)")
                }
                for type in wrappers {
                    if let wrapping = findWrappingForRange(range, type) {
                        let tr = Transform(doc)
                        do { _ = try tr.wrap(range, wrapping) } catch {
                            try expect(false, "findWrapping found \(wrapping.map(\.type.name)) but wrap threw — \(ctx): \(error)")
                            continue
                        }
                        try checkValid(tr.doc, "after wrap in \(wrapping.map(\.type.name)) — \(ctx)")
                        try expect(tr.doc.content.size > doc.content.size, "wrap didn't grow the document — \(ctx)")
                    }
                }
            }
        }
    }

    test("structure fuzz: a slice cut from any range puts the document back") {
        // The selection sweep checks this for the ranges a selection can be;
        // this is every kind of range, including ones that open in the middle
        // of a table cell and close inside a caption.
        let schema = try fuzzSchema()
        var rng = SelRNG(139)
        for (seed, doc) in fuzzCorpus(schema, count: 30) {
            let size = doc.content.size
            for _ in 0 ..< 60 {
                let a = Int.random(in: 0 ... size, using: &rng), b = Int.random(in: 0 ... size, using: &rng)
                let from = Swift.min(a, b), to = Swift.max(a, b)
                let slice = doc.slice(from, to)
                try expect(slice.size == to - from, "a slice of \(from)..\(to) reports size \(slice.size) — \(seed)")
                do {
                    let back = try doc.replace(from, to, slice)
                    try expect(back == doc, "putting back the slice of \(from)..\(to) changed the document — \(seed)")
                } catch {
                    try expect(false, "putting back the slice of \(from)..\(to) was rejected — \(seed): \(error)")
                }
            }
        }
    }

    test("structure fuzz: a resolved position knows where it is") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 40) {
            for pos in 0 ... doc.content.size {
                let r = doc.resolve(pos)
                let ctx = "\(seed) pos \(pos)"
                try expectEqual(r.pos, pos, "pos — \(ctx)")
                try expect(r.doc == doc, "doc — \(ctx)")
                try expectEqual(r.parent, r.node(r.depth), "parent is not node(depth) — \(ctx)")
                try expectEqual(r.start() + r.parentOffset, pos, "start + parentOffset — \(ctx)")
                try expect(r.start() <= pos && pos <= r.end(), "outside its own parent — \(ctx)")
                for d in 0 ... r.depth {
                    try expect(r.start(d) <= pos && pos <= r.end(d), "outside node(\(d)) — \(ctx)")
                    if d > 0 {
                        try expectEqual(r.before(d), r.start(d) - 1, "before(\(d)) — \(ctx)")
                        try expectEqual(r.after(d), r.end(d) + 1, "after(\(d)) — \(ctx)")
                        try expectEqual(r.node(d).nodeSize, r.after(d) - r.before(d), "node(\(d)) size — \(ctx)")
                    }
                    try expect(r.index(d) <= r.node(d).childCount, "index(\(d)) past the children — \(ctx)")
                }
                if let after = r.nodeAfter {
                    try expect(r.index() < r.parent.childCount, "nodeAfter with no child index — \(ctx)")
                    try expect(doc.nodeAt(pos) != nil, "nodeAfter but nodeAt is nil — \(ctx)")
                    if r.textOffset == 0 {
                        try expectEqual(r.parent.child(r.index()), after, "nodeAfter is not the child at index — \(ctx)")
                        try expectEqual(r.posAtIndex(r.index()), pos, "posAtIndex doesn't round-trip — \(ctx)")
                    }
                }
                if let before = r.nodeBefore, r.textOffset == 0 {
                    try expectEqual(doc.resolve(pos - before.nodeSize).nodeAfter, before, "nodeBefore doesn't sit before pos — \(ctx)")
                }
                try expect(r.textOffset >= 0 && (r.textOffset == 0 || (r.nodeBefore?.isText ?? false)),
                           "textOffset without text before it — \(ctx)")
            }
        }
    }
}

private func checkValid(_ doc: Node, _ ctx: @autoclosure () -> String) throws {
    var invalid: (any Error)?
    do { try doc.check() } catch { invalid = error }
    try expect(invalid == nil, "invalid document \(ctx()): \(invalid.map { "\($0)" } ?? "")\n\(fuzzOutline(doc))")
}
