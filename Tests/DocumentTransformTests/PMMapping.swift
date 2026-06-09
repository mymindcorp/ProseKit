import Foundation
import DocumentTransform
import TestHarness

// Ported from prosemirror-transform/test/test-mapping.ts — Mapping/StepMap
// position mapping and the deleted-range flags on MapResult.

private enum MkArg {
    case map([Int])
    case mirror(Int, Int)
}
private func mk(_ args: MkArg...) -> Mapping {
    let m = Mapping()
    for arg in args {
        switch arg {
        case let .map(r): m.appendMap(StepMap(r))
        case let .mirror(f, t): m.setMirror(f, t)
        }
    }
    return m
}

// A case is (from, to, bias, lossy).
private typealias MapCase = (Int, Int, Int, Bool)

func registerPMMappingTests() {
    func testMapping(_ name: String, _ mapping: Mapping, _ cases: [MapCase]) {
        test("PM Mapping: \(name)") {
            let inverted = mapping.invert()
            for (from, to, bias, lossy) in cases {
                try expectEqual(mapping.map(from, bias), to, "map(\(from), \(bias))")
                if !lossy { try expectEqual(inverted.map(to, bias), from, "invert.map(\(to), \(bias))") }
            }
        }
    }
    func testDel(_ name: String, _ mapping: Mapping, _ pos: Int, _ side: Int, _ flags: String) {
        test("PM Mapping del: \(name)") {
            let r = mapping.mapResult(pos, side)
            var found = ""
            if r.deleted { found += "d" }
            if r.deletedBefore { found += "b" }
            if r.deletedAfter { found += "a" }
            if r.deletedAcross { found += "x" }
            try expectEqual(found, flags)
        }
    }

    testMapping("can map through a single insertion", mk(.map([2, 0, 4])),
                [(0, 0, 1, false), (2, 6, 1, false), (2, 2, -1, false), (3, 7, 1, false)])
    testMapping("can map through a single deletion", mk(.map([2, 4, 0])),
                [(0, 0, 1, false), (2, 2, -1, false), (3, 2, 1, true), (6, 2, 1, false), (6, 2, -1, true), (7, 3, 1, false)])
    testMapping("can map through a single replace", mk(.map([2, 4, 4])),
                [(0, 0, 1, false), (2, 2, 1, false), (4, 6, 1, true), (4, 2, -1, true), (6, 6, -1, false), (8, 8, 1, false)])
    testMapping("can map through a mirrored delete-insert", mk(.map([2, 4, 0]), .map([2, 0, 4]), .mirror(0, 1)),
                [(0, 0, 1, false), (2, 2, 1, false), (4, 4, 1, false), (6, 6, 1, false), (7, 7, 1, false)])
    testMapping("can map through a mirrored insert-delete", mk(.map([2, 0, 4]), .map([2, 4, 0]), .mirror(0, 1)),
                [(0, 0, 1, false), (2, 2, 1, false), (3, 3, 1, false)])
    testMapping("can map through a delete-insert with an insert in between", mk(.map([2, 4, 0]), .map([1, 0, 1]), .map([3, 0, 4]), .mirror(0, 2)),
                [(0, 0, 1, false), (1, 2, 1, false), (4, 5, 1, false), (6, 7, 1, false), (7, 8, 1, false)])

    // deleted flags — before
    testDel("deletions before (−1)", mk(.map([0, 2, 0])), 2, -1, "db")
    testDel("deletions before (+1)", mk(.map([0, 2, 0])), 2, 1, "b")
    testDel("deletions before with replace", mk(.map([0, 2, 2])), 2, -1, "db")
    testDel("deletions before, two maps", mk(.map([0, 1, 0]), .map([0, 1, 0])), 2, -1, "db")
    testDel("deletions before, not adjacent", mk(.map([0, 1, 0])), 2, -1, "")
    // deleted flags — after
    testDel("deletions after (−1)", mk(.map([2, 2, 0])), 2, -1, "a")
    testDel("deletions after (+1)", mk(.map([2, 2, 0])), 2, 1, "da")
    testDel("deletions after with replace", mk(.map([2, 2, 2])), 2, 1, "da")
    testDel("deletions after, two maps", mk(.map([2, 1, 0]), .map([2, 1, 0])), 2, 1, "da")
    testDel("deletions after, not adjacent", mk(.map([3, 2, 0])), 2, -1, "")
    // deleted flags — across
    testDel("deletions across (−1)", mk(.map([0, 4, 0])), 2, -1, "dbax")
    testDel("deletions across (+1)", mk(.map([0, 4, 0])), 2, 1, "dbax")
    testDel("deletions across, multiple maps", mk(.map([0, 1, 0]), .map([4, 1, 0]), .map([0, 3, 0])), 2, 1, "dbax")
    // deleted flags — around
    testDel("deletions around, both sides safe", mk(.map([4, 1, 0]), .map([0, 1, 0])), 2, -1, "")
    testDel("deletions around, spanning", mk(.map([2, 1, 0]), .map([0, 2, 0])), 2, -1, "dba")
    testDel("deletions around, after only", mk(.map([2, 1, 0]), .map([0, 1, 0])), 2, -1, "a")
    testDel("deletions around, before only", mk(.map([3, 1, 0]), .map([0, 2, 0])), 2, -1, "db")
}
