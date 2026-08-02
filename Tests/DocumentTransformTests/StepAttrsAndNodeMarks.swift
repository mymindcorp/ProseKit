import Foundation
import DocumentModel
import DocumentTransform
import TestHarness

// The four step types no ported ProseMirror suite reaches: AttrStep,
// DocAttrStep, AddNodeMarkStep and RemoveNodeMarkStep. `test-step.ts` covers
// merging for the replace and text-mark steps, and `test-trans.ts` drives
// transforms rather than steps, so these four were running with a third of
// their lines never executed.
//
// They are not obscure. Every one of them is what undo inverts, what collab
// rebases, and what goes over the wire as JSON — the three things asked of a
// step here, so the three things each case checks.

private func headingDoc() -> Node {
    doc(h1("title"), p("body")).node
}

/// A document whose only inline child is an image, at position 1.
private func imageDoc() -> Node { doc(p(img())).node }

/// Apply a step and return the document, failing the test if it didn't apply.
private func applied(_ step: any Step, _ node: Node) throws -> Node {
    let result = step.apply(node)
    guard let out = result.doc else {
        try expect(false, "step failed to apply: \(result.failed ?? "unknown")")
        return node
    }
    return out
}

/// A step through JSON and back, via the registry the wire format uses.
private func roundTripped(_ step: any Step) throws -> any Step {
    try decodeStep(basicSchema, step.toJSON())
}

func registerStepAttrAndNodeMarkTests() {
    // MARK: AttrStep

    test("AttrStep: sets an attribute on the node at its position") {
        let before = headingDoc()
        let after = try applied(AttrStep(0, "level", .int(3)), before)
        try expectEqual(after.child(0).attrs["level"], .int(3))
        // Only that attribute, and only that node.
        try expectEqual(after.child(0).textContent, "title")
        try expectEqual(after.child(1), before.child(1))
    }

    test("AttrStep: fails when nothing is at the position") {
        // Inside the heading's text rather than at a node boundary.
        let result = AttrStep(1, "level", .int(2)).apply(headingDoc())
        try expect(result.doc == nil, "expected no document")
        try expect(result.failed != nil, "expected a failure message")
    }

    test("AttrStep: inverting restores the attribute it replaced") {
        let before = headingDoc()
        let step = AttrStep(0, "level", .int(3))
        let after = try applied(step, before)
        let restored = try applied(step.invert(before), after)
        try expectEqual(restored, before)
    }

    test("AttrStep: an insertion before it moves its position") {
        // What rebasing a remote insert onto a local attribute change does.
        let before = doc(p("first"), h1("title")).node
        let headingPos = before.child(0).nodeSize
        let insert = ReplaceStep(0, 0, Slice(content: Fragment.from(p("new").node),
                                             openStart: 0, openEnd: 0))
        let afterInsert = try applied(insert, before)
        guard let mapped = AttrStep(headingPos, "level", .int(3)).map(insert.getMap()) else {
            try expect(false, "the step should survive an insertion before it"); return
        }
        let out = try applied(mapped, afterInsert)
        // The heading is last now, and it is the one that changed.
        try expectEqual(out.child(2).attrs["level"], .int(3))
        try expectEqual(out.child(0).textContent, "new")
    }

    test("AttrStep: an insertion exactly at its position drops it") {
        // `map` asks with a rightward bias, and an insertion at the position
        // counts as deleting what was after it — so the step no longer knows
        // which node it meant. ProseMirror drops it here too.
        let insert = ReplaceStep(0, 0, Slice(content: Fragment.from(p("new").node),
                                             openStart: 0, openEnd: 0))
        try expect(AttrStep(0, "level", .int(3)).map(insert.getMap()) == nil,
                   "a step whose node is no longer identifiable is dropped")
    }

    test("AttrStep: deleting the node it points at drops the step") {
        let before = headingDoc()
        let delete = ReplaceStep(0, before.child(0).nodeSize, .empty)
        try expect(AttrStep(0, "level", .int(3)).map(delete.getMap()) == nil,
                   "a step whose node is gone has nothing left to do")
    }

    test("AttrStep: survives a round trip through JSON") {
        for value in [AttributeValue.int(3), .string("x"), .bool(true), .null] {
            let step = AttrStep(0, "level", value)
            let back = try roundTripped(step)
            try expectEqual(back.toJSON(), step.toJSON(), "value: \(value)")
            // And still does the same thing to a document.
            try expectEqual(back.apply(headingDoc()).doc, step.apply(headingDoc()).doc)
        }
    }

    test("AttrStep: bad JSON throws rather than guessing") {
        for json: [String: AttributeValue] in [["stepType": "attr", "attr": .string("level")],
                                               ["stepType": "attr", "pos": .int(0)]] {
            try expectThrows { _ = try decodeStep(basicSchema, json) }
        }
    }

    // MARK: DocAttrStep

    test("DocAttrStep: sets an attribute on the document itself") {
        let versioned = try! Schema(nodes: [
            ("doc", NodeSpec(content: "paragraph+", attrs: ["version": AttributeSpec(default: .int(1))])),
            ("paragraph", NodeSpec(content: "text*")),
            ("text", NodeSpec()),
        ], marks: [], topNode: "doc")
        let before = try versioned.node("doc", [:], content: Fragment.from([
            try versioned.node("paragraph", [:], content: Fragment.from([versioned.text("x")])),
        ]))
        try expectEqual(before.attrs["version"], .int(1))
        let after = try applied(DocAttrStep("version", .int(2)), before)
        try expectEqual(after.attrs["version"], .int(2))
        try expectEqual(after.content, before.content)   // the content is untouched
        // And inverting puts the old value back.
        try expectEqual(try applied(DocAttrStep("version", .int(2)).invert(before), after), before)
    }

    test("DocAttrStep: an attribute the document doesn't declare is dropped") {
        // Matching ProseMirror: computing attributes keeps only the declared
        // ones, so this succeeds and changes nothing rather than failing.
        let after = try applied(DocAttrStep("nosuch", .int(2)), headingDoc())
        try expectEqual(after, headingDoc())
    }

    test("DocAttrStep: maps to itself") {
        // It has no position, so nothing an edit does can move it.
        let step = DocAttrStep("version", .int(2))
        let insert = ReplaceStep(0, 0, Slice(content: Fragment.from(p("new").node),
                                             openStart: 0, openEnd: 0))
        guard let mapped = step.map(insert.getMap()) else {
            try expect(false, "a document attribute step always survives"); return
        }
        try expectEqual(mapped.toJSON(), step.toJSON())
    }

    test("DocAttrStep: inverting reads the attribute the document had") {
        let inverted = DocAttrStep("version", .int(2)).invert(headingDoc())
        try expectEqual(inverted.toJSON()["value"], .null)  // absent, so null
        try expectEqual(inverted.toJSON()["attr"], .string("version"))
    }

    test("DocAttrStep: survives a round trip through JSON") {
        let step = DocAttrStep("version", .int(2))
        try expectEqual(try roundTripped(step).toJSON(), step.toJSON())
        try expectThrows { _ = try decodeStep(basicSchema, ["stepType": "docAttr"]) }
    }

    // MARK: AddNodeMarkStep / RemoveNodeMarkStep
    //
    // Marks on a *node* rather than a range of text — what an image carries
    // when it sits inside a link.

    test("AddNodeMarkStep: marks the node at its position") {
        let before = imageDoc()
        let mark = basicSchema.mark("em")
        let after = try applied(AddNodeMarkStep(1, mark), before)
        try expect(after.child(0).child(0).marks.contains { $0.type.name == "em" },
                   "expected the image to carry the mark")
    }

    test("AddNodeMarkStep: inverting removes what it added") {
        let before = imageDoc()
        let step = AddNodeMarkStep(1, basicSchema.mark("em"))
        let after = try applied(step, before)
        try expectEqual(try applied(step.invert(before), after), before)
    }

    test("RemoveNodeMarkStep: inverting puts back what it removed") {
        let mark = basicSchema.mark("em")
        let marked = try applied(AddNodeMarkStep(1, mark), imageDoc())
        let step = RemoveNodeMarkStep(1, mark)
        let after = try applied(step, marked)
        try expect(after.child(0).child(0).marks.isEmpty, "the mark should be gone")
        try expectEqual(try applied(step.invert(marked), after), marked)
    }

    test("RemoveNodeMarkStep: removing a mark that isn't there changes nothing") {
        let before = imageDoc()
        try expectEqual(try applied(RemoveNodeMarkStep(1, basicSchema.mark("strong")), before),
                        before)
    }

    test("node mark steps: an insertion ahead of them moves their position") {
        let before = imageDoc()
        let insert = ReplaceStep(0, 0, Slice(content: Fragment.from(p("new").node),
                                             openStart: 0, openEnd: 0))
        let afterInsert = try applied(insert, before)
        guard let mapped = AddNodeMarkStep(1, basicSchema.mark("em")).map(insert.getMap()) else {
            try expect(false, "the step should survive an insertion before it"); return
        }
        let out = try applied(mapped, afterInsert)
        try expect(out.child(1).child(0).marks.contains { $0.type.name == "em" },
                   "the image moved, and the mark went with it")
    }

    test("node mark steps: survive a round trip through JSON") {
        for step: any Step in [AddNodeMarkStep(1, basicSchema.mark("em")),
                               RemoveNodeMarkStep(1, basicSchema.mark("em"))] {
            let back = try roundTripped(step)
            try expectEqual(back.toJSON(), step.toJSON())
            try expectEqual(back.apply(imageDoc()).doc, step.apply(imageDoc()).doc)
        }
    }
}
