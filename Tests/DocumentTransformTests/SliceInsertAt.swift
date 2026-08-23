import Foundation
import DocumentModel
import DocumentTransform
import TestHarness

// `Slice.insertAt` is what a `ReplaceAroundStep` uses to drop the gap — the
// content it leaves in place — into its slice. Without a content check there,
// a step can build a document no schema would accept: a code block holding a
// paragraph, say. The check has to skip a cut edge, though, since what sits
// there in the slice is not what the node ends up owning.
// (prosemirror-model 1.25.3, narrowed in 1.25.5.)

func registerSliceInsertAtTests() {
    test("insertAt: a closed node rejects content it cannot hold") {
        // code_block is `text*`, so a paragraph has no business in one.
        let slice = Slice(content: Fragment.from(pre().node), openStart: 0, openEnd: 0)
        try expectNil(slice.insertAt(1, Fragment.from(p("foo").node)))
    }

    test("insertAt: a closed node accepts content it can hold") {
        let slice = Slice(content: Fragment.from(blockquote().node), openStart: 0, openEnd: 0)
        let out = slice.insertAt(1, Fragment.from(p("foo").node))
        try expectNotNil(out)
        try expectEqual(out!.content.child(0).childCount, 1)
    }

    test("insertAt: an open edge is not checked") {
        // Same node, same insertion point, same content it cannot hold — but
        // the paragraph is cut open on both sides, so the rest of it arrives
        // from the document when the slice is placed and the schema check would
        // be asking about content this node never owns.
        let para = Fragment.from(p("ab").node)
        try expectNil(Slice(content: para, openStart: 0, openEnd: 0)
            .insertAt(2, Fragment.from(p("x").node)))
        try expectNotNil(Slice(content: para, openStart: 1, openEnd: 1)
            .insertAt(1, Fragment.from(p("x").node)))
    }

    test("insertAt: only the outermost children are on an open edge") {
        // A cut runs down the first child at the start and the last child at
        // the end. The middle paragraph is on neither edge — the slice owns all
        // of it — so it is checked like any closed node.
        let three = Fragment.from([p("ab").node, p("cd").node, p("ef").node])
        try expectNil(Slice(content: three, openStart: 1, openEnd: 1)
            .insertAt(4, Fragment.from(p("x").node)))
    }

    test("a ReplaceAroundStep whose gap cannot fit its slice fails") {
        let d = doc(p("foo")).node
        let slice = Slice(content: Fragment.from(pre().node), openStart: 0, openEnd: 0)
        // Wrap the whole paragraph (the gap, 0…5) in the code block.
        let step = ReplaceAroundStep(0, 5, 0, 5, slice, 1, structure: true)
        let result = step.apply(d)
        try expectNil(result.doc)
        try expectNotNil(result.failed)
    }

    test("a ReplaceAroundStep whose gap fits still applies") {
        let d = doc(p("foo")).node
        let slice = Slice(content: Fragment.from(blockquote().node), openStart: 0, openEnd: 0)
        let step = ReplaceAroundStep(0, 5, 0, 5, slice, 1, structure: true)
        let out = step.apply(d)
        try expectNil(out.failed)
        try expectEqual(out.doc, doc(blockquote(p("foo"))).node)
    }

    test("the step that fails would otherwise have built an invalid document") {
        // The point of the guard: this is what applying it used to produce.
        let bad = try! basicSchema.node("code_block", [:], content: Fragment.from(p("foo").node))
        try expect(!bad.type.validContent(bad.content), "expected an invalid code block")
    }
}
