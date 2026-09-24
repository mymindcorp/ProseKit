import Foundation
import DocumentModel
import DocumentTransform
import EditorChangeset
import TestHarness

// Boundaries the ported suite never lands on: a changed range whose start sits
// exactly at the start of the region the new maps touched, the minimum
// unchanged run Myers' trace-back keeps between two changes, and two changes
// exactly the simplify distance apart.

private func range(_ r: (from: Int, to: Int)?) -> String { r.map { "\($0.from)-\($0.to)" } ?? "nil" }

private func describe<D>(_ changes: [Change<D>]) -> String {
    changes.map { "[\($0.fromA),\($0.toA),\($0.fromB),\($0.toB)]" }.joined(separator: ",")
}

func registerChangesetMutationKillTests() {
    test("changeset kills: changedRange leaves an old change starting at the touched start unshifted") {
        // "abcdefghij": "c" → "C" and "h" → "H", then the new step deletes "Cd".
        let d0 = doc(p("abcdefghij")).node
        let tr1 = Transform(d0)
        try tr1.replaceWith(3, 4, basicSchema.text("C"))
        try tr1.replaceWith(8, 9, basicSchema.text("H"))
        let set1: ChangeSet<String> = ChangeSet.create(d0).addSteps(tr1.doc, tr1.mapping.maps, ["a", "a"])
        try expectEqual(describe(set1.changes), "[3,4,3,4],[8,9,8,9]")
        let tr2 = Transform(tr1.doc)
        try tr2.delete(3, 5)
        let set2 = set1.addSteps(tr2.doc, tr2.mapping.maps, ["b"])
        try expectEqual(describe(set2.changes), "[3,5,3,3],[8,9,6,7]")
        // The old "C" change starts at the deletion's start (position 3), so
        // it stays at 3 — only positions strictly after the start shift back.
        // Upstream: `p <= touched.fromA ? p : p + moved`.
        try expectEqual(range(set1.changedRange(set2, maps: tr2.mapping.maps)), "3-3")
    }

    test("changeset kills: Myers keeps changes apart when the unchanged run between them reaches the minimum") {
        // After trimming the shared paragraph tokens, 23 tokens differ on each
        // side; the minimum unchanged run is max(2, 23 / 10) = 2, so the three
        // shared "q"s keep the two replacements separate.
        let d1 = doc(p("AAAAAAAAAAqqqBBBBBBBBBB")).node
        let d2 = doc(p("CCCCCCCCCCqqqDDDDDDDDDD")).node
        let whole = Change<Int>(0, 25, 0, 25, [Span(25, 0)], [Span(25, 0)])
        let diff = computeDiff(d1.content, d2.content, whole)
        try expectEqual(describe(diff), "[1,11,1,11],[14,24,14,24]")
    }

    test("changeset kills: simplify joins changes exactly the simplify distance apart inside one word") {
        // One 34-letter word; letters 1-2 and 33-34 replaced. The second change
        // starts exactly 30 positions after the first ends, so both are
        // simplified together: one change covering the whole word.
        let word = "XY" + String(repeating: "a", count: 30) + "ZW"
        let d = doc(p(word)).node
        let changes = [
            Change<String>(1, 3, 1, 3, [Span(2, "u")], [Span(2, "u")]),
            Change<String>(33, 35, 33, 35, [Span(2, "u")], [Span(2, "u")]),
        ]
        let simplified = simplifyChanges(changes, d)
        try expectEqual(describe(simplified), "[1,35,1,35]")
        try expectEqual(simplified[0].deleted.map(\.length), [34])
        try expectEqual(simplified[0].inserted.map(\.length), [34])
    }
}
