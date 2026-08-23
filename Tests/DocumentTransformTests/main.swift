import Foundation
import DocumentModel
import DocumentTransform
import TestHarness

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) { collector.test(name, body) }

// MARK: - StepMap / Mapping

test("StepMap maps positions across an insertion") {
    // Insert 2 chars at position 3 (oldSize 0, newSize 2).
    let map = StepMap([3, 0, 2])
    try expectEqual(map.map(2), 2)
    try expectEqual(map.map(3), 5)   // assoc 1 → after inserted content
    try expectEqual(map.map(3, -1), 3)
    try expectEqual(map.map(5), 7)
}

test("StepMap invert round-trips") {
    let map = StepMap([3, 4, 1]) // delete 4, insert 1
    let inv = map.invert()
    try expectEqual(map.map(10), 7)
    try expectEqual(inv.map(7), 10)
}

test("Mapping composes step maps") {
    let m = Mapping()
    m.appendMap(StepMap([0, 0, 1])) // insert 1 at 0
    m.appendMap(StepMap([5, 0, 1])) // insert 1 at 5 (post-first-step coords)
    try expectEqual(m.map(0), 1)
    // original 5 → +1 (first insert) → 6 → +1 (second insert at 5 ≤ 6) → 7
    try expectEqual(m.map(5), 7)
}

// MARK: - Transform: replace / delete / insert

test("Transform.insert text") {
    let doc = B.doc(B.p("ad"))
    let tr = Transform(doc)
    try tr.insert(2, B.t("bc"))
    try expectEqual(tr.doc, B.doc(B.p("abcd")))
}

test("Transform.delete within paragraph") {
    let doc = B.doc(B.p("hello world"))
    let tr = Transform(doc)
    try tr.delete(1, 6)
    try expectEqual(tr.doc, B.doc(B.p(" world")))
}

test("Transform.delete joins two paragraphs (Fitter)") {
    let doc = B.doc(B.p("foo"), B.p("bar"))
    let tr = Transform(doc)
    try tr.delete(4, 6) // remove both boundary tokens — exercises the Fitter join
    try expectEqual(tr.doc, B.doc(B.p("foobar")))
}

test("Transform.delete across blockquote (Fitter, structured)") {
    let doc = B.doc(B.p("a"), B.blockquote(B.p("b")))
    let tr = Transform(doc)
    // delete from inside first paragraph to inside the quoted paragraph
    try tr.delete(2, 7)
    try expectEqual(tr.doc, B.doc(B.p("a")))
}

// Regression: deleteRange must not trap when `to` resolves shallower than
// `from` (e.g. deleting from inside a nested block out to a top-level position).
// The old "covered depths" loop read `resolvedTo` at depths it didn't have.
test("deleteRange from inside a nested block out to the document end") {
    let doc = B.doc(B.blockquote(B.p("hello")), B.p("world"))
    let end = doc.content.size
    let tr = Transform(doc)
    try tr.deleteRange(4, end) // deep `from` (doc>blockquote>p), shallow `to` (doc end)
    try expect(tr.doc.content.size < end, "the range was deleted")
    try expectEqual(tr.doc.firstChild?.type.name, "blockquote")
}

test("deleteRange across a list item out to a shallow position") {
    let doc = B.doc(B.ul(B.li(B.p("one")), B.li(B.p("two"))), B.p("after"))
    let end = doc.content.size
    let tr = Transform(doc)
    try tr.deleteRange(4, end) // inside the first list item's paragraph → doc end
    try expect(tr.doc.content.size < end)
}

test("Transform steps are invertible") {
    let doc = B.doc(B.p("hello world"))
    let tr = Transform(doc)
    try tr.delete(1, 6)
    var d = tr.doc
    for i in stride(from: tr.steps.count - 1, through: 0, by: -1) {
        let inverted = tr.steps[i].invert(tr.docs[i])
        let result = inverted.apply(d)
        try expectNil(result.failed)
        d = result.doc!
    }
    try expectEqual(d, doc)
}

// MARK: - Marks

test("addMark wraps text in bold") {
    let doc = B.doc(B.p("hello"))
    let tr = Transform(doc)
    try tr.addMark(1, 6, B.schema.mark("bold"))
    try expectEqual(tr.doc, B.doc(B.p(B.strong("hello"))))
}

test("removeMark by type") {
    let doc = B.doc(B.p(B.strong("hello")))
    let tr = Transform(doc)
    try tr.removeMark(1, 6, B.bold)
    try expectEqual(tr.doc, B.doc(B.p("hello")))
}

// MARK: - Structure

test("setBlockType paragraph -> heading") {
    let doc = B.doc(B.p("title"))
    let tr = Transform(doc)
    try tr.setBlockType(1, 1, B.type("heading"), ["level": .int(1)])
    try expectEqual(tr.doc, B.doc(B.h(1, B.t("title"))))
}

test("split paragraph") {
    let doc = B.doc(B.p("hello"))
    let tr = Transform(doc)
    try tr.split(3) // between "he" and "llo"
    try expectEqual(tr.doc, B.doc(B.p("he"), B.p("llo")))
}

test("join two paragraphs via join()") {
    let doc = B.doc(B.p("foo"), B.p("bar"))
    try expect(canJoin(doc, 5))
    let tr = Transform(doc)
    try tr.join(5)
    try expectEqual(tr.doc, B.doc(B.p("foobar")))
}

test("wrap paragraph in blockquote") {
    let doc = B.doc(B.p("hi"))
    let range = doc.resolve(1).blockRange(doc.resolve(3))
    try expectNotNil(range)
    let tr = Transform(doc)
    try tr.wrap(range!, [NodeTypeWithAttrs(B.type("blockquote"))])
    try expectEqual(tr.doc, B.doc(B.blockquote(B.p("hi"))))
}

test("lift paragraph out of blockquote") {
    let doc = B.doc(B.blockquote(B.p("hi")))
    let range = doc.resolve(2).blockRange(doc.resolve(4))
    try expectNotNil(range)
    let target = liftTarget(range!)
    try expectNotNil(target)
    let tr = Transform(doc)
    try tr.lift(range!, target!)
    try expectEqual(tr.doc, B.doc(B.p("hi")))
}

// MARK: - JSON round-trip of steps

test("ReplaceStep JSON round-trip") {
    let doc = B.doc(B.p("hello"))
    let s = replaceStep(doc, 1, 6, Slice(content: Fragment.from(B.t("bye")), openStart: 0, openEnd: 0))!
    let json = s.toJSON()
    let restored = try decodeStep(B.schema, json)
    try expectEqual(restored.apply(doc).doc, s.apply(doc).doc)
}

registerPMStructureTests(); registerPMTransformTests(); registerPMReplaceTests(); registerPMContentTests(); registerPMSliceTests(); registerPMMarkTests(); registerPMNodeTests(); registerPMMappingTests(); registerPMResolveTests(); registerPMStepTests(); registerPMDiffTests(); registerStepAttrAndNodeMarkTests(); registerMarkStepEdgeTests(); registerAdversarialStepTests(); registerSliceInsertAtTests()

TestSuite.main("DocumentTransformTests", collector.all)
