import Foundation
import DocumentModel
import DocumentTransform
import EditorCollab
import TestHarness

// Ported from prosemirror-collab/test/test-rebase.ts — rebaseSteps, the core of
// collaborative editing (rebasing local steps over concurrent remote steps).

private typealias Client = @Sendable (Transform, [String: Int]) -> Transform

private func runRebase(_ transforms: [Transform], _ startTags: [String: Int], _ expected: TaggedNode) throws {
    guard let first = transforms.first else { return }
    let full = Transform(first.before)
    for transform in transforms {
        let rebased = Transform(transform.doc)
        let startLen = transform.steps.count + full.steps.count
        let rb = transform.steps.enumerated().map { i, s in
            Rebaseable(step: s, inverted: s.invert(transform.docs[i]), origin: nil)
        }
        rebaseSteps(rb, full.steps, rebased)
        var i = startLen
        while i < rebased.steps.count { try full.step(rebased.steps[i]); i += 1 }
    }
    try expectEqual(full.doc, expected.node)
    // Every tag in the start doc must map to its expected position (or be deleted).
    for (tag, pos) in startTags {
        let mapped = full.mapping.mapResult(pos)
        let exp = expected.tags[tag]
        if mapped.deleted {
            try expect(exp == nil, "tag <\(tag)> was unexpectedly deleted")
        } else {
            try expect(exp != nil, "tag <\(tag)> should have been deleted")
            try expectEqual(mapped.pos, exp!, "tag <\(tag)>")
        }
    }
}

private func permute<T>(_ array: [T]) -> [[T]] {
    if array.count < 2 { return [array] }
    var result: [[T]] = []
    for i in array.indices {
        var rest = array
        rest.remove(at: i)
        for sub in permute(rest) { result.append([array[i]] + sub) }
    }
    return result
}

private func typeAt(_ tr: Transform, _ pos: Int, _ text: String) -> Transform {
    try! tr.replaceWith(pos, pos, basicSchema.text(text))
}
private func wrapAt(_ tr: Transform, _ pos: Int, _ type: String) -> Transform {
    let rpos = tr.doc.resolve(pos)
    return try! tr.wrap(rpos.blockRange(rpos)!, [NodeTypeWithAttrs(basicSchema.nodes[type]!)])
}

func registerPMRebaseTests() {
    func rebase(_ name: String, _ d: TaggedNode, _ clients: [Client], _ expected: TaggedNode) {
        test("PM rebase: \(name)") {
            let transforms = clients.map { $0(Transform(d.node), d.tags) }
            try runRebase(transforms, d.tags, expected)
        }
    }
    func rebasePermute(_ name: String, _ d: TaggedNode, _ clients: [Client], _ expected: TaggedNode) {
        test("PM rebase (permuted): \(name)") {
            let transforms = clients.map { $0(Transform(d.node), d.tags) }
            for perm in permute(transforms) { try runRebase(perm, d.tags, expected) }
        }
    }

    rebasePermute("supports concurrent typing", doc(p("h<1>ell<2>o")),
        [{ tr, _ in typeAt(tr, 2, "X") }, { tr, _ in typeAt(tr, 5, "Y") }],
        doc(p("hX<1>ellY<2>o")))
    rebasePermute("supports multiple concurrently typed chars", doc(p("h<1>ell<2>o")),
        [{ tr, _ in typeAt(typeAt(typeAt(tr, 2, "X"), 3, "Y"), 4, "Z") }, { tr, _ in typeAt(typeAt(tr, 5, "U"), 6, "V") }],
        doc(p("hXYZ<1>ellUV<2>o")))
    rebasePermute("supports three concurrent typers", doc(p("h<1>ell<2>o th<3>ere")),
        [{ tr, _ in typeAt(tr, 2, "X") }, { tr, _ in typeAt(tr, 5, "Y") }, { tr, _ in typeAt(tr, 9, "Z") }],
        doc(p("hX<1>ellY<2>o thZ<3>ere")))
    rebasePermute("handles wrapping of changed blocks", doc(p("<1>hell<2>o<3>")),
        [{ tr, _ in typeAt(tr, 5, "X") }, { tr, _ in wrapAt(tr, 1, "blockquote") }],
        doc(blockquote(p("<1>hellX<2>o<3>"))))
    rebasePermute("handles insertions in deleted content", doc(p("hello<1> wo<2>rld<3>!")),
        [{ tr, _ in try! tr.delete(6, 12) }, { tr, _ in typeAt(tr, 9, "X") }],
        doc(p("hello<3>!")))
    rebase("allows deleting the same content twice", doc(p("hello<1> wo<2>rld<3>!")),
        [{ tr, _ in try! tr.delete(6, 12) }, { tr, _ in try! tr.delete(6, 12) }],
        doc(p("hello<3>!")))
    rebasePermute("isn't confused by joining a block that's being edited", doc(ul(li(p("one")), "<1>", li(p("tw<2>o")))),
        [{ tr, _ in typeAt(tr, 12, "A") }, { tr, _ in try! tr.join(8) }],
        doc(ul(li(p("one"), p("twA<2>o")))))
    rebase("supports typing concurrently with marking", doc(p("hello <1>wo<2>rld<3>")),
        [{ tr, _ in try! tr.addMark(7, 12, basicSchema.mark("em")) }, { tr, _ in typeAt(tr, 9, "_") }],
        doc(p("hello <1>", em("wo"), "_<2>", em("rld<3>"))))
    rebase("doesn't unmark marks added concurrently", doc(p(em("<1>hello"), " world<2>")),
        [{ tr, _ in try! tr.addMark(1, 12, basicSchema.mark("em")) }, { tr, _ in try! tr.removeMark(1, 12, basicSchema.mark("em")) }],
        doc(p("<1>hello", em(" world<2>"))))
    rebase("doesn't mark concurrently unmarked text", doc(p("<1>hello ", em("world<2>"))),
        [{ tr, _ in try! tr.removeMark(1, 12, basicSchema.mark("em")) }, { tr, _ in try! tr.addMark(1, 12, basicSchema.mark("em")) }],
        doc(p(em("<1>hello "), "world<2>")))
    rebasePermute("maps through inserts", doc(p("X<1>X<2>X")),
        [{ tr, _ in typeAt(tr, 2, "hello") }, { tr, _ in try! typeAt(tr, 3, "goodbye").delete(4, 7) }],
        doc(p("Xhello<1>Xgbye<2>X")))
    rebase("handle concurrent removal of blocks", doc(p("a"), "<1>", p("b"), "<2>", p("c")),
        [{ tr, t in try! tr.delete(t["1"]!, t["2"]!) }, { tr, t in try! tr.delete(t["1"]!, t["2"]!) }],
        doc(p("a"), "<2>", p("c")))
    rebasePermute("discards edits in removed blocks", doc(p("a"), "<1>", p("b<2>"), "<3>", p("c")),
        [{ tr, t in try! tr.delete(t["1"]!, t["3"]!) }, { tr, t in typeAt(tr, t["2"]!, "ay") }],
        doc(p("a"), "<3>", p("c")))
    rebase("preserves double block inserts", doc(p("a"), "<1>", p("b")),
        [{ tr, _ in try! tr.replaceWith(3, 3, basicSchema.node("paragraph")) }, { tr, _ in try! tr.replaceWith(3, 3, basicSchema.node("paragraph")) }],
        doc(p("a"), p(), p(), "<1>", p("b")))
}
