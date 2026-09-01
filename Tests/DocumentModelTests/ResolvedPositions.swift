import Foundation
import DocumentModel
import TestHarness

// The `ResolvedPos` helpers that only the transform and state suites had
// reached, pinned directly. Same document as the ported resolve table:
//
//   doc(p("ab"), blockquote(p(em("cd"), "ef")))
//   0 p 1 a 2 b 3 /p 4 bq 5 p 6 c 7 d 8 e 9 f 10 /p 11 /bq 12

func registerResolvedPosTests() {
    let d = B.doc(B.p("ab"), B.blockquote(B.p(B.em("cd"), B.t("ef"))))

    test("sharedDepth: the deepest node both positions are inside") {
        try expectEqual(d.resolve(7).sharedDepth(9), 2)    // both in the inner paragraph
        try expectEqual(d.resolve(7).sharedDepth(5), 1)    // 5 is the blockquote's start,
        try expectEqual(d.resolve(7).sharedDepth(11), 1)   // 11 its end — both inclusive
        try expectEqual(d.resolve(7).sharedDepth(2), 0)
        try expectEqual(d.resolve(2).sharedDepth(3), 1)
        try expectEqual(d.resolve(2).sharedDepth(4), 0)
        try expectEqual(d.resolve(0).sharedDepth(12), 0)
    }

    test("indexAfter: the index after the position, counting a text node it sits inside") {
        try expectEqual(d.resolve(1).indexAfter(), 0)      // before "ab"
        try expectEqual(d.resolve(2).indexAfter(), 1)      // inside it: the node is behind us
        try expectEqual(d.resolve(3).indexAfter(), 1)      // after it
        try expectEqual(d.resolve(8).indexAfter(), 1)      // between em("cd") and "ef"
        // At a shallower depth the child the position descends into is
        // always behind it.
        try expectEqual(d.resolve(2).indexAfter(0), 1)
        try expectEqual(d.resolve(4).indexAfter(0), 1)
        try expectEqual(d.resolve(0).indexAfter(0), 0)
    }

    test("sameParent: whether two positions point into the same node") {
        try expect(d.resolve(1).sameParent(d.resolve(3)))
        try expect(d.resolve(0).sameParent(d.resolve(12)))
        try expect(!d.resolve(2).sameParent(d.resolve(7)))
        try expect(!d.resolve(3).sameParent(d.resolve(4)))
    }

    test("blockRange: the blocks around two positions") {
        let inner = d.resolve(7).blockRange(d.resolve(9))!
        try expectEqual(inner.depth, 1)
        try expectEqual(inner.start, 5)
        try expectEqual(inner.end, 11)
        try expectEqual(inner.startIndex, 0)
        try expectEqual(inner.endIndex, 1)
        try expect(inner.parent == d.child(1))

        let outer = d.resolve(2).blockRange(d.resolve(9))!
        try expectEqual(outer.depth, 0)
        try expectEqual(outer.start, 0)
        try expectEqual(outer.end, 12)
        try expectEqual(outer.startIndex, 0)
        try expectEqual(outer.endIndex, 2)

        // A cursor's range is the block it sits in.
        let cursor = d.resolve(7).blockRange()!
        try expectEqual(cursor.depth, 1)
        try expectEqual(cursor.start, 5)
        try expectEqual(cursor.end, 11)
    }

    test("blockRange: the predicate holds whichever order the positions come in") {
        let isDoc: (Node) -> Bool = { $0.type.name == "doc" }
        let forward = d.resolve(7).blockRange(d.resolve(9), pred: isDoc)!
        try expectEqual(forward.depth, 0)
        // Upstream drops the predicate when it swaps the positions; this
        // port keeps it, so the answer is the same either way round.
        let backward = d.resolve(9).blockRange(d.resolve(7), pred: isDoc)!
        try expectEqual(backward.depth, 0)
        // At depth 0 the range is the blockquote both positions sit in.
        try expectEqual(backward.start, 4)
        try expectEqual(backward.end, 12)
        try expectEqual(backward.startIndex, 1)
        try expectEqual(backward.endIndex, 2)
        try expectEqual(forward.start, 4)
        try expectNil(d.resolve(7).blockRange(d.resolve(9), pred: { $0.type.name == "heading" }))
    }

    test("marksAcross: the marks the content after a position carries to another") {
        let em = B.doc(B.p(B.em("ab"), B.t("cd")))
        try expectEqual(em.resolve(1).marksAcross(em.resolve(3)), [B.schema.mark("italic")])
        try expectEqual(em.resolve(3).marksAcross(em.resolve(5)), [])
        // Nothing inline after the position: no answer.
        try expectNil(em.resolve(0).marksAcross(em.resolve(0)))
        try expectNil(em.resolve(5).marksAcross(em.resolve(5)))
    }

    test("marksAcross: a non-inclusive mark drops off unless the far side carries it too") {
        // `link` is non-inclusive in the test schema.
        let linked = B.doc(B.p(B.link("ab", "u"), B.t("cd")))
        try expectEqual(linked.resolve(1).marksAcross(linked.resolve(3)), [])
        try expectEqual(linked.resolve(1).marksAcross(linked.resolve(2)), [B.schema.mark("link", ["href": "u"])])
    }

    test("findDiffStart/End count grapheme clusters, like every other position") {
        // A combining mark, a flag, and a ZWJ family: each one cluster, so the
        // difference after it starts at 1 (the paragraph's open) + 1.
        for prefix in ["e\u{0301}", "\u{1F1EF}\u{1F1F5}", "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}"] {
            let a = B.doc(B.p(prefix + "x")), b = B.doc(B.p(prefix + "y"))
            try expectEqual(a.content.findDiffStart(b.content), 2, "start after \(prefix.debugDescription)")
            try expectEqual(a.content.findDiffEnd(b.content)?.a, 3, "end after \(prefix.debugDescription)")
            try expectEqual(a.content.findDiffEnd(b.content)?.b, 3)
        }
        // A shared suffix of clusters is skipped from the end.
        let a = B.doc(B.p("x" + "e\u{0301}")), b = B.doc(B.p("y" + "e\u{0301}"))
        try expectEqual(a.content.findDiffStart(b.content), 1)
        try expectEqual(a.content.findDiffEnd(b.content)?.a, 2)
        try expectEqual(a.content.findDiffEnd(b.content)?.b, 2)
    }
}
