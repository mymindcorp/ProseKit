import Foundation
import DocumentModel
import DocumentTransform
import TestHarness

// Ported from prosemirror-transform/test/test-invert.ts (added with 1.12.3),
// seeded rather than drawn from Math.random so a failure replays.

private struct InvertRNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    /// A number in 0..<n, or 0 when n is not positive.
    mutating func r(_ n: Int) -> Int {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return n > 0 ? Int(s % UInt64(n)) : 0
    }
}

private func randomText(_ rng: inout InvertRNG, _ len: Int) -> String {
    String((0 ..< len).map { _ in Character(UnicodeScalar(97 + UInt8(rng.r(26)))) })
}

/// One random edit: add or remove a mark, insert text, delete a range, or split
/// in a new block. Upstream lets `tr` throw these at whatever positions come up;
/// here an edit that doesn't fit is skipped (`try?`), which leaves `tr` as it was.
private func randomStep(_ rng: inout InvertRNG, _ tr: Transform) {
    let sel = rng.r(5), len = tr.doc.content.size
    if sel == 0 || sel == 1 {
        let markSel = rng.r(3)
        let mark = markSel == 0 ? basicSchema.mark("strong")
            : markSel == 1 ? basicSchema.mark("em")
            : basicSchema.mark("link", ["href": .string("/\(rng.r(5))")])
        let from = max(0, rng.r(len) - 1)
        let to = min(len, from + rng.r(10))
        if sel == 1 { _ = try? tr.addMark(from, to, mark) } else { _ = try? tr.removeMark(from, to, mark) }
    } else if sel == 2 {
        _ = try? tr.insert(rng.r(len - 2) + 1, basicSchema.text(randomText(&rng, rng.r(2) + 1)))
    } else if sel == 3 && len > 2 {
        let from = rng.r(len - 3) + 1
        let to = min(len - 1, from + 1 + rng.r(8))
        _ = try? tr.delete(from, to)
    } else {
        let block = rng.r(2) == 0 ? p().node : h1().node
        let pos = rng.r(len - 2) + 1
        _ = try? tr.replace(pos, pos, Slice(content: Fragment.from([block, block]), openStart: 1, openEnd: 1))
    }
}

private func randomDoc(_ rng: inout InvertRNG, _ minLen: Int) -> Node {
    var blocks: [TaggedNode] = []
    var len = 0
    while len < minLen {
        let txt = randomText(&rng, min(minLen - len, rng.r(6) + 2))
        let block: TaggedNode
        switch rng.r(5) {
        case 0: block = h2(txt)
        case 1: block = blockquote(p(txt))
        case 2: block = ul(li(p(txt)), li(p(randomText(&rng, 5))))
        default: block = p(txt)
        }
        blocks.append(block)
        len += block.node.nodeSize
    }
    return try! basicSchema.node("doc", [:], content: Fragment.from(blocks.map(\.node)))
}

func registerPMInvertTests() {
    test("PM invert: reverts to the previous document") {
        for seed in 1 ... 200 {
            var rng = InvertRNG(UInt64(seed))
            let tr = Transform(randomDoc(&rng, 40))
            for j in 0 ..< 10 {
                let start = tr.doc, startI = tr.steps.count
                randomStep(&rng, tr)
                var d = tr.doc
                for k in stride(from: tr.steps.count - 1, through: startI, by: -1) {
                    let inverse = tr.steps[k].invert(tr.docs[k])
                    guard let next = inverse.apply(d).doc else {
                        try expect(false, "seed \(seed) edit \(j): inverse of \(tr.steps[k].jsonID) failed to apply"); return
                    }
                    // Not upstream's: inverting the inverse — what redo does —
                    // has to bring the step's own result back. It's the only
                    // route that inverts a `MarkSetStep`.
                    let redone = inverse.invert(d).apply(next).doc
                    try expectEqual(redone, d, "seed \(seed) edit \(j): redo of \(tr.steps[k].jsonID)")
                    d = next
                }
                try expectEqual(d, start, "seed \(seed) edit \(j)")
            }
        }
    }

    test("PM invert: reverts accurately when mapped") {
        for seed in 1 ... 1000 {
            var rng = InvertRNG(UInt64(seed))
            let start = randomDoc(&rng, 40)
            let first = Transform(start)
            randomStep(&rng, first)
            guard let step = first.steps.first else { continue }
            let other = Transform(start)
            randomStep(&rng, other)
            guard let mapped = step.map(other.mapping), let d = mapped.apply(other.doc).doc else { continue }
            try expectEqual(mapped.invert(other.doc).apply(d).doc, other.doc, "seed \(seed): \(mapped.jsonID)")
        }
    }

    test("PM invert: undoing a replaced link brings the old one back") {
        let d = doc(p(a("abc", href: "/a"), " d")).node
        let step = AddMarkStep(1, 6, basicSchema.mark("link", ["href": .string("/b")]))
        let after = step.apply(d).doc!
        try expectEqual(after, doc(p(a("abc d", href: "/b"))).node)
        // Two ranges to undo — the link to put back, and the plain " d" to strip.
        let inverse = step.invert(d)
        try expect(inverse is MarkSetStep, "two ranges make a set")
        try expectEqual(inverse.apply(after).doc, d)
    }

    test("PM invert: removing a mark only puts it back where it was") {
        let d = doc(p(em("ab"), "cd")).node
        let step = RemoveMarkStep(1, 5, basicSchema.mark("em"))
        let inverse = step.invert(d)
        guard let add = inverse as? AddMarkStep else { try expect(false, "one range, one step"); return }
        try expectEqual([add.from, add.to], [1, 3])
        try expectEqual(inverse.apply(step.apply(d).doc!).doc, d)
    }

    test("PM invert: a mark step keeps what lies between two deletions that took its ends") {
        let em = basicSchema.mark("em")
        // Delete 2..4 and 6..8: both ends of 3..7 go, 4..6 survives as 2..4.
        let mapping = Mapping(maps: [StepMap([2, 2, 0]), StepMap([4, 2, 0])])
        guard let mapped = AddMarkStep(3, 7, em).map(mapping) as? AddMarkStep else {
            try expect(false, "the middle survives"); return
        }
        try expectEqual([mapped.from, mapped.to], [2, 4])
    }

    test("MarkSetStep: JSON round-trips, and refuses anything but mark steps") {
        let d = doc(p(a("abc", href: "/a"), " d")).node
        let set = AddMarkStep(1, 6, basicSchema.mark("link", ["href": .string("/b")])).invert(d)
        let json = set.toJSON()
        try expectEqual(json["stepType"], .string("markSet"))
        let decoded = try decodeStep(basicSchema, json)
        try expect(decoded is MarkSetStep)
        try expectEqual(decoded.toJSON(), json)
        let after = doc(p(a("abc d", href: "/b"))).node
        try expectEqual(decoded.apply(after).doc, d)

        let bad: [[String: AttributeValue]] = [
            ["stepType": "markSet"],
            ["stepType": "markSet", "steps": .string("nope")],
            ["stepType": "markSet", "steps": .array([.object(ReplaceStep(0, 0, .empty).toJSON())])],
            ["stepType": "markSet", "steps": .array([.int(1)])],
        ]
        for json in bad {
            try expectThrows { _ = try decodeStep(basicSchema, json) }
        }
    }

    test("MarkSetStep: nested sets are spliced flat, and an emptied set maps to nil") {
        let em = basicSchema.mark("em")
        let inner = MarkSetStep([AddMarkStep(1, 2, em), RemoveMarkStep(2, 3, em)])
        let outer = MarkSetStep([inner, AddMarkStep(3, 4, em)])
        try expectEqual(outer.steps.count, 3)
        try expect(outer.steps.allSatisfy { !($0 is MarkSetStep) })
        try expect(MarkSetStep([AddMarkStep(2, 3, em)]).map(StepMap([1, 4, 0])) == nil)
    }
}
