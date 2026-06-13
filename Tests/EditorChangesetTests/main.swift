import Foundation
import DocumentModel
import DocumentTransform
import EditorChangeset
import TestHarness

// Ported from prosemirror-changeset/test/{test-changes, test-merge, test-diff,
// test-simplify, test-changed-range}.ts — the complete upstream suite.

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) { collector.test(name, body) }

private func t(_ s: String) -> Node { basicSchema.text(s) }

// MARK: - test-changes.ts

/// Apply the builds in order, adding each transform's maps to the set with
/// per-build data (`sep`), and compare against the expected description.
/// Plain expectations are [fromA, toA, fromB, toB]; `detailed` adds the
/// deleted/inserted span lists ([length, data] pairs).
private func find(_ d: TaggedNode, _ builds: [(Transform) -> Void], _ expected: String,
                  sep: [Int]? = nil, seq: Bool = false, detailed: Bool = false) throws {
    var set = ChangeSet<Int>.create(d.node)
    var curDoc = d.node
    for (i, build) in builds.enumerated() {
        let tr = Transform(curDoc)
        build(tr)
        let data = sep?[i] ?? (seq ? i : 0)
        set = set.addSteps(tr.doc, tr.mapping.maps, data)
        curDoc = tr.doc
    }
    let got = set.changes.map { ch -> String in
        var s = "[\(ch.fromA),\(ch.toA),\(ch.fromB),\(ch.toB)"
        if detailed {
            let del = ch.deleted.map { "[\($0.length),\($0.data)]" }.joined(separator: ",")
            let ins = ch.inserted.map { "[\($0.length),\($0.data)]" }.joined(separator: ",")
            s += ",[\(del)],[\(ins)]"
        }
        return s + "]"
    }.joined(separator: ",")
    try expectEqual("[\(got)]", expected)
}

private func find(_ d: TaggedNode, _ build: @escaping (Transform) -> Void, _ expected: String,
                  detailed: Bool = false) throws {
    try find(d, [build], expected, detailed: detailed)
}

func registerChangesetFuzzTests() {
    test("changeset fuzz: invariants hold under random edit sequences") {
        var rngState: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd(_ n: Int) -> Int {
            rngState ^= rngState << 13; rngState ^= rngState >> 7; rngState ^= rngState << 17
            return Int(rngState % UInt64(max(1, n)))
        }
        let letters = Array("abcdefgh")
        func rndText() -> String { String((0...rnd(3)).map { _ in letters[rnd(letters.count)] }) }

        for round in 0..<80 {
            var curDoc = doc(p("abcdefghij")).node
            var set = ChangeSet<Int>.create(curDoc)
            for batch in 0..<10 {
                let tr = Transform(curDoc)
                for _ in 0...rnd(3) {
                    let size = tr.doc.content.size
                    guard size >= 3 else { break }
                    switch rnd(3) {
                    case 0:
                        _ = try? tr.insert(1 + rnd(size - 1), basicSchema.text(rndText()))
                    case 1:
                        let a = 1 + rnd(size - 2)
                        let b = min(size - 1, a + 1 + rnd(3))
                        if b > a { _ = try? tr.delete(a, b) }
                    default:
                        let a = 1 + rnd(size - 2)
                        let b = min(size - 1, a + 1 + rnd(2))
                        if b > a { _ = try? tr.replaceWith(a, b, basicSchema.text(rndText())) }
                    }
                }
                guard !tr.steps.isEmpty else { continue }
                set = set.addSteps(tr.doc, tr.mapping.maps, batch)
                curDoc = tr.doc

                // Structural invariants (seed-reproducible on failure).
                let ctx = "round \(round) batch \(batch)"
                var lastToA = 0, lastToB = 0
                for ch in set.changes {
                    try expect(ch.fromA <= ch.toA && ch.fromB <= ch.toB, "inverted range \(ctx)")
                    try expect(ch.fromA >= lastToA && ch.fromB >= lastToB, "out of order \(ctx)")
                    lastToA = ch.toA; lastToB = ch.toB
                    try expectEqual(ch.deleted.reduce(0) { $0 + $1.length }, ch.toA - ch.fromA, "deleted spans \(ctx)")
                    try expectEqual(ch.inserted.reduce(0) { $0 + $1.length }, ch.toB - ch.fromB, "inserted spans \(ctx)")
                    try expect(ch.toA <= set.startDoc.content.size, "A out of doc \(ctx)")
                    try expect(ch.toB <= curDoc.content.size, "B out of doc \(ctx)")
                }
                // Simplify must keep ranges ordered with consistent span sums.
                var lastB = 0
                for ch in simplifyChanges(set.changes, curDoc) {
                    try expect(ch.fromB >= lastB, "simplify order \(ctx)")
                    lastB = ch.toB
                    try expectEqual(ch.deleted.reduce(0) { $0 + $1.length }, ch.toA - ch.fromA, "simplify deleted \(ctx)")
                    try expectEqual(ch.inserted.reduce(0) { $0 + $1.length }, ch.toB - ch.fromB, "simplify inserted \(ctx)")
                }
            }
        }
    }
}

func registerPMChangesTests() {
    test("PM changeset: finds a single insertion") {
        try find(doc(p("hello")), { tr in _ = try? tr.insert(3, t("XY")) }, "[[3,3,3,5]]")
    }
    test("PM changeset: finds a single deletion") {
        try find(doc(p("hello")), { tr in _ = try? tr.delete(3, 5) }, "[[3,5,3,3]]")
    }
    test("PM changeset: identifies a replacement") {
        try find(doc(p("hello")), { tr in _ = try? tr.replaceWith(3, 5, t("juj")) }, "[[3,5,3,6]]")
    }
    test("PM changeset: merges adjacent canceling edits") {
        try find(doc(p("hello")), { tr in _ = try? tr.delete(3, 5); _ = try? tr.insert(3, t("ll")) }, "[]")
    }
    test("PM changeset: doesn't crash when cancelling edits are followed by others") {
        try find(doc(p("hello")), { tr in
            _ = try? tr.delete(2, 3)
            _ = try? tr.insert(2, t("e"))
            _ = try? tr.delete(5, 6)
        }, "[[5,6,5,5]]")
    }
    test("PM changeset: stops handling an inserted span after collapsing it") {
        try find(doc(p("abcba")), { tr in
            _ = try? tr.insert(2, t("b"))
            _ = try? tr.insert(6, t("b"))
            _ = try? tr.delete(3, 6)
        }, "[[3,4,3,3]]")
    }
    test("PM changeset: partially merges insert at start") {
        try find(doc(p("helLo")), { tr in _ = try? tr.delete(3, 5); _ = try? tr.insert(3, t("l")) }, "[[4,5,4,4]]")
    }
    test("PM changeset: partially merges insert at end") {
        try find(doc(p("helLo")), { tr in _ = try? tr.delete(3, 5); _ = try? tr.insert(3, t("L")) }, "[[3,4,3,3]]")
    }
    test("PM changeset: partially merges delete at start") {
        try find(doc(p("abc")), { tr in _ = try? tr.insert(3, t("xyz")); _ = try? tr.delete(3, 4) }, "[[3,3,3,5]]")
    }
    test("PM changeset: partially merges delete at end") {
        try find(doc(p("abc")), { tr in _ = try? tr.insert(3, t("xyz")); _ = try? tr.delete(5, 6) }, "[[3,3,3,5]]")
    }
    test("PM changeset: finds multiple insertions") {
        try find(doc(p("abc")), { tr in _ = try? tr.insert(1, t("x")); _ = try? tr.insert(5, t("y")) },
                 "[[1,1,1,2],[4,4,5,6]]")
    }
    test("PM changeset: finds multiple deletions") {
        try find(doc(p("xyz")), { tr in _ = try? tr.delete(1, 2); _ = try? tr.delete(2, 3) },
                 "[[1,2,1,1],[3,4,2,2]]")
    }
    test("PM changeset: identifies a deletion between insertions") {
        try find(doc(p("zyz")), { tr in
            _ = try? tr.insert(2, t("A"))
            _ = try? tr.insert(4, t("B"))
            _ = try? tr.delete(3, 4)
        }, "[[2,3,2,4]]")
    }
    test("PM changeset: can add a deletion in a new addStep call") {
        try find(doc(p("hello")), [
            { tr in _ = try? tr.delete(1, 2) },
            { tr in _ = try? tr.delete(2, 3) },
        ], "[[1,2,1,1],[3,4,2,2]]")
    }
    test("PM changeset: merges delete/insert from different addStep calls") {
        try find(doc(p("hello")), [
            { tr in _ = try? tr.delete(3, 5) },
            { tr in _ = try? tr.insert(3, t("ll")) },
        ], "[]")
    }
    test("PM changeset: revert a deletion by inserting the character again") {
        try find(doc(p("bar")), [
            { tr in _ = try? tr.delete(2, 3) },
            { tr in _ = try? tr.insert(2, t("x")) },
            { tr in _ = try? tr.insert(2, t("a")) },
        ], "[[3,3,3,4]]")
    }
    test("PM changeset: insert character before changed character") {
        try find(doc(p("bar")), [
            { tr in _ = try? tr.delete(2, 3) },
            { tr in _ = try? tr.insert(2, t("x")) },
            { tr in _ = try? tr.insert(2, t("x")) },
        ], "[[2,3,2,4]]")
    }
    test("PM changeset: partially merges delete/insert from different addStep calls") {
        try find(doc(p("heljo")), [
            { tr in _ = try? tr.delete(3, 5) },
            { tr in _ = try? tr.insert(3, t("ll")) },
        ], "[[4,5,4,5]]")
    }
    test("PM changeset: merges insert/delete from different addStep calls") {
        try find(doc(p("ok")), [
            { tr in _ = try? tr.insert(2, t("--")) },
            { tr in _ = try? tr.delete(2, 4) },
        ], "[]")
    }
    test("PM changeset: partially merges insert/delete from different addStep calls") {
        try find(doc(p("ok")), [
            { tr in _ = try? tr.insert(2, t("--")) },
            { tr in _ = try? tr.delete(2, 3) },
        ], "[[2,2,2,3]]")
    }
    test("PM changeset: maps deletions forward") {
        try find(doc(p("foobar")), [
            { tr in _ = try? tr.delete(5, 6) },
            { tr in _ = try? tr.insert(1, t("OKAY")) },
        ], "[[1,1,1,5],[5,6,9,9]]")
    }
    test("PM changeset: can incrementally undo then redo") {
        try find(doc(p("bar")), [
            { tr in _ = try? tr.delete(2, 3) },
            { tr in _ = try? tr.insert(2, t("a")) },
            { tr in _ = try? tr.delete(2, 3) },
        ], "[[2,3,2,2]]")
    }
    test("PM changeset: can map through complicated changesets") {
        try find(doc(p("12345678901234")), [
            { tr in
                _ = try? tr.delete(9, 12)
                _ = try? tr.insert(6, t("xyz"))
                _ = try? tr.replaceWith(2, 3, t("uv"))
            },
            { tr in
                _ = try? tr.delete(14, 15)
                _ = try? tr.insert(13, t("90"))
                _ = try? tr.delete(8, 9)
            },
        ], "[[2,3,2,4],[6,6,7,9],[11,12,14,14],[13,14,15,15]]")
    }
    test("PM changeset: computes a proper diff of the changes") {
        try find(doc(p("abcd"), p("efgh")), { tr in
            _ = try? tr.delete(2, 10)
            _ = try? tr.insert(2, t("cdef"))
        }, "[[2,3,2,2],[5,7,4,4],[9,10,6,6]]")
    }
    test("PM changeset: handles re-adding content step by step") {
        try find(doc(p("one two three")), [
            { tr in _ = try? tr.delete(1, 14) },
            { tr in _ = try? tr.insert(1, t("two")) },
            { tr in _ = try? tr.insert(4, t(" ")) },
            { tr in _ = try? tr.insert(5, t("three")) },
        ], "[[1,5,1,1]]")
    }
    test("PM changeset: doesn't get confused by split deletions") {
        try find(doc(blockquote(h1("one"), p("two four"))), [
            { tr in _ = try? tr.delete(7, 11) },
            { tr in _ = try? tr.replaceWith(0, 13, blockquote(h1("one"), p("four")).node) },
        ], "[[7,11,7,7,[[4,0]],[]]]", seq: true, detailed: true)
    }
    test("PM changeset: doesn't get confused by multiply split deletions") {
        try find(doc(blockquote(h1("one"), p("two three"))), [
            { tr in _ = try? tr.delete(14, 16) },
            { tr in _ = try? tr.delete(7, 11) },
            { tr in _ = try? tr.delete(3, 5) },
            { tr in _ = try? tr.replaceWith(0, 10, blockquote(h1("o"), p("thr")).node) },
        ], "[[3,5,3,3,[[2,2]],[]],[8,12,6,6,[[3,1],[1,3]],[]],[14,16,8,8,[[2,0]],[]]]",
           seq: true, detailed: true)
    }
    test("PM changeset: won't lose the order of overlapping changes") {
        try find(doc(p("12345")), [
            { tr in _ = try? tr.delete(4, 5) },
            { tr in _ = try? tr.replaceWith(2, 2, t("a")) },
            { tr in _ = try? tr.delete(1, 6) },
            { tr in _ = try? tr.replaceWith(1, 1, t("1a235")) },
        ], "[[2,2,2,3,[],[[1,1]]],[4,5,5,5,[[1,0]],[]]]", sep: [0, 0, 1, 1], detailed: true)
    }
    test("PM changeset: properly maps deleted positions") {
        try find(doc(p("jTKqvPrzApX")), [
            { tr in _ = try? tr.delete(8, 11) },
            { tr in _ = try? tr.replaceWith(1, 1, t("MPu")) },
            { tr in _ = try? tr.delete(2, 12) },
            { tr in _ = try? tr.replaceWith(2, 2, t("PujTKqvPrX")) },
        ], "[[1,1,1,4,[],[[3,2]]],[8,11,11,11,[[3,1]],[]]]", sep: [1, 2, 2, 2], detailed: true)
    }
    test("PM changeset: fuzz issue 1") {
        try find(doc(p("hzwiKqBPzn")), [
            { tr in _ = try? tr.delete(3, 7) },
            { tr in _ = try? tr.replaceWith(5, 5, t("LH")) },
            { tr in _ = try? tr.replaceWith(6, 6, t("uE")) },
            { tr in _ = try? tr.delete(1, 6) },
            { tr in _ = try? tr.delete(3, 6) },
        ], "[[1,11,1,3,[[2,1],[4,0],[2,1],[2,0]],[[2,0]]]]", sep: [0, 1, 0, 1, 0], detailed: true)
    }
    test("PM changeset: fuzz issue 2") {
        try find(doc(p("eAMISWgauf")), [
            { tr in _ = try? tr.delete(5, 10) },
            { tr in _ = try? tr.replaceWith(5, 5, t("KkM")) },
            { tr in _ = try? tr.replaceWith(3, 3, t("UDO")) },
            { tr in _ = try? tr.delete(1, 12) },
            { tr in _ = try? tr.replaceWith(1, 1, t("eAUDOMIKkMf")) },
            { tr in _ = try? tr.delete(5, 8) },
            { tr in _ = try? tr.replaceWith(3, 3, t("qX")) },
        ], "[[3,10,3,10,[[2,0],[5,2]],[[7,0]]]]", sep: [2, 0, 0, 0, 0, 0, 0], detailed: true)
    }
    test("PM changeset: fuzz issue 3") {
        try find(doc(p("hfxjahnOuH")), [
            { tr in _ = try? tr.delete(1, 5) },
            { tr in _ = try? tr.replaceWith(3, 3, t("X")) },
            { tr in _ = try? tr.delete(1, 8) },
            { tr in _ = try? tr.replaceWith(1, 1, t("ahXnOuH")) },
            { tr in _ = try? tr.delete(2, 4) },
            { tr in _ = try? tr.replaceWith(2, 2, t("tn")) },
            { tr in _ = try? tr.delete(5, 7) },
            { tr in _ = try? tr.delete(1, 6) },
            { tr in _ = try? tr.replaceWith(1, 1, t("atnnH")) },
            { tr in _ = try? tr.delete(2, 6) },
        ], "[[1,11,1,2,[[4,1],[1,0],[1,1],[1,0],[2,1],[1,0]],[[1,0]]]]",
           sep: [1, 0, 1, 1, 1, 1, 1, 0, 0, 0], detailed: true)
    }
    test("PM changeset: correctly handles steps with multiple map entries") {
        try find(doc(p()), [
            { tr in _ = try? tr.replaceWith(1, 1, t("ab")) },
            { tr in
                if let range = tr.doc.resolve(1).blockRange() {
                    _ = try? tr.wrap(range, [NodeTypeWithAttrs(basicSchema.nodes["blockquote"]!)])
                }
            },
        ], "[[0,0,0,1],[1,1,2,4],[2,2,5,6]]")
    }
}

// MARK: - test-merge.ts

private func mergeRange(_ array: [Int], _ author: Int = 0) -> Change<Int> {
    let fromA = array[0], toA = array[1]
    let fromB = array.count > 2 ? array[2] : array[0]
    let toB = array.count > 2 ? array[3] : array[1]
    return Change(fromA, toA, fromB, toB,
                  toA - fromA == 0 ? [] : [Span(toA - fromA, author)],
                  toB - fromB == 0 ? [] : [Span(toB - fromB, author)])
}

private func mergeTest(_ a: [[Int]], _ b: [[Int]], _ expected: [[Int]]) throws {
    let result = Change.merge(a.map { mergeRange($0) }, b.map { mergeRange($0) }, { x, _ in x })
        .map { [$0.fromA, $0.toA, $0.fromB, $0.toB] }
    try expectEqual("\(result)", "\(expected)")
}

func registerPMMergeTests() {
    test("PM changeset merge: can merge simple insertions") {
        try mergeTest([[1, 1, 1, 2]], [[1, 1, 1, 2]], [[1, 1, 1, 3]])
    }
    test("PM changeset merge: can merge simple deletions") {
        try mergeTest([[1, 2, 1, 1]], [[1, 2, 1, 1]], [[1, 3, 1, 1]])
    }
    test("PM changeset merge: can merge insertion before deletion") {
        try mergeTest([[2, 3, 2, 2]], [[1, 1, 1, 2]], [[1, 1, 1, 2], [2, 3, 3, 3]])
    }
    test("PM changeset merge: can merge insertion after deletion") {
        try mergeTest([[2, 3, 2, 2]], [[2, 2, 2, 3]], [[2, 3, 2, 3]])
    }
    test("PM changeset merge: can merge deletion before insertion") {
        try mergeTest([[2, 2, 2, 3]], [[1, 2, 1, 1]], [[1, 2, 1, 2]])
    }
    test("PM changeset merge: can merge deletion after insertion") {
        try mergeTest([[2, 2, 2, 3]], [[3, 4, 3, 3]], [[2, 3, 2, 3]])
    }
    test("PM changeset merge: can merge deletion of insertion") {
        try mergeTest([[2, 2, 2, 3]], [[2, 3, 2, 2]], [])
    }
    test("PM changeset merge: can merge insertion after replace") {
        try mergeTest([[2, 3, 2, 3]], [[3, 3, 3, 4]], [[2, 3, 2, 4]])
    }
    test("PM changeset merge: can merge insertion before replace") {
        try mergeTest([[2, 3, 2, 3]], [[2, 2, 2, 3]], [[2, 3, 2, 4]])
    }
    test("PM changeset merge: can merge replace after insert") {
        try mergeTest([[2, 2, 2, 3]], [[2, 3, 2, 3]], [[2, 2, 2, 3]])
    }
}

// MARK: - test-diff.ts

private func diffTest(_ doc1: TaggedNode, _ doc2: TaggedNode, _ ranges: [[Int]]) throws {
    let change = Change(0, doc1.node.content.size, 0, doc2.node.content.size,
                        [Span(doc1.node.content.size, 0)], [Span(doc2.node.content.size, 0)])
    let diff = computeDiff(doc1.node.content, doc2.node.content, change)
        .map { [$0.fromA, $0.toA, $0.fromB, $0.toB] }
    try expectEqual("\(diff)", "\(ranges)")
}

func registerPMDiffTests() {
    test("PM changeset diff: returns an empty diff for identical documents") {
        try diffTest(doc(p("foo"), p("bar")), doc(p("foo"), p("bar")), [])
    }
    test("PM changeset diff: finds single-letter changes") {
        try diffTest(doc(p("foo"), p("bar")), doc(p("foa"), p("bar")), [[3, 4, 3, 4]])
    }
    test("PM changeset diff: finds simple structure changes") {
        try diffTest(doc(p("foo"), p("bar")), doc(p("foobar")), [[4, 6, 4, 4]])
    }
    test("PM changeset diff: finds multiple changes") {
        try diffTest(doc(p("foo"), p("---bar")), doc(p("fgo"), p("---bur")), [[2, 4, 2, 4], [10, 11, 10, 11]])
    }
    test("PM changeset diff: ignores single-letter unchanged parts") {
        try diffTest(doc(p("abcdef")), doc(p("axydzf")), [[2, 6, 2, 6]])
    }
    test("PM changeset diff: ignores matching substrings in longer diffs") {
        try diffTest(doc(p("One two three")),
                     doc(p("One"), p("And another long paragraph that has wo and ee in it")),
                     [[4, 14, 4, 57]])
    }
    test("PM changeset diff: finds deletions") {
        try diffTest(doc(p("abc"), p("def")), doc(p("ac"), p("d")), [[2, 3, 2, 2], [7, 9, 6, 6]])
    }
    test("PM changeset diff: ignores marks") {
        try diffTest(doc(p("abc")), doc(p(em("a"), strong("bc"))), [])
    }
    test("PM changeset diff: ignores marks in diffing") {
        try diffTest(doc(p("abcdefghi")), doc(p(em("x"), strong("bc"), "defgh", em("y"))),
                     [[1, 2, 1, 2], [9, 10, 9, 10]])
    }
    test("PM changeset diff: ignores attributes") {
        try diffTest(doc(h1("x")), doc(h2("x")), [])
    }
    test("PM changeset diff: finds huge deletions") {
        let xs = String(repeating: "x", count: 200), bs = String(repeating: "b", count: 20)
        try diffTest(doc(p("a" + bs + "c")), doc(p("a" + xs + bs + xs + "c")),
                     [[2, 2, 2, 202], [22, 22, 222, 422]])
    }
    test("PM changeset diff: finds huge insertions") {
        let xs = String(repeating: "x", count: 200), bs = String(repeating: "b", count: 20)
        try diffTest(doc(p("a" + xs + bs + xs + "c")), doc(p("a" + bs + "c")),
                     [[2, 202, 2, 2], [222, 422, 22, 22]])
    }
    test("PM changeset diff: can handle ambiguous diffs") {
        try diffTest(doc(p("abcbcd")), doc(p("abcd")), [[4, 6, 4, 4]])
    }
    test("PM changeset diff: sees the difference between different closing tokens") {
        try diffTest(doc(p("a")), doc(h1("oo")), [[0, 3, 0, 4]])
    }
}

// MARK: - test-simplify.ts

private func simplifyRange(_ array: [Int], _ author: Int = 0) -> Change<Int> {
    let fromA = array[0], toA = array[1]
    let fromB = array.count > 2 ? array[2] : array[0]
    let toB = array.count > 2 ? array[3] : array[1]
    return Change(fromA, toA, fromB, toB, [Span(toA - fromA, author)], [Span(toB - fromB, author)])
}

private func simplifyTest(_ changes: [[Int]], _ d: TaggedNode, _ result: [[Int]]) throws {
    let simplified = simplifyChanges(changes.map { simplifyRange($0) }, d.node)
    let got = simplified.enumerated().map { i, r -> [Int] in
        if i < result.count, result[i].count > 2 { return [r.fromA, r.toA, r.fromB, r.toB] }
        return [r.fromB, r.toB]
    }
    try expectEqual("\(got)", "\(result)")
}

func registerPMSimplifyTests() {
    test("PM changeset simplify: doesn't change insertion-only changes") {
        try simplifyTest([[1, 1, 1, 2], [2, 2, 3, 4]], doc(p("hello")), [[1, 1, 1, 2], [2, 2, 3, 4]])
    }
    test("PM changeset simplify: doesn't change deletion-only changes") {
        try simplifyTest([[1, 2, 1, 1], [3, 4, 2, 2]], doc(p("hello")), [[1, 2, 1, 1], [3, 4, 2, 2]])
    }
    test("PM changeset simplify: doesn't change single-letter-replacements") {
        try simplifyTest([[1, 2, 1, 2]], doc(p("hello")), [[1, 2, 1, 2]])
    }
    test("PM changeset simplify: does expand multiple-letter replacements") {
        try simplifyTest([[2, 4, 2, 4]], doc(p("hello")), [[1, 6, 1, 6]])
    }
    test("PM changeset simplify: does combine changes within the same word") {
        try simplifyTest([[1, 3, 1, 1], [5, 5, 3, 4]], doc(p("hello")), [[1, 7, 1, 6]])
    }
    test("PM changeset simplify: expands changes to cover full words") {
        try simplifyTest([[7, 10]], doc(p("one two three four")), [[5, 14]])
    }
    test("PM changeset simplify: doesn't expand across non-word text") {
        try simplifyTest([[7, 10]], doc(p("one two ----- four")), [[5, 10]])
    }
    test("PM changeset simplify: treats leaf nodes as non-words") {
        try simplifyTest([[2, 3], [6, 7]], doc(p("one", img(), "two")), [[2, 3], [6, 7]])
    }
    test("PM changeset simplify: treats node boundaries as non-words") {
        try simplifyTest([[2, 3], [7, 8]], doc(p("one"), p("two")), [[2, 3], [7, 8]])
    }
    test("PM changeset simplify: can merge stretches of changes") {
        try simplifyTest([[2, 3], [4, 6], [8, 10], [15, 16]], doc(p("foo bar baz bug ugh")), [[1, 12], [15, 16]])
    }
    test("PM changeset simplify: handles realistic word updates") {
        try simplifyTest([[8, 8, 8, 11], [10, 15, 13, 17]], doc(p("chonic condition")), [[8, 15, 8, 17]])
    }
    test("PM changeset simplify: works when after significant content") {
        try simplifyTest([[63, 80, 63, 83]],
                         doc(p("one long paragraph -----"), p("two long paragraphs ------"), p("a vote against the government")),
                         [[62, 81, 62, 84]])
    }
    test("PM changeset simplify: joins changes that grow together when simplifying") {
        try simplifyTest([[1, 5, 1, 5], [7, 13, 7, 9], [20, 21, 16, 16]], doc(p("and his co-star")),
                         [[1, 13, 1, 9], [20, 21, 16, 16]])
    }
    test("PM changeset simplify: properly fills in metadata") {
        let simple = simplifyChanges([simplifyRange([2, 3], 0), simplifyRange([4, 6], 1), simplifyRange([8, 9, 8, 8], 2)],
                                     doc(p("1234567890")).node)
        try expectEqual(simple.count, 1)
        try expectEqual("\(simple[0].deleted.map { [$0.length, $0.data] })", "\([[3, 0], [4, 1], [4, 2]])")
        try expectEqual("\(simple[0].inserted.map { [$0.length, $0.data] })", "\([[3, 0], [4, 1], [3, 2]])")
    }
}

// MARK: - test-changed-range.ts

private func mkRange(_ d: TaggedNode, _ change: (Transform) -> Void)
    -> (doc0: Node, tr: Transform, data: [String], set0: ChangeSet<String>, set: ChangeSet<String>) {
    let tr = Transform(d.node)
    change(tr)
    let data = [String](repeating: "a", count: tr.steps.count)
    let set0: ChangeSet<String> = ChangeSet.create(d.node)
    return (d.node, tr, data, set0, set0.addSteps(tr.doc, tr.mapping.maps, data))
}

private func sameRange(_ a: (from: Int, to: Int)?, _ b: (from: Int, to: Int)?) throws {
    try expectEqual("\(String(describing: a))", "\(String(describing: b))")
}

func registerPMChangedRangeTests() {
    test("PM changeset changedRange: returns null for identical sets") {
        let (doc0, tr, data, _, set) = mkRange(doc(p("foo"))) { tr in
            _ = try? tr.replaceWith(2, 3, basicSchema.text("aaaa"))
            _ = try? tr.replaceWith(1, 1, basicSchema.text("xx"))
            _ = try? tr.delete(5, 7)
        }
        try expect(set.changedRange(set, maps: nil) == nil)
        let other: ChangeSet<String> = ChangeSet.create(doc0)
        try expect(set.changedRange(other.addSteps(tr.doc, tr.mapping.maps, data), maps: nil) == nil)
    }
    test("PM changeset changedRange: returns only the changed range in simple cases") {
        let (_, tr, _, set0, set) = mkRange(doc(p("abcd"))) { tr in
            _ = try? tr.replaceWith(2, 4, basicSchema.text("u"))
        }
        try sameRange(set0.changedRange(set, maps: tr.mapping.maps), (2, 3))
    }
    test("PM changeset changedRange: expands to cover updated spans") {
        let (doc0, tr, _, set0, set) = mkRange(doc(p("abcd"))) { tr in
            _ = try? tr.replaceWith(2, 2, basicSchema.text("c"))
            _ = try? tr.delete(3, 5)
        }
        let mid: ChangeSet<String> = ChangeSet.create(doc0)
        let set1 = mid.addSteps(tr.docs[1], [tr.mapping.maps[0]], ["a"])
        try sameRange(set0.changedRange(set1, maps: [tr.mapping.maps[0]]), (2, 3))
        try sameRange(set1.changedRange(set, maps: [tr.mapping.maps[1]]), (2, 3))
    }
    test("PM changeset changedRange: detects changes in deletions") {
        let (_, _, _, _, set) = mkRange(doc(p("abc"))) { tr in _ = try? tr.delete(2, 3) }
        try sameRange(set.changedRange(set.map { _ in "b" }, maps: nil), (2, 2))
    }
}

registerPMChangesTests()
registerChangesetFuzzTests()
registerPMMergeTests()
registerPMDiffTests()
registerPMSimplifyTests()
registerPMChangedRangeTests()

TestSuite.main("EditorChangesetTests", collector.all)
