import Foundation
import DocumentModel
import DocumentTransform
import TestHarness

// Tests written against surviving mutants: each one pins a behaviour that the
// rest of the suite let be broken without failing. They are modelled on
// upstream prosemirror-transform (test-mapping.ts, test-step.ts,
// test-structure.ts, test-trans.ts) and on what upstream's code computes.

/// `plain` takes only `strong`; `rich` takes any mark. Kept alive at file
/// scope: a document can't outlive its schema.
private let strictMarkSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("plain", NodeSpec(content: "inline*", marks: "strong", group: "block")),
    ("rich", NodeSpec(content: "inline*", group: "block")),
    ("text", NodeSpec(group: "inline")),
    ("pic", NodeSpec(group: "inline", inline: true)),
], marks: [
    ("em", MarkSpec()),
    ("strong", MarkSpec()),
])

/// `section` holds paragraphs (or pairs of them) then an optional `tail`;
/// `pair` is exactly two paragraphs.
private let liftSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "section+")),
    ("section", NodeSpec(content: "(p | pair)+ tail?")),
    ("tail", NodeSpec(content: "p+")),
    ("pair", NodeSpec(content: "p p")),
    ("p", NodeSpec(content: "text*")),
    ("text", NodeSpec()),
])

/// A document that must start with a heading and keep a paragraph, a `qdoc`
/// whose first quote is mandatory, and an isolating textblock.
private let joinSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "heading (paragraph | iso)+")),
    ("qdoc", NodeSpec(content: "qa qb*")),
    ("qa", NodeSpec(content: "paragraph+")),
    ("qb", NodeSpec(content: "paragraph+")),
    ("heading", NodeSpec(content: "text*")),
    ("paragraph", NodeSpec(content: "text*")),
    ("iso", NodeSpec(content: "text*", isolating: true)),
    ("text", NodeSpec()),
], topNode: "doc")

/// The figure part of upstream test-structure.ts's schema.
private let figureSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block*")),
    ("para", NodeSpec(content: "text*", group: "block")),
    ("figure", NodeSpec(content: "caption figureimage", group: "block")),
    ("caption", NodeSpec(content: "text*", marks: "")),
    ("figureimage", NodeSpec()),
    ("text", NodeSpec()),
])

/// A figure is blocks with an optional trailing caption.
private let captionFigureSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("para", NodeSpec(content: "text*", group: "block")),
    ("figure", NodeSpec(content: "block+ figcaption?", group: "block")),
    ("figcaption", NodeSpec(content: "text*")),
    ("text", NodeSpec()),
])

func registerTransformMutationKillTests() {
    // MARK: StepMap / Mapping

    // A mirrored pair where the *inverted* map comes first: the recovery lands
    // in the plain map, whose `recover` has to add up the size change of the
    // ranges in front of the one it recovers into.
    test("mutation: Mapping recovers through a mirrored pair whose second map is not inverted") {
        let ranges = [0, 1, 2, 4, 1, 3]
        let mapping = Mapping(maps: [StepMap(ranges).invert(), StepMap(ranges)], mirror: [0, 1])
        // 6 sits inside the inverted map's second range (5..8); recovery
        // through the plain map must put it back at 6, not 5.
        try expectEqual(mapping.map(6), 6)
        try expectEqual(mapping.map(6, -1), 6)
        try expectEqual(mapping.map(7), 7)
    }

    test("mutation: StepMap.forEach reports new starts of an inverted map") {
        let ranges = [0, 1, 2, 4, 1, 3]
        var plain: [[Int]] = []
        StepMap(ranges).forEach { plain.append([$0, $1, $2, $3]) }
        try expectEqual(plain, [[0, 1, 0, 2], [4, 5, 5, 8]])
        var inverted: [[Int]] = []
        StepMap(ranges).invert().forEach { inverted.append([$0, $1, $2, $3]) }
        try expectEqual(inverted, [[0, 2, 0, 1], [5, 8, 4, 5]])
    }

    // A mirror whose partner lies past the end of a sliced mapping can't be
    // used for recovery: the slice never gets to the map that restores the
    // content, so the position is mapped as deleted.
    test("mutation: a sliced Mapping ignores a mirror outside the slice") {
        let mapping = Mapping(maps: [StepMap([2, 4, 0]), StepMap([2, 0, 4])], mirror: [0, 1])
        try expectEqual(mapping.map(4), 4, "the whole mapping recovers")
        try expectEqual(mapping.slice(0, 1).map(4), 2, "the slice only deletes")
        try expectEqual(mapping.slice(0, 1).mapResult(4).pos, 2)
        try expect(mapping.slice(0, 1).mapResult(4).deleted)
    }

    // MARK: ReplaceStep

    // Only a step whose *both* ends were deleted across is dropped; one whose
    // start fell inside a deletion survives, shrunk to what is left.
    test("mutation: ReplaceStep.map keeps a step whose start alone was deleted") {
        let slice = Slice(content: Fragment.from(basicSchema.text("x")), openStart: 0, openEnd: 0)
        let step = ReplaceStep(3, 7, slice)
        guard let mapped = step.map(StepMap([2, 2, 0])) as? ReplaceStep else {
            try expect(false, "the step should survive the mapping"); return
        }
        try expectEqual(mapped.from, 2)
        try expectEqual(mapped.to, 5)
        try expectEqual(mapped.slice, slice)
        // Both ends inside one deletion: gone.
        try expect(ReplaceStep(3, 4, slice).map(StepMap([2, 4, 0])) == nil)
    }

    // An insertion mapped over another insertion at the same point: `from`
    // moves past it (assoc 1), `to` stays before it (assoc -1), and the step
    // must not come out with `to < from`.
    test("mutation: ReplaceStep.map never produces to < from") {
        let slice = Slice(content: Fragment.from(basicSchema.text("x")), openStart: 0, openEnd: 0)
        guard let mapped = ReplaceStep(3, 3, slice).map(StepMap([3, 0, 2])) as? ReplaceStep else {
            try expect(false, "the insertion should survive"); return
        }
        try expectEqual(mapped.from, 5)
        try expectEqual(mapped.to, 5)
        let d = doc(p("abcdef")).node
        let applied = mapped.apply(try d.replace(3, 3, Slice(content: Fragment.from(basicSchema.text("YZ")), openStart: 0, openEnd: 0)))
        try expectEqual(applied.doc, doc(p("abYZxcdef")).node)
    }

    // Typing followed by a split right after the typed text: the split's slice
    // is open at its start, so the two can't be concatenated into one slice.
    test("mutation: ReplaceStep.merge refuses a following step whose slice is open at the start") {
        let typed = ReplaceStep(2, 2, Slice(content: Fragment.from(basicSchema.text("a")), openStart: 0, openEnd: 0))
        let para = try basicSchema.node("paragraph")
        let split = ReplaceStep(3, 3, Slice(content: Fragment.from([para, para]), openStart: 1, openEnd: 1))
        try expect(typed.merge(split) == nil)
        // …and the mirror cases: a split followed by typing on either side of
        // it, where the split's slice is open at the end / start that touches.
        let split2 = ReplaceStep(2, 2, Slice(content: Fragment.from([para, para]), openStart: 1, openEnd: 1))
        let after = ReplaceStep(4, 4, Slice(content: Fragment.from(basicSchema.text("a")), openStart: 0, openEnd: 0))
        try expect(split2.merge(after) == nil)
        try expect(split2.merge(typed) == nil)
    }

    // MARK: ReplaceAroundStep

    // A replacement that swallows both the gap's end and the step's end maps
    // `gapTo` (assoc 1) past the inserted text and `to` (assoc -1) before it —
    // a gap that would end after the step does. Such a step is dropped.
    test("mutation: ReplaceAroundStep.map drops a step whose gap would end past it") {
        let wrapper = Slice(content: Fragment.from(try basicSchema.node("blockquote")), openStart: 0, openEnd: 0)
        let step = ReplaceAroundStep(2, 12, 3, 11, wrapper, 1, structure: true)
        try expect(step.map(StepMap([10, 3, 2])) == nil, "gapTo 12 > to 10")
        // The start-side twin: gapFrom lands before from.
        try expect(step.map(StepMap([1, 3, 2])) == nil, "gapFrom 1 < from 3")
        // A mapping that keeps the ends in order keeps the step.
        guard let kept = step.map(StepMap([6, 1, 0])) as? ReplaceAroundStep else {
            try expect(false, "an edit inside the gap keeps the step"); return
        }
        try expectEqual([kept.from, kept.to, kept.gapFrom, kept.gapTo], [2, 11, 3, 10])
    }

    // Content inserted right at the gap's edges belongs to the gap — it is the
    // content the step keeps — so gapFrom maps with assoc -1 and gapTo with 1.
    test("mutation: ReplaceAroundStep.map widens the gap over insertions at its edges") {
        let wrapper = Slice(content: Fragment.from(try basicSchema.node("blockquote")), openStart: 0, openEnd: 0)
        let step = ReplaceAroundStep(2, 12, 3, 11, wrapper, 1, structure: true)
        guard let atStart = step.map(StepMap([3, 0, 2])) as? ReplaceAroundStep else {
            try expect(false, "kept"); return
        }
        try expectEqual([atStart.from, atStart.to, atStart.gapFrom, atStart.gapTo], [2, 14, 3, 13])
        guard let atEnd = step.map(StepMap([11, 0, 2])) as? ReplaceAroundStep else {
            try expect(false, "kept"); return
        }
        try expectEqual([atEnd.from, atEnd.to, atEnd.gapFrom, atEnd.gapTo], [2, 14, 3, 13])
    }

    test("mutation: ReplaceAroundStep.map keeps a step whose start alone was deleted") {
        let wrapper = Slice(content: Fragment.from(try basicSchema.node("blockquote")), openStart: 0, openEnd: 0)
        let step = ReplaceAroundStep(2, 12, 2, 12, wrapper, 1, structure: true)
        guard let mapped = step.map(StepMap([1, 2, 0])) as? ReplaceAroundStep else {
            try expect(false, "only one end was deleted across"); return
        }
        try expectEqual([mapped.from, mapped.to, mapped.gapFrom, mapped.gapTo], [1, 10, 1, 10])
        try expect(step.map(StepMap([0, 14, 0])) == nil, "both ends deleted across")
    }

    // A gap open on only one side is still not flat.
    test("mutation: ReplaceAroundStep.apply rejects a gap open on one side only") {
        let d = doc(p("ab"), p("cd")).node
        let wrapper = Slice(content: Fragment.from(try basicSchema.node("blockquote")), openStart: 0, openEnd: 0)
        // gapFrom 2 is inside the first paragraph, gapTo 4 is between blocks.
        let openAtStart = ReplaceAroundStep(0, 4, 2, 4, wrapper, 1).apply(d)
        try expectEqual(openAtStart.failed, "Gap is not a flat range")
        // gapFrom 0 between blocks, gapTo 6 inside the second paragraph.
        let openAtEnd = ReplaceAroundStep(0, 8, 0, 6, wrapper, 1).apply(d)
        try expectEqual(openAtEnd.failed, "Gap is not a flat range")
    }

    // MARK: Mark steps

    // A mark step that maps to an empty range has nothing left to mark, even
    // when neither of its ends was deleted.
    test("mutation: mark steps mapping to an empty range are dropped") {
        let emMark = basicSchema.mark("em")
        try expect(AddMarkStep(3, 3, emMark).map(StepMap.empty) == nil)
        try expect(RemoveMarkStep(3, 3, emMark).map(StepMap.empty) == nil)
        guard let kept = AddMarkStep(3, 4, emMark).map(StepMap.empty) as? AddMarkStep else {
            try expect(false, "a one-character range survives"); return
        }
        try expectEqual([kept.from, kept.to], [3, 4])
    }

    // Upstream's merge tests only put the later range second; the adjacency
    // check is symmetric, so a step followed by one that ends where it starts
    // merges too.
    test("mutation: mark steps merge with an adjacent step that comes before them") {
        let emMark = basicSchema.mark("em")
        let d = doc(p("foobar")).node
        guard let added = AddMarkStep(2, 4, emMark).merge(AddMarkStep(1, 2, emMark)) as? AddMarkStep else {
            try expect(false, "adjacent add-mark steps merge"); return
        }
        try expectEqual([added.from, added.to], [1, 4])
        try expectEqual(added.apply(d).doc, doc(p(em("foo"), "bar")).node)
        guard let removed = RemoveMarkStep(2, 4, emMark).merge(RemoveMarkStep(1, 2, emMark)) as? RemoveMarkStep else {
            try expect(false, "adjacent remove-mark steps merge"); return
        }
        try expectEqual([removed.from, removed.to], [1, 4])
        try expect(AddMarkStep(3, 4, emMark).merge(AddMarkStep(1, 2, emMark)) == nil, "separated ranges don't")
    }

    test("mutation: mark steps survive a deletion that takes only one of their ends") {
        let emMark = basicSchema.mark("em")
        guard let removed = RemoveMarkStep(3, 7, emMark).map(StepMap([2, 2, 0])) as? RemoveMarkStep else {
            try expect(false, "the remove step keeps what is left of its range"); return
        }
        try expectEqual([removed.from, removed.to], [2, 5])
        guard let added = AddMarkStep(3, 7, emMark).map(StepMap([6, 3, 0])) as? AddMarkStep else {
            try expect(false, "the add step keeps what is left of its range"); return
        }
        try expectEqual([added.from, added.to], [3, 6])
        try expect(RemoveMarkStep(3, 7, emMark).map(StepMap([2, 6, 0])) == nil, "both ends deleted")
    }

    // A mark step leaves inline content alone where the parent doesn't allow
    // the mark — the step still succeeds, on the rest of its range.
    test("mutation: AddMarkStep skips inline nodes whose parent disallows the mark") {
        let s = strictMarkSchema
        let em = s.mark("em"), strong = s.mark("strong")
        let plain = try s.node("plain", content: Fragment.from([s.text("ab"), try s.node("pic")]))
        let rich = try s.node("rich", content: Fragment.from([s.text("cd"), try s.node("pic")]))
        let d = try s.node("doc", content: Fragment.from([plain, rich]))
        let result = AddMarkStep(0, d.content.size, em).apply(d)
        let markedRich = try s.node("rich", content: Fragment.from([s.text("cd", [em]), try s.node("pic", marks: [em])]))
        try expectEqual(result.doc, try s.node("doc", content: Fragment.from([plain, markedRich])))
        // A mark the strict parent does allow goes on everywhere.
        let strongDoc = AddMarkStep(0, d.content.size, strong).apply(d).doc
        try expectEqual(strongDoc?.child(0).child(0).marks, [strong])
        try expectEqual(strongDoc?.child(0).child(1).marks, [strong])
    }

    // MARK: Structure helpers

    // The start-side twin of the end-side "stops at an ancestor" case: at the
    // start of the item's *second* paragraph the item has content before it,
    // so the list in front of the item isn't "right before" this position.
    test("mutation: insertPoint stops at an ancestor with content before the position") {
        let d = doc(ul(li(p("a"), p("b")))).node
        // 6 is the start of p("b") inside the item.
        try expectNil(insertPoint(d, 6, basicSchema.nodes["list_item"]!))
        // At the start of the first paragraph it may climb out in front of the item.
        try expectEqual(insertPoint(d, 3, basicSchema.nodes["list_item"]!), 1)
    }

    // The mirror of upstream's "notices unliftable content after or before":
    // lifting the *last* paragraph out of `tail` has to put it after the tail,
    // where `p+ tail?` doesn't allow it — it must not take the tail's place.
    test("mutation: liftTarget accounts for content before the lifted range") {
        let s = liftSchema
        let para = try s.node("p", content: Fragment.from(s.text("A")))
        let d = try s.node("doc", content: Fragment.from(try s.node("section", content: Fragment.from([
            para, try s.node("tail", content: Fragment.from([para, para, para])),
        ]))))
        // section 0, p 1..4, tail 4, its paragraphs at 5, 8, 11.
        try expectNil(liftTarget(d.resolve(12).blockRange()!)) // last paragraph of the tail
        try expectEqual(liftTarget(d.resolve(6).blockRange()!), 1, "first paragraph lifts in front of the tail")
    }

    // A wrapper whose content the range doesn't complete is no wrapping.
    test("mutation: findWrapping requires the range to finish the wrapper's content") {
        let s = liftSchema
        let para = try s.node("p", content: Fragment.from(s.text("A")))
        let d = try s.node("doc", content: Fragment.from(try s.node("section", content: Fragment.from([para, para]))))
        let pair = s.nodes["pair"]!
        // One paragraph can't fill `pair` ("p p").
        try expectNil(findWrappingForRange(d.resolve(2).blockRange()!, pair))
        // Two can.
        let both = d.resolve(2).blockRange(d.resolve(5))!
        try expectEqual(findWrappingForRange(both, pair)?.map { $0.type.name }, ["pair"])
    }

    // Joining is only possible when the parent can lose the child after the
    // boundary: `heading paragraph+` can't give up its only paragraph.
    test("mutation: canJoin asks the parent whether it can lose a child") {
        let s = joinSchema
        let d = try s.node("doc", content: Fragment.from([
            try s.node("heading", content: Fragment.from(s.text("a"))),
            try s.node("paragraph", content: Fragment.from(s.text("b"))),
        ]))
        try expect(!canJoin(d, 3), "heading + its only paragraph")
        let d2 = try s.node("doc", content: Fragment.from([
            try s.node("heading", content: Fragment.from(s.text("a"))),
            try s.node("paragraph", content: Fragment.from(s.text("b"))),
            try s.node("paragraph", content: Fragment.from(s.text("c"))),
        ]))
        try expect(canJoin(d2, 6), "two paragraphs")
    }

    // joinPoint only joins non-textblocks: two paragraphs are joined by
    // deleting, not by a structural join point.
    test("mutation: joinPoint skips textblocks") {
        let d = doc(p("a"), p("b")).node
        try expectNil(joinPoint(d, 3))
        try expectNil(joinPoint(d, 3, 1))
        // Two blockquotes do have one.
        let q = doc(blockquote(p("a")), blockquote(p("b"))).node
        try expectEqual(joinPoint(q, 5), 5)
    }

    // Searching forward, the child that would be removed by the join is the
    // one *after* the boundary — `qa qb*` can lose a `qb`, never its `qa`.
    test("mutation: joinPoint forward checks the node after the boundary") {
        let s = joinSchema
        let para = { (t: String) in try s.node("paragraph", content: Fragment.from(s.text(t))) }
        let d = try s.node("qdoc", content: Fragment.from([
            try s.node("qa", content: Fragment.from(try para("x"))),
            try s.node("qb", content: Fragment.from(try para("y"))),
        ]))
        // 3 is the end of "x"; forward, the boundary after qa is 5.
        try expectEqual(joinPoint(d, 3, 1), 5)
        try expectEqual(joinPoint(d, 8, -1), 5, "backward from inside qb")
    }

    test("mutation: canSplit refuses inside an isolating textblock") {
        let s = joinSchema
        let d = try s.node("doc", content: Fragment.from([
            try s.node("heading", content: Fragment.from(s.text("a"))),
            try s.node("iso", content: Fragment.from(s.text("bc"))),
        ]))
        try expect(!canSplit(d, 5))
        let d2 = try s.node("doc", content: Fragment.from([
            try s.node("heading", content: Fragment.from(s.text("a"))),
            try s.node("paragraph", content: Fragment.from(s.text("bc"))),
        ]))
        try expect(canSplit(d2, 5))
    }

    // MARK: Fitter

    // Upstream's "adds an image to a figure" / "adds a caption to a figure",
    // with the open side swapped: a node open at its start but closed at its
    // end has the end of its content filled in when it is placed.
    test("mutation: replace fills the end of a node closed at the end but open at the start") {
        let s = figureSchema
        let empty = try s.node("doc", content: Fragment.from(try s.node("para")))
        let slice = Slice(content: Fragment.from(try s.node("figure", content: Fragment.from(try s.node("caption")))), openStart: 1, openEnd: 0)
        let tr = Transform(empty)
        try tr.replace(0, 0, slice)
        let figure = try s.node("figure", content: Fragment.from([try s.node("caption"), try s.node("figureimage")]))
        try expectEqual(tr.doc, try s.node("doc", content: Fragment.from([figure, try s.node("para")])))
    }

    // Pasting marked text into a code block drops the marks the block doesn't
    // allow, rather than failing.
    test("mutation: replace strips marks the target block disallows") {
        let d = doc(pre("ab")).node
        let slice = Slice(content: Fragment.from(p(em("x")).node), openStart: 1, openEnd: 1)
        let tr = Transform(d)
        try tr.replace(2, 2, slice)
        try expectEqual(tr.doc, doc(pre("axb")).node)
    }

    // A slice cut from inside a caption holds a figure open on both sides
    // with only its caption in it. Placed between blocks, the figure gets its
    // missing leading block filled in — and when the fitter then closes it,
    // it must not *also* append a block behind the caption. The frontier's
    // match for that figure is the content expression's start state (the
    // slice's figure alone can't be matched), so filling from it re-adds what
    // the start fill already supplied. Upstream prosemirror-transform fills
    // here unconditionally; ProseKit checks the content it actually placed.
    test("mutation: closing a figure placed from a caption slice adds nothing after the caption") {
        let s = captionFigureSchema
        let caption = try s.node("figcaption", content: Fragment.from(s.text("c")))
        let slice = Slice(content: Fragment.from(try s.node("figure", content: Fragment.from(caption))), openStart: 2, openEnd: 2)
        let para = try s.node("para", content: Fragment.from(s.text("x")))
        let tr = Transform(try s.node("doc", content: Fragment.from(para)))
        try tr.replace(0, 0, slice)
        let figure = try s.node("figure", content: Fragment.from([try s.node("para"), caption]))
        try expectEqual(tr.doc, try s.node("doc", content: Fragment.from([figure, para])))
        try tr.doc.check()
    }
}
