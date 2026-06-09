import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import TestHarness

// Ported from prosemirror-commands/test/test-commands.ts. Each `run` builds a
// state with the `<a>`/`<b>` selection, runs the command, and checks the doc (and
// the resulting selection when the expected doc carries an `<a>` tag).

private func selFor(_ d: TaggedNode) -> Selection {
    if let a = d.tags["a"] {
        let r = d.node.resolve(a)
        if r.parent.inlineContent { return TextSelection.create(d.node, a, d.tags["b"]) }
        return NodeSelection.create(d.node, a)
    }
    return Selection.atStart(d.node)
}
private func mkState(_ d: TaggedNode) -> EditorState {
    EditorState.create(EditorStateConfig(schema: basicSchema, doc: d.node, selection: selFor(d)))
}
private func run(_ d: TaggedNode, _ command: Command, _ result: TaggedNode?) throws {
    var state = mkState(d)
    _ = command(state, { tr in state = state.apply(tr) }, nil)
    try expectEqual(state.doc, (result ?? d).node)
    if let result, result.tags["a"] != nil {
        try expect(state.selection.eq(selFor(result)), "selection mismatch")
    }
}

private func bq(_ name: String) -> NodeType { basicSchema.nodes[name]! }
private func mk(_ name: String) -> MarkType { basicSchema.marks[name]! }

func registerPMCommandsTests() {
    func c(_ name: String, _ body: @escaping @Sendable () throws -> Void) { test("PM cmd \(name)") { try body() } }

    // MARK: joinBackward
    c("joinBackward: can join paragraphs") { try run(doc(p("hi"), p("<a>there")), joinBackward, doc(p("hithere"))) }
    c("joinBackward: can join out of a nested node") { try run(doc(p("hi"), blockquote(p("<a>there"))), joinBackward, doc(p("hi"), p("there"))) }
    c("joinBackward: moves a block into an adjacent wrapper") { try run(doc(blockquote(p("hi")), p("<a>there")), joinBackward, doc(blockquote(p("hi"), p("there")))) }
    c("joinBackward: moves a block into an adjacent wrapper from another wrapper") { try run(doc(blockquote(p("hi")), blockquote(p("<a>there"))), joinBackward, doc(blockquote(p("hi"), p("there")))) }
    c("joinBackward: joins the wrapper to a subsequent one if applicable") { try run(doc(blockquote(p("hi")), p("<a>there"), blockquote(p("x"))), joinBackward, doc(blockquote(p("hi"), p("there"), p("x")))) }
    c("joinBackward: moves a block into a list item") { try run(doc(ul(li(p("hi"))), p("<a>there")), joinBackward, doc(ul(li(p("hi")), li(p("there"))))) }
    c("joinBackward: joins lists") { try run(doc(ul(li(p("hi"))), ul(li(p("<a>there")))), joinBackward, doc(ul(li(p("hi")), li(p("there"))))) }
    c("joinBackward: joins list items") { try run(doc(ul(li(p("hi")), li(p("<a>there")))), joinBackward, doc(ul(li(p("hi"), p("there"))))) }
    c("joinBackward: lifts out of a list at the start") { try run(doc(ul(li(p("<a>there")))), joinBackward, doc(p("<a>there"))) }
    c("joinBackward: joins lists before and after") { try run(doc(ul(li(p("hi"))), p("<a>there"), ul(li(p("x")))), joinBackward, doc(ul(li(p("hi")), li(p("there")), li(p("x"))))) }
    c("joinBackward: deletes leaf nodes before") { try run(doc(hr(), p("<a>there")), joinBackward, doc(p("there"))) }
    c("joinBackward: lifts before it deletes") { try run(doc(hr(), blockquote(p("<a>there"))), joinBackward, doc(hr(), p("there"))) }
    c("joinBackward: does nothing at start of doc") { try run(doc(p("<a>foo")), joinBackward, nil) }
    c("joinBackward: doesn't join surrounding nodes of different types") { try run(doc(ul(li(p("a"))), p("<a>"), ol(li(p("b")))), joinBackward, doc(ul(li(p("a")), li(p("<a>"))), ol(li(p("b"))))) }

    // MARK: selectNodeBackward
    c("selectNodeBackward: selects the node before the cut") { try run(doc(blockquote(p("a")), blockquote(p("<a>b"))), selectNodeBackward, doc("<a>", blockquote(p("a")), blockquote(p("b")))) }
    c("selectNodeBackward: does nothing when not at the start of the textblock") { try run(doc(p("a<a>b")), selectNodeBackward, nil) }

    // MARK: deleteSelection
    c("deleteSelection: deletes part of a text node") { try run(doc(p("f<a>o<b>o")), deleteSelection, doc(p("fo"))) }
    c("deleteSelection: can delete across blocks") { try run(doc(p("f<a>oo"), p("ba<b>r")), deleteSelection, doc(p("fr"))) }
    c("deleteSelection: deletes node selections") { try run(doc(p("foo"), "<a>", hr()), deleteSelection, doc(p("foo"))) }
    c("deleteSelection: moves selection after deleted node") { try run(doc(p("a"), "<a>", p("b"), blockquote(p("c"))), deleteSelection, doc(p("a"), blockquote(p("<a>c")))) }
    c("deleteSelection: moves selection before deleted node at end") { try run(doc(p("a"), "<a>", p("b")), deleteSelection, doc(p("a<a>"))) }

    // MARK: joinForward
    c("joinForward: joins two textblocks") { try run(doc(p("foo<a>"), p("bar")), joinForward, doc(p("foobar"))) }
    c("joinForward: keeps type of second node when first is empty") { try run(doc(p("x"), p("<a>"), h1("hi")), joinForward, doc(p("x"), h1("<a>hi"))) }
    c("joinForward: clears nodes from joined node that wouldn't be allowed") { try run(doc(pre("foo<a>"), p("bar", img())), joinForward, doc(pre("foo<a>bar"))) }
    c("joinForward: does nothing at the end of the document") { try run(doc(p("foo<a>")), joinForward, nil) }
    c("joinForward: deletes a leaf node after the current block") { try run(doc(p("foo<a>"), hr(), p("bar")), joinForward, doc(p("foo"), p("bar"))) }
    c("joinForward: pulls the next block into the current list item") { try run(doc(ul(li(p("a<a>")), li(p("b")))), joinForward, doc(ul(li(p("a"), p("b"))))) }
    c("joinForward: joins two blocks inside of a list item") { try run(doc(ul(li(p("a<a>"), p("b")))), joinForward, doc(ul(li(p("ab"))))) }
    c("joinForward: pulls the next block into a blockquote") { try run(doc(blockquote(p("foo<a>")), p("bar")), joinForward, doc(blockquote(p("foo<a>"), p("bar")))) }
    c("joinForward: joins two blockquotes") { try run(doc(blockquote(p("hi<a>")), blockquote(p("there"))), joinForward, doc(blockquote(p("hi"), p("there")))) }
    c("joinForward: pulls the next block outside of a wrapping blockquote") { try run(doc(p("foo<a>"), blockquote(p("bar"))), joinForward, doc(p("foo"), p("bar"))) }
    c("joinForward: joins two lists") { try run(doc(ul(li(p("hi<a>"))), ul(li(p("there")))), joinForward, doc(ul(li(p("hi")), li(p("there"))))) }
    c("joinForward: does nothing in a nested node at the end of the document") { try run(doc(ul(li(p("there<a>")))), joinForward, nil) }
    c("joinForward: deletes a leaf node at the end of the document") { try run(doc(p("there<a>"), hr()), joinForward, doc(p("there"))) }
    c("joinForward: moves before it deletes a leaf node") { try run(doc(blockquote(p("there<a>")), hr()), joinForward, doc(blockquote(p("there"), hr()))) }
    c("joinForward: does nothing when it can't join") { try run(doc(p("foo<a>"), ul(li(p("bar"), ul(li(p("baz")))))), joinForward, nil) }

    // MARK: selectNodeForward
    c("selectNodeForward: does nothing at end of document") { try run(doc(p("foo<a>")), selectNodeForward, nil) }

    // MARK: joinUp
    c("joinUp: joins identical parent blocks") { try run(doc(blockquote(p("foo")), blockquote(p("<a>bar"))), joinUp, doc(blockquote(p("foo"), p("<a>bar")))) }
    c("joinUp: does nothing in the first block") { try run(doc(blockquote(p("<a>foo")), blockquote(p("bar"))), joinUp, nil) }
    c("joinUp: joins lists") { try run(doc(ul(li(p("foo"))), ul(li(p("<a>bar")))), joinUp, doc(ul(li(p("foo")), li(p("bar"))))) }
    c("joinUp: joins list items") { try run(doc(ul(li(p("foo")), li(p("<a>bar")))), joinUp, doc(ul(li(p("foo"), p("bar"))))) }
    c("joinUp: doesn't look at ancestors when a block is selected") { try run(doc(ul(li(p("foo")), li("<a>", p("bar")))), joinUp, nil) }
    c("joinUp: can join selected block nodes") { try run(doc(ul(li(p("foo")), "<a>", li(p("bar")))), joinUp, doc(ul("<a>", li(p("foo"), p("bar"))))) }

    // MARK: joinDown
    c("joinDown: joins parent blocks") { try run(doc(blockquote(p("foo<a>")), blockquote(p("bar"))), joinDown, doc(blockquote(p("foo<a>"), p("bar")))) }
    c("joinDown: doesn't join with the block before") { try run(doc(blockquote(p("foo")), blockquote(p("<a>bar"))), joinDown, nil) }
    c("joinDown: joins lists") { try run(doc(ul(li(p("foo<a>"))), ul(li(p("bar")))), joinDown, doc(ul(li(p("foo")), li(p("bar"))))) }
    c("joinDown: joins list items") { try run(doc(ul(li(p("<a>foo")), li(p("bar")))), joinDown, doc(ul(li(p("foo"), p("bar"))))) }
    c("joinDown: doesn't look at parent nodes of a selected node") { try run(doc(ul(li("<a>", p("foo")), li(p("bar")))), joinDown, nil) }
    c("joinDown: can join selected nodes") { try run(doc(ul("<a>", li(p("foo")), li(p("bar")))), joinDown, doc(ul("<a>", li(p("foo"), p("bar"))))) }

    // MARK: lift
    c("lift: lifts out of a parent block") { try run(doc(blockquote(p("<a>foo"))), lift, doc(p("<a>foo"))) }
    c("lift: splits the parent block when necessary") { try run(doc(blockquote(p("foo"), p("<a>bar"), p("baz"))), lift, doc(blockquote(p("foo")), p("bar"), blockquote(p("baz")))) }
    c("lift: can lift out of a list") { try run(doc(ul(li(p("<a>foo")))), lift, doc(p("foo"))) }
    c("lift: does nothing for a top-level block") { try run(doc(p("<a>foo")), lift, nil) }
    c("lift: lifts out of the innermost parent") { try run(doc(blockquote(ul(li(p("foo<a>"))))), lift, doc(blockquote(p("foo<a>")))) }
    c("lift: can lift a node selection") { try run(doc(blockquote("<a>", ul(li(p("foo"))))), lift, doc("<a>", ul(li(p("foo"))))) }
    c("lift: lifts out of a nested list") { try run(doc(ul(li(p("one"), ul(li(p("<a>sub1")), li(p("sub2")))), li(p("two")))), lift, doc(ul(li(p("one"), p("<a>sub1"), ul(li(p("sub2")))), li(p("two"))))) }

    // MARK: wrapIn
    c("wrapIn: can wrap a paragraph") { try run(doc(p("fo<a>o")), wrapIn(bq("blockquote")), doc(blockquote(p("foo")))) }
    c("wrapIn: wraps multiple paragraphs") { try run(doc(p("fo<a>o"), p("bar"), p("ba<b>z"), p("quux")), wrapIn(bq("blockquote")), doc(blockquote(p("foo"), p("bar"), p("baz")), p("quux"))) }
    c("wrapIn: wraps an already wrapped node") { try run(doc(blockquote(p("fo<a>o"))), wrapIn(bq("blockquote")), doc(blockquote(blockquote(p("foo"))))) }
    c("wrapIn: can wrap a node selection") { try run(doc("<a>", ul(li(p("foo")))), wrapIn(bq("blockquote")), doc(blockquote(ul(li(p("foo")))))) }

    // MARK: splitBlock
    c("splitBlock: splits a paragraph at the end") { try run(doc(p("foo<a>")), splitBlock, doc(p("foo"), p())) }
    c("splitBlock: split a paragraph in the middle") { try run(doc(p("foo<a>bar")), splitBlock, doc(p("foo"), p("bar"))) }
    c("splitBlock: splits a paragraph from a heading") { try run(doc(h1("foo<a>")), splitBlock, doc(h1("foo"), p())) }
    c("splitBlock: splits a heading in two when in the middle") { try run(doc(h1("foo<a>bar")), splitBlock, doc(h1("foo"), h1("bar"))) }
    c("splitBlock: deletes selected content") { try run(doc(p("fo<a>ob<b>ar")), splitBlock, doc(p("fo"), p("ar"))) }
    c("splitBlock: splits a parent block when a node is selected") { try run(doc(ol(li(p("a")), "<a>", li(p("b")), li(p("c")))), splitBlock, doc(ol(li(p("a"))), ol(li(p("b")), li(p("c"))))) }
    c("splitBlock: doesn't split the parent block when at the start") { try run(doc(ol("<a>", li(p("a")), li(p("b")), li(p("c")))), splitBlock, nil) }

    // MARK: liftEmptyBlock
    c("liftEmptyBlock: splits the parent block when there are siblings before") { try run(doc(blockquote(p("foo"), p("<a>"), p("bar"))), liftEmptyBlock, doc(blockquote(p("foo")), blockquote(p(), p("bar")))) }
    c("liftEmptyBlock: lifts the last child out of its parent") { try run(doc(blockquote(p("foo"), p("<a>"))), liftEmptyBlock, doc(blockquote(p("foo")), p())) }
    c("liftEmptyBlock: lifts an only child") { try run(doc(blockquote(p("foo")), blockquote(p("<a>"))), liftEmptyBlock, doc(blockquote(p("foo")), p("<a>"))) }
    c("liftEmptyBlock: does not violate schema constraints") { try run(doc(ul(li(p("<a>foo"), blockquote(p("bar"))))), liftEmptyBlock, nil) }
    c("liftEmptyBlock: lifts out of a list") { try run(doc(ul(li(p("hi")), li(p("<a>")))), liftEmptyBlock, doc(ul(li(p("hi"))), p())) }

    // MARK: createParagraphNear
    c("createParagraphNear: creates a paragraph before a selected node at the start") { try run(doc("<a>", hr(), hr()), createParagraphNear, doc(p(), hr(), hr())) }
    c("createParagraphNear: creates a paragraph after a lone selected node") { try run(doc("<a>", hr()), createParagraphNear, doc(hr(), p())) }
    c("createParagraphNear: creates a paragraph after selected nodes not at the start") { try run(doc(p(), "<a>", hr()), createParagraphNear, doc(p(), hr(), p())) }

    // MARK: setBlockType
    c("setBlockType: can change the type of a paragraph") { try run(doc(p("fo<a>o")), setBlockType(bq("heading"), ["level": .int(1)]), doc(h1("foo"))) }
    c("setBlockType: can change the type of a code block") { try run(doc(pre("fo<a>o")), setBlockType(bq("heading"), ["level": .int(1)]), doc(h1("foo"))) }
    c("setBlockType: can make a heading into a paragraph") { try run(doc(h1("fo<a>o")), setBlockType(bq("paragraph")), doc(p("foo"))) }
    c("setBlockType: preserves marks") { try run(doc(h1("fo<a>o", em("bar"))), setBlockType(bq("paragraph")), doc(p("foo", em("bar")))) }
    c("setBlockType: acts on node selections") { try run(doc("<a>", h1("foo")), setBlockType(bq("paragraph")), doc(p("foo"))) }
    c("setBlockType: can make a block a code block") { try run(doc(h1("fo<a>o")), setBlockType(bq("code_block")), doc(pre("foo"))) }
    c("setBlockType: clears marks when necessary") { try run(doc(p("fo<a>o", em("bar"))), setBlockType(bq("code_block")), doc(pre("foobar"))) }
    c("setBlockType: acts on multiple blocks when possible") { try run(doc(p("a<a>bc"), p("def"), ul(li(p("ghi"), p("jk<b>l")))), setBlockType(bq("code_block")), doc(pre("a<a>bc"), pre("def"), ul(li(p("ghi"), pre("jk<b>l"))))) }
    c("setBlockType: returns false when all textblocks are already this type") { try run(doc(pre("a<a>bc"), pre("de<b>f")), setBlockType(bq("code_block")), nil) }
    c("setBlockType: returns false when the selected blocks can't be changed") { try run(doc(ul(p("a<a>b<b>c"), p("def"))), setBlockType(bq("code_block")), nil) }

    // MARK: selectParentNode
    c("selectParentNode: selects the whole textblock") { try run(doc(ul(li(p("foo"), p("b<a>ar")), li(p("baz")))), selectParentNode, doc(ul(li(p("foo"), "<a>", p("bar")), li(p("baz"))))) }
    c("selectParentNode: goes one level up when on a block") { try run(doc(ul(li(p("foo"), "<a>", p("bar")), li(p("baz")))), selectParentNode, doc(ul("<a>", li(p("foo"), p("bar")), li(p("baz"))))) }
    c("selectParentNode: goes further up") { try run(doc(ul("<a>", li(p("foo"), p("bar")), li(p("baz")))), selectParentNode, doc("<a>", ul(li(p("foo"), p("bar")), li(p("baz"))))) }
    c("selectParentNode: stops at the top level") { try run(doc("<a>", ul(li(p("foo"), p("bar")), li(p("baz")))), selectParentNode, doc("<a>", ul(li(p("foo"), p("bar")), li(p("baz"))))) }

    // MARK: toggleMark
    c("toggleMark: can add a mark") { try run(doc(p("one <a>two<b>")), toggleMark(mk("em")), doc(p("one ", em("two")))) }
    c("toggleMark: can stack marks") { try run(doc(p("one <a>tw", strong("o<b>"))), toggleMark(mk("em")), doc(p("one ", em("tw", strong("o"))))) }
    c("toggleMark: can remove marks") { try run(doc(p(em("one <a>two<b>"))), toggleMark(mk("em")), doc(p(em("one "), "two"))) }
    c("toggleMark: skips whitespace at selection ends when adding marks") { try run(doc(p("one<a> two  <b>three")), toggleMark(mk("em")), doc(p("one ", em("two"), "  three"))) }
    c("toggleMark: doesn't skip whitespace-only selections") { try run(doc(p("one<a> <b>two")), toggleMark(mk("em")), doc(p("one", em(" "), "two"))) }

    c("toggleMark: can toggle pending marks") {
        var state = mkState(doc(p("hell<a>o")))
        _ = toggleMark(mk("em"))(state, { tr in state = state.apply(tr) }, nil)
        try expectEqual(state.storedMarks?.count, 1)
        _ = toggleMark(mk("strong"))(state, { tr in state = state.apply(tr) }, nil)
        try expectEqual(state.storedMarks?.count, 2)
        _ = toggleMark(mk("em"))(state, { tr in state = state.apply(tr) }, nil)
        try expectEqual(state.storedMarks?.count, 1)
    }
}
