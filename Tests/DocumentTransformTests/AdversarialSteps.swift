import Foundation
import DocumentModel
import DocumentTransform
import TestHarness

// Steps arrive from peers, stored documents and the clipboard, so their
// positions are untrusted. `ResolvedPos.resolve` traps rather than throwing on a
// position outside the document, which `StepResult.fromReplace`'s do/catch can
// never see — so every step has to reject the position before it resolves it.
// Each of these crashed the process before that check existed.

func registerAdversarialStepTests() {
    let doc = B.doc(B.p("hello"))   // content.size == 7

    // MARK: - Positions outside the document

    test("adversarial: a replace step past the end fails instead of trapping") {
        let step = ReplaceStep(9999, 9999, Slice.empty)
        try expectNotNil(step.apply(doc).failed)
        try expectNil(step.apply(doc).doc)
    }

    test("adversarial: a replace step whose `to` is past the end fails") {
        try expectNotNil(ReplaceStep(1, 9999, Slice.empty).apply(doc).failed)
    }

    test("adversarial: a replace-around step past the end fails") {
        try expectNotNil(ReplaceAroundStep(0, 9999, 1, 2, Slice.empty, 0).apply(doc).failed)
    }

    test("adversarial: a replace-around gap past the end fails") {
        try expectNotNil(ReplaceAroundStep(0, 7, 1, 9999, Slice.empty, 0).apply(doc).failed)
    }

    test("adversarial: a mark step past the end fails") {
        try expectNotNil(AddMarkStep(0, 9999, B.schema.mark("italic")).apply(doc).failed)
        try expectNotNil(RemoveMarkStep(0, 9999, B.schema.mark("italic")).apply(doc).failed)
    }

    // `insert` indexes into the step's own slice rather than the document, and
    // ran off the end of it separately.
    test("adversarial: a replace-around insert outside its slice fails") {
        try expectNotNil(ReplaceAroundStep(0, 7, 1, 6, Slice.empty, 9999).apply(doc).failed)
    }

    // MARK: - Positions no document could produce

    test("adversarial: negative step positions are rejected when decoded") {
        let cases: [[String: AttributeValue]] = [
            ["stepType": "replace", "from": .int(-5), "to": .int(-1)],
            ["stepType": "replaceAround", "from": .int(-1), "to": .int(2),
             "gapFrom": .int(0), "gapTo": .int(1), "insert": .int(0)],
            ["stepType": "replaceAround", "from": .int(0), "to": .int(2),
             "gapFrom": .int(0), "gapTo": .int(1), "insert": .int(-9)],
            ["stepType": "addMark", "from": .int(-3), "to": .int(1), "mark": .object(["type": "italic"])],
            ["stepType": "removeMark", "from": .int(-3), "to": .int(1), "mark": .object(["type": "italic"])],
        ]
        for json in cases {
            try expectThrows({ _ = try decodeStep(B.schema, json) })
        }
    }

    // A negative position reaches `getMap`'s `to - from` before any document is
    // in hand, where the full integer range overflows and traps.
    test("adversarial: a step spanning the integer range can't be decoded") {
        try expectThrows({
            _ = try decodeStep(B.schema, ["stepType": "replace",
                                          "from": .int(Int.min), "to": .int(Int.max)])
        })
    }

    // MARK: - The guarded paths on top of `apply`

    test("adversarial: maybeStep rejects an out-of-range step and keeps the doc") {
        let tr = Transform(doc)
        try expectNotNil(tr.maybeStep(ReplaceStep(9999, 9999, Slice.empty)).failed)
        try expectEqual(tr.doc, doc)
        try expect(!tr.docChanged)
        try expect(tr.steps.isEmpty)
    }

    test("adversarial: step() throws on an out-of-range step") {
        try expectThrows({ _ = try Transform(doc).step(ReplaceStep(9999, 9999, Slice.empty)) })
    }

    // The realistic shape of this: a step that was valid for the document it was
    // made against, applied to a shorter one — which is what a peer's step looks
    // like after the document has been edited underneath it.
    test("adversarial: a step from a longer document fails on a shorter one") {
        let longer = B.doc(B.p("hello"), B.p("world"))
        let step = ReplaceStep(8, 13, Slice.empty)
        try expectNil(step.apply(longer).failed)      // fits the document it was made for
        try expectNotNil(step.apply(doc).failed)      // and is refused, not fatal, on this one
    }

    // MARK: - Slices whose open depths overstate their content

    // A slice's open depths are a claim about its content, and `Slice`'s
    // initializer takes them as given — it is built once per keystroke on the
    // replace path and cannot afford to re-derive them. So a slice built in
    // code, rather than decoded through `Slice.fromJSON` (which clamps), can
    // claim more depth than it has. Every one of these crashed or hung the
    // process: the Fitter walks the claim literally, and a slice that claims
    // more depth than it has content reports a *negative* size, which its
    // `while unplaced.size != 0` loop reads as work still to do.

    test("adversarial: an empty slice claiming open depth doesn't hang the fitter") {
        // size == -3. Found by the transform fuzz driving `replaceRange`.
        let slice = Slice(content: .empty, openStart: 0, openEnd: 3)
        let tr = Transform(doc)
        _ = try? tr.replaceRange(1, 3, slice)
        try tr.doc.check()
    }

    test("adversarial: a flat slice claiming to be nested doesn't trap") {
        // One text node, so nothing is open; the slice says four levels are.
        let slice = Slice(content: Fragment.from(B.t("hi")), openStart: 4, openEnd: 4)
        let tr = Transform(doc)
        _ = try? tr.replace(1, 3, slice)
        try tr.doc.check()
    }

    test("adversarial: over-open depths are clamped, not silently obeyed") {
        // The clamp is what the paragraph's own nesting allows: one level in
        // from each side, no more.
        let slice = Slice(content: Fragment.from(B.p("in")), openStart: 5, openEnd: 5)
        let clamped = slice.clampingOpenDepths()
        try expectEqual(clamped.openStart, 1)
        try expectEqual(clamped.openEnd, 1)
        try expectEqual(clamped.content, slice.content)
        // And a slice that was already honest comes back untouched.
        let honest = Slice(content: Fragment.from(B.p("in")), openStart: 1, openEnd: 0)
        try expectEqual(honest.clampingOpenDepths(), honest)
    }

    test("adversarial: a slice whose spine runs out mid-fit doesn't trap") {
        // `openStart` claims a leading spine — descend `firstChild` this many
        // times and a node is there each time. The Fitter walks that claim
        // literally, and `placeNodes` can consume the spine while carrying the
        // claim across, so a slice that was honest on the way in stops being
        // honest a round later. Two children that can't be siblings is the
        // shortest way to reach it: the list item is placed, the depth of two
        // stays, and the bare text left behind has no spine at all.
        let inner = Slice(content: Fragment.from([B.li(B.p("a")), B.t("tail")]),
                          openStart: 2, openEnd: 0)
        let target = B.doc(B.ul(B.li(B.p("one"))), B.p("two"))
        for from in 0 ... target.content.size {
            let tr = Transform(target)
            _ = try? tr.replace(from, target.content.size, inner)
            try tr.doc.check()
        }
    }

    test("adversarial: replaceStep declines an over-open slice rather than trapping") {
        let slice = Slice(content: .empty, openStart: 2, openEnd: 2)
        // Clamped to a genuinely empty slice, so replacing nothing with it is
        // the no-op `replaceStep` reports as nil.
        try expectNil(replaceStep(doc, 3, 3, slice))
    }

    // MARK: - Valid steps still work

    test("adversarial: the bounds check leaves valid steps alone") {
        let step = ReplaceStep(1, 6, Slice(content: Fragment.from(B.t("bye")), openStart: 0, openEnd: 0))
        try expectEqual(step.apply(doc).doc, B.doc(B.p("bye")))
        // The last position in the document is in range; one past it isn't.
        try expectEqual(doc.content.size, 7)
        try expectNil(ReplaceStep(7, 7, Slice.empty).apply(doc).failed)
        try expectNotNil(ReplaceStep(8, 8, Slice.empty).apply(doc).failed)
    }
}
