import Foundation
import DocumentModel
import DocumentTransform
import EditorChangeset
import TestHarness

// `changedRange` with maps between the two sets: the ported cases only pass a
// single map with the old change *after* nothing, so the arithmetic that
// shifts an old change sitting past the touched region, the branch that
// reports an old change the new set no longer has, and the fold over more
// than one map were never run. Plus the diff's give-up path when Myers' search
// exhausts its budget without finishing — distinct from the early bail on a
// region that is too long to even start.

private func range(_ r: (from: Int, to: Int)?) -> String { r.map { "\($0.from)-\($0.to)" } ?? "nil" }

func registerChangedRangeEdgeTests() {
    test("changedRange: an old change past the touched region is shifted by what the maps inserted") {
        // "abcdef": first "e" → "E", then "x" inserted at the front.
        let d0 = doc(p("abcdef")).node
        let tr1 = Transform(d0)
        try tr1.replaceWith(5, 6, basicSchema.text("E"))
        let set1: ChangeSet<String> = ChangeSet.create(d0).addSteps(tr1.doc, tr1.mapping.maps, ["a"])
        let tr2 = Transform(tr1.doc)
        try tr2.insert(1, basicSchema.text("x"))
        let set2 = set1.addSteps(tr2.doc, tr2.mapping.maps, ["b"])
        // Only the insertion is new: the "E" change moved but is the same change.
        try expectEqual(range(set1.changedRange(set2, maps: tr2.mapping.maps)), "1-2")
    }

    test("changedRange: an old change the new set lacks is reported at its own position") {
        // Two sets over the same document from different edits: the first
        // also changed "b", the second only "e".
        let d0 = doc(p("abcdef")).node
        let both = Transform(d0)
        try both.replaceWith(2, 3, basicSchema.text("B"))
        try both.replaceWith(5, 6, basicSchema.text("E"))
        let onlyE = Transform(d0)
        try onlyE.replaceWith(5, 6, basicSchema.text("E"))
        let setBoth: ChangeSet<String> = ChangeSet.create(d0).addSteps(both.doc, both.mapping.maps, ["a", "a"])
        let setE: ChangeSet<String> = ChangeSet.create(d0).addSteps(onlyE.doc, onlyE.mapping.maps, ["a"])
        try expectEqual(range(setBoth.changedRange(setE, maps: nil)), "2-3")
        try expectEqual(range(setE.changedRange(setBoth, maps: nil)), "2-3")
    }

    test("changedRange: several maps between the sets are folded into one touched region") {
        let d0 = doc(p("abcdef")).node
        let set0: ChangeSet<String> = ChangeSet.create(d0)
        let tr = Transform(d0)
        try tr.insert(1, basicSchema.text("x"))
        try tr.insert(7, basicSchema.text("y")) // after the shifted "e"
        let set1 = set0.addSteps(tr.doc, tr.mapping.maps, ["a", "a"])
        try expectEqual(range(set0.changedRange(set1, maps: tr.mapping.maps)), "1-8")
    }

    test("addSteps: a second insertion touching the first extends it instead of re-diffing") {
        let d0 = doc(p("ab")).node
        let tr1 = Transform(d0)
        try tr1.insert(2, basicSchema.text("xyz"))
        let set1: ChangeSet<String> = ChangeSet.create(d0).addSteps(tr1.doc, tr1.mapping.maps, ["a"])
        let tr2 = Transform(tr1.doc)
        try tr2.insert(2, basicSchema.text("q"))
        let set2 = set1.addSteps(tr2.doc, tr2.mapping.maps, ["a"])
        try expectEqual(set2.changes.count, 1)
        try expectEqual(set2.changes[0].fromA, 2)
        try expectEqual(set2.changes[0].toA, 2)
        try expectEqual(set2.changes[0].toB - set2.changes[0].fromB, 4)
    }

    test("changeset diff: when the search exhausts its budget the region is one change") {
        // Short enough to start Myers' search (under the size guard), but with
        // no common character the edit script needs more steps than the
        // search will take, so it ends with the whole trimmed region.
        let d1 = doc(p(String(repeating: "a", count: 1300)))
        let d2 = doc(p(String(repeating: "b", count: 1300)))
        let change = Change(0, d1.node.content.size, 0, d2.node.content.size,
                            [Span(d1.node.content.size, 0)], [Span(d2.node.content.size, 0)])
        let diff = computeDiff(d1.node.content, d2.node.content, change).map { [$0.fromA, $0.toA, $0.fromB, $0.toB] }
        try expectEqual("\(diff)", "\([[1, 1301, 1, 1301]])")
    }
}
