import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import TestHarness

// Ported from prosemirror-commands/test/test-commands.ts — the `splitBlock`
// cases that need a schema the shared test builder doesn't have. Between them
// they cover what a split has to decide: which type the new block gets when the
// original type isn't allowed twice, what happens to the empty block a split at
// the start leaves behind, and how many levels a split has to cut through when
// the cursor is inside an inline node.

private func splitAt(_ schema: Schema, _ d: Node, _ pos: Int, _ command: Command = splitBlock) -> (doc: Node, applied: Bool) {
    var state = EditorState.create(EditorStateConfig(schema: schema, doc: d, selection: TextSelection.create(d, pos)))
    let applied = command(state, { tr in state = state.apply(tr) }, nil)
    return (state.doc, applied)
}

// The basic schema with a heading that may only open the document, plus an
// inline node to put a cursor inside.
private let headingFirstSchema: Schema = {
    let nodes: [(String, NodeSpec)] = [
        ("doc", NodeSpec(content: "heading block*")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        // Deliberately *not* in the `block` group, and so allowed only where
        // `doc` names it outright: as the document's first child. Upstream's
        // test schema gets this by replacing the heading spec wholesale.
        ("heading", NodeSpec(content: "inline*")),
        ("span", NodeSpec(content: "inline*", group: "inline", inline: true)),
        ("text", NodeSpec(group: "inline")),
    ]
    return try! Schema(nodes: nodes, marks: [], topNode: "doc")
}()

private func hDoc(_ text: String = "foobar") -> Node {
    let s = headingFirstSchema
    return try! s.node("doc", [:], content: Fragment.from(
        try! s.node("heading", [:], content: Fragment.from(s.text(text)))))
}

func registerSplitBlockSchemaTests() {
    let s = headingFirstSchema

    test("PM cmd splitBlock: splits a paragraph from a heading when a double heading isn't allowed") {
        let out = splitAt(s, hDoc(), 4)
        try expectEqual(out.doc, try! s.node("doc", [:], content: Fragment.from([
            try! s.node("heading", [:], content: Fragment.from(s.text("foo"))),
            try! s.node("paragraph", [:], content: Fragment.from(s.text("bar"))),
        ])))
        try expect(out.applied)
    }

    test("PM cmd splitBlock: won't try to reset the type of an empty leftover when the schema forbids it") {
        // Splitting at the start would rather leave a paragraph behind, but a
        // paragraph can't be the document's first child here, so the empty
        // heading stays a heading.
        let out = splitAt(s, hDoc(), 1)
        try expectEqual(out.doc, try! s.node("doc", [:], content: Fragment.from([
            try! s.node("heading", [:]),
            try! s.node("paragraph", [:], content: Fragment.from(s.text("foobar"))),
        ])))
    }

    test("PM cmd splitBlock: can split an inline node") {
        let d = try! s.node("doc", [:], content: Fragment.from(
            try! s.node("heading", [:], content: Fragment.from(
                try! s.node("span", [:], content: Fragment.from(s.text("abcd")))))))
        let out = splitAt(s, d, 4)
        try expectEqual(out.doc, try! s.node("doc", [:], content: Fragment.from([
            try! s.node("heading", [:], content: Fragment.from(
                try! s.node("span", [:], content: Fragment.from(s.text("ab"))))),
            try! s.node("paragraph", [:], content: Fragment.from(
                try! s.node("span", [:], content: Fragment.from(s.text("cd"))))),
        ])))
    }

    test("PM cmd splitBlock: prefers textblocks") {
        let s = try! Schema(nodes: [
            ("doc", NodeSpec(content: "para* section*")),
            ("section", NodeSpec(content: "para+")),
            ("para", NodeSpec(content: "text*")),
            ("text", NodeSpec()),
        ], marks: [], topNode: "doc")
        let d = try! s.node("doc", [:], content: Fragment.from(
            try! s.node("para", [:], content: Fragment.from(s.text("hello")))))
        let out = splitAt(s, d, 3)
        try expectEqual(out.doc, try! s.node("doc", [:], content: Fragment.from([
            try! s.node("para", [:], content: Fragment.from(s.text("he"))),
            try! s.node("para", [:], content: Fragment.from(s.text("llo"))),
        ])))
    }

    test("PM cmd splitBlock: returns false and changes nothing when no split is possible") {
        // The document holds exactly one paragraph, so there is nowhere for the
        // split-off half to go.
        let s = try! Schema(nodes: [
            ("doc", NodeSpec(content: "para")),
            ("para", NodeSpec(content: "text*")),
            ("text", NodeSpec()),
        ], marks: [], topNode: "doc")
        let d = try! s.node("doc", [:], content: Fragment.from(
            try! s.node("para", [:], content: Fragment.from(s.text("hello")))))
        let out = splitAt(s, d, 3)
        try expect(!out.applied, "splitBlock should report that it did nothing")
        try expectEqual(out.doc, d)
    }

    test("PM cmd splitBlock: an impossible split reports false to a dispatch-less caller too") {
        let s = try! Schema(nodes: [
            ("doc", NodeSpec(content: "para")),
            ("para", NodeSpec(content: "text*")),
            ("text", NodeSpec()),
        ], marks: [], topNode: "doc")
        let d = try! s.node("doc", [:], content: Fragment.from(
            try! s.node("para", [:], content: Fragment.from(s.text("hello")))))
        let state = EditorState.create(EditorStateConfig(schema: s, doc: d, selection: TextSelection.create(d, 3)))
        try expect(!splitBlock(state, nil, nil), "a query should answer the same as a run")
    }
}

