import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import TestHarness

// Ported from prosemirror-state/test/test-selection.ts (+ the TestState helper
// from state.ts). Exercises selection tracking across edits, NodeSelection
// replace/delete behavior, stored-mark preservation, and TextSelection.between.

private func selFor(_ d: TaggedNode) -> Selection {
    if let a = d.tags["a"] {
        let resolved = d.node.resolve(a)
        if resolved.parent.inlineContent {
            return TextSelection.create(d.node, a, d.tags["b"])
        }
        return NodeSelection.create(d.node, a)
    }
    return Selection.atStart(d.node)
}

private final class TestState {
    var state: EditorState
    init(_ d: TaggedNode, _ selection: Selection? = nil) {
        state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: d.node, selection: selection ?? selFor(d)))
    }
    func apply(_ tr: Transaction) { state = state.apply(tr) }
    func textSel(_ anchor: Int, _ head: Int? = nil) { apply(state.tr.setSelection(TextSelection.create(state.doc, anchor, head))) }
    func nodeSel(_ pos: Int) { apply(state.tr.setSelection(NodeSelection.create(state.doc, pos))) }
    func deleteSelection() { apply(state.tr.deleteSelection()) }
    var doc: Node { state.doc }
    var selection: Selection { state.selection }
    var tr: Transaction { state.tr }
}

func registerPMSelectionTests() {
    test("PM sel: should follow changes") {
        let s = TestState(doc(p("hi")))
        s.apply(try s.tr.insertText("xy", 1)); try expectEqual(s.selection.head, 3); try expectEqual(s.selection.anchor, 3)
        s.apply(try s.tr.insertText("zq", 1)); try expectEqual(s.selection.head, 5); try expectEqual(s.selection.anchor, 5)
        s.apply(try s.tr.insertText("uv", 7)); try expectEqual(s.selection.head, 5); try expectEqual(s.selection.anchor, 5)
    }

    test("PM sel: should move after inserted content") {
        let s = TestState(doc(p("hi"))); s.textSel(2, 3)
        s.apply(try s.tr.insertText("o")); try expectEqual(s.selection.head, 3); try expectEqual(s.selection.anchor, 3)
    }

    test("PM sel: moves after an inserted leaf node") {
        let s = TestState(doc(p("foobar"))); s.textSel(4)
        s.apply(s.tr.replaceSelectionWith(try! basicSchema.node("horizontal_rule")))
        try expectEqual(s.doc, doc(p("foo"), hr(), p("bar")).node); try expectEqual(s.selection.head, 7)
        s.textSel(10)
        s.apply(s.tr.replaceSelectionWith(try! basicSchema.node("horizontal_rule")))
        try expectEqual(s.doc, doc(p("foo"), hr(), p("bar"), hr()).node); try expectEqual(s.selection.from, 11)
    }

    test("PM sel: allows typing over a leaf node") {
        let s = TestState(doc(p("a"), "<a>", hr(), p("b"))); s.nodeSel(3)
        s.apply(s.tr.replaceSelectionWith(basicSchema.text("x")))
        try expectEqual(s.doc, doc(p("a"), p("x"), p("b")).node); try expectEqual(s.selection.head, 5); try expectEqual(s.selection.anchor, 5)
    }

    test("PM sel: allows deleting a selected block") {
        let s = TestState(doc(p("foo"), ul(li(p("bar")), li(p("baz")), li(p("quux")))))
        s.nodeSel(0); s.deleteSelection(); try expectEqual(s.doc, doc(ul(li(p("bar")), li(p("baz")), li(p("quux")))).node); try expectEqual(s.selection.head, 3)
        s.nodeSel(2); s.deleteSelection(); try expectEqual(s.doc, doc(ul(li(p("baz")), li(p("quux")))).node); try expectEqual(s.selection.head, 3)
        s.nodeSel(9); s.deleteSelection(); try expectEqual(s.doc, doc(ul(li(p("baz")))).node); try expectEqual(s.selection.head, 6)
        s.nodeSel(0); s.deleteSelection(); try expectEqual(s.doc, doc(p()).node)
    }

    test("PM sel: preserves the marks of a deleted selection") {
        let s = TestState(doc(p("foo", em("<a>bar<b>"), "baz"))); s.deleteSelection()
        try expectEqual(s.state.storedMarks?.count, 1)
    }
    test("PM sel: doesn't preserve non-inclusive marks of a deleted selection") {
        let s = TestState(doc(p("foo", a(em("<a>bar<b>")), "baz"))); s.deleteSelection()
        try expectEqual(s.state.storedMarks?.count, 1)
    }
    test("PM sel: doesn't preserve marks when deleting a selection at the end of a block") {
        let s = TestState(doc(p("foo", em("bar<a>")), p("b<b>az"))); s.deleteSelection()
        try expect(s.state.storedMarks == nil)
    }
    test("PM sel: drops non-inclusive marks at the end of a deleted span when appropriate") {
        let s = TestState(doc(p("foo", a("ba", em("<a>r<b>")), "baz"))); s.deleteSelection()
        try expectEqual(s.state.storedMarks?.map { $0.type.name }.joined(separator: ","), "em")
    }
    test("PM sel: keeps non-inclusive marks when still inside them") {
        let s = TestState(doc(p("foo", a("b", em("<a>a<b>"), "r"), "baz"))); s.deleteSelection()
        try expectEqual(s.state.storedMarks?.count, 2)
    }

    test("PM sel: preserves marks when typing over marked text") {
        let s = TestState(doc(p("foo ", em("<a>bar<b>"), " baz")))
        s.apply(try s.tr.insertText("quux")); try expectEqual(s.doc, doc(p("foo ", em("quux"), " baz")).node)
        s.apply(try s.tr.insertText("bar", 5, 9)); try expectEqual(s.doc, doc(p("foo ", em("bar"), " baz")).node)
    }

    test("PM sel: allows deleting a leaf") {
        let s = TestState(doc(p("a"), hr(), hr(), p("b")))
        s.nodeSel(3); s.deleteSelection(); try expectEqual(s.doc, doc(p("a"), hr(), p("b")).node); try expectEqual(s.selection.from, 3)
        s.deleteSelection(); try expectEqual(s.doc, doc(p("a"), p("b")).node); try expectEqual(s.selection.head, 4)
    }

    test("PM sel: properly handles deleting the selection") {
        let s = TestState(doc(p("foo", img(), "bar"), blockquote(p("hi")), p("ay")))
        s.nodeSel(4); s.apply(s.tr.deleteSelection()); try expectEqual(s.doc, doc(p("foobar"), blockquote(p("hi")), p("ay")).node); try expectEqual(s.selection.head, 4)
        s.nodeSel(9); s.apply(s.tr.deleteSelection()); try expectEqual(s.doc, doc(p("foobar"), p("ay")).node); try expectEqual(s.selection.from, 9)
        s.nodeSel(8); s.apply(s.tr.deleteSelection()); try expectEqual(s.doc, doc(p("foobar")).node); try expectEqual(s.selection.from, 7)
    }

    test("PM sel: puts the cursor after the inserted text when inserting a list item") {
        let s = TestState(doc(p("<a>abc")))
        let source = doc(ul(li(p("<a>def<b>"))))
        s.apply(s.tr.replaceSelection(source.node.slice(tag(source, "a"), tag(source, "b"), includeParents: true)))
        try expectEqual(s.selection.from, 6)
    }

    test("PM sel: can replace inline selections") {
        let s = TestState(doc(p("foo", img(), "bar", img(), "baz")))
        s.nodeSel(4); s.apply(s.tr.replaceSelectionWith(try! basicSchema.node("hard_break")))
        try expectEqual(s.doc, doc(p("foo", br(), "bar", img(), "baz")).node); try expectEqual(s.selection.head, 5); try expect(s.selection.empty)
        s.nodeSel(8); s.apply(try s.tr.insertText("abc"))
        try expectEqual(s.doc, doc(p("foo", br(), "barabcbaz")).node); try expectEqual(s.selection.head, 11); try expect(s.selection.empty)
        s.nodeSel(0); s.apply(try s.tr.insertText("xyz")); try expectEqual(s.doc, doc(p("xyz")).node)
    }

    test("PM sel: can replace a block selection") {
        let s = TestState(doc(p("abc"), hr(), hr(), blockquote(p("ow"))))
        s.nodeSel(5); s.apply(s.tr.replaceSelectionWith(try! basicSchema.node("code_block")))
        try expectEqual(s.doc, doc(p("abc"), pre(), hr(), blockquote(p("ow"))).node); try expectEqual(s.selection.from, 7)
        s.nodeSel(8); s.apply(s.tr.replaceSelectionWith(try! basicSchema.node("paragraph")))
        try expectEqual(s.doc, doc(p("abc"), pre(), hr(), p()).node); try expectEqual(s.selection.from, 9)
    }


    // MARK: TextSelection.between
    test("PM between: uses arguments when possible") {
        let d = doc(p("f<a>o<b>o"))
        let s = TextSelection.between(d.node.resolve(tag(d, "b")), d.node.resolve(tag(d, "a")))
        try expectEqual(s.anchor, tag(d, "b")); try expectEqual(s.head, tag(d, "a"))
    }
    test("PM between: will adjust when necessary") {
        let d = doc("<a>", p("foo"))
        let s = TextSelection.between(d.node.resolve(tag(d, "a")), d.node.resolve(tag(d, "a")))
        try expectEqual(s.anchor, 1)
    }
    test("PM between: uses bias when adjusting") {
        let d = doc(p("foo"), "<a>", p("bar")); let pos = d.node.resolve(tag(d, "a"))
        try expectEqual(TextSelection.between(pos, pos, -1).anchor, 4)
        try expectEqual(TextSelection.between(pos, pos, 1).anchor, 6)
    }
    test("PM between: will fall back to a node selection") {
        let d = doc(hr(), "<a>")
        let s = TextSelection.between(d.node.resolve(tag(d, "a")), d.node.resolve(tag(d, "a")))
        try expect((s as? NodeSelection)?.node == d.node.firstChild)
    }
    test("PM between: will collapse towards the other argument") {
        let d = doc("<a>", p("foo"), "<b>")
        var s = TextSelection.between(d.node.resolve(tag(d, "a")), d.node.resolve(tag(d, "b")))
        try expectEqual(s.anchor, 1); try expectEqual(s.head, 4)
        s = TextSelection.between(d.node.resolve(tag(d, "b")), d.node.resolve(tag(d, "a")))
        try expectEqual(s.anchor, 4); try expectEqual(s.head, 1)
    }
}




// MARK: - Selections restored from JSON that no longer fits

/// `{"doc": …, "selection": …}` for a two-paragraph document.
private func stateJSON(_ selection: [String: AttributeValue]) -> [String: AttributeValue] {
    ["doc": .object(doc(p("hello"), p("world")).node.toJSON()),
     "selection": .object(selection)]
}

func registerSelectionJSONGuardTests() {
    test("state JSON: a text selection past the end lands at the end") {
        // A stored document, a peer's state, or the clipboard can carry a
        // selection for a document that has since been edited somewhere else.
        // `resolve` traps outside the document, so this used to be a crash on
        // open rather than a selection that needed nudging.
        let json = stateJSON(["type": .string("text"),
                              "anchor": .int(999_999), "head": .int(999_999)])
        let state = try EditorState.fromJSON(EditorStateConfig(schema: basicSchema), json)
        try expectEqual(state.selection.from, state.doc.content.size - 1)
        try expect(state.selection is TextSelection)
    }

    test("state JSON: a negative text selection lands at the start") {
        let json = stateJSON(["type": .string("text"), "anchor": .int(-50), "head": .int(-50)])
        let state = try EditorState.fromJSON(EditorStateConfig(schema: basicSchema), json)
        try expectEqual(state.selection.from, 1)
    }

    test("state JSON: one end out of range keeps the end that fits") {
        let json = stateJSON(["type": .string("text"), "anchor": .int(1), "head": .int(999_999)])
        let state = try EditorState.fromJSON(EditorStateConfig(schema: basicSchema), json)
        try expectEqual(state.selection.from, 1)
        try expectEqual(state.selection.to, state.doc.content.size - 1)
    }

    test("state JSON: a selection that does fit is left alone") {
        // The guard clamps; it doesn't move a selection that was already valid.
        let json = stateJSON(["type": .string("text"), "anchor": .int(2), "head": .int(4)])
        let state = try EditorState.fromJSON(EditorStateConfig(schema: basicSchema), json)
        try expectEqual(state.selection.from, 2)
        try expectEqual(state.selection.to, 4)
    }

    test("state JSON: every selection type survives a document it doesn't fit") {
        // The node and gap-cursor cases were already clamped; this holds the
        // whole switch to the same rule so the next case added inherits it.
        for type in ["text", "node", "gapcursor"] {
            let json = stateJSON(["type": .string(type), "anchor": .int(999_999),
                                  "head": .int(999_999), "pos": .int(999_999)])
            let state = try EditorState.fromJSON(EditorStateConfig(schema: basicSchema), json)
            try expect(state.selection.to <= state.doc.content.size, "type: \(type)")
        }
    }

    test("state JSON: a selection round-trips through JSON unchanged") {
        let original = EditorState.create(EditorStateConfig(
            schema: basicSchema, doc: doc(p("hello"), p("world")).node,
            selection: TextSelection.create(doc(p("hello"), p("world")).node, 2, 4)))
        let back = try EditorState.fromJSON(EditorStateConfig(schema: basicSchema),
                                            original.toJSON())
        try expectEqual(back.doc, original.doc)
        try expect(back.selection.eq(original.selection), "the selection should survive")
    }
}
