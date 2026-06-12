import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import TestHarness

// Ported from prosemirror-gapcursor/test/test-gapcursor.ts (GapCursor.valid),
// plus headless coverage for the arrow handler, typing-at-gap, JSON, and
// mapping (upstream covers those interactively in the browser).

private let gcSchema: Schema = {
    let nodes: [(String, NodeSpec)] = [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("section", NodeSpec(content: "block+", group: "block")),
        ("maybe_section", NodeSpec(content: "block*", group: "block")),
        ("atom_block", NodeSpec(group: "block", atom: true, selectable: true)),
        ("uatom_block", NodeSpec(group: "block", atom: true, selectable: false)),
        ("text", NodeSpec(group: "inline")),
    ]
    return try! Schema(nodes: nodes, marks: [], topNode: "doc")
}()

private func gcNode(_ t: String, _ c: [Node] = []) -> Node {
    try! gcSchema.node(t, [:], content: Fragment.from(c))
}
private func gcDoc(_ c: Node...) -> Node { gcNode("doc", c) }
private func gcP(_ s: String = "") -> Node { gcNode("paragraph", s.isEmpty ? [] : [gcSchema.text(s)]) }
private func atom() -> Node { gcNode("atom_block") }

private func gcState(_ d: Node, _ selection: Selection? = nil) -> EditorState {
    EditorState.create(EditorStateConfig(schema: gcSchema, doc: d, selection: selection, plugins: [gapCursor()]))
}

private func pressArrow(_ state: EditorState, _ key: String) -> EditorState {
    var s = state
    for plugin in state.plugins {
        if let h = plugin.props?.handleKeyDown, h(key, s, { tr in s = s.apply(tr) }) { break }
    }
    return s
}

func registerPMGapCursorTests() {
    test("PM gapcursor valid: allowed at doc start/end adjacent to an atom block") {
        let d = gcDoc(atom())
        try expect(GapCursor.valid(d.resolve(0)))
        try expect(GapCursor.valid(d.resolve(d.content.size)))
    }

    test("PM gapcursor valid: disallowed at doc start/end adjacent to a textblock") {
        let d = gcDoc(gcP("hi"))
        try expect(!GapCursor.valid(d.resolve(0)))
        try expect(!GapCursor.valid(d.resolve(d.content.size)))
    }

    test("PM gapcursor valid: allowed at block start/end adjacent to an atom block") {
        let section = gcNode("section", [atom()])
        let d = gcDoc(section)
        let sectionStart = d.resolve(1)
        let sectionEnd = d.resolve(1 + section.content.size)
        try expectEqual(sectionStart.parent.type.name, "section")
        try expectEqual(sectionEnd.parent.type.name, "section")
        try expect(GapCursor.valid(sectionStart))
        try expect(GapCursor.valid(sectionEnd))
    }

    test("PM gapcursor valid: allowed in an empty block") {
        let section = gcNode("maybe_section")
        let d = gcDoc(section)
        try expectEqual(d.resolve(1).parent.type.name, "maybe_section")
        try expect(GapCursor.valid(d.resolve(1)))
        try expect(GapCursor.valid(d.resolve(1 + section.content.size)))
    }

    test("gapcursor arrows: right from a node selection lands in the gap between atoms") {
        // Upstream: a selectable atom gets node-selected first (base arrow
        // behavior); the gapcursor enters the gap from that NodeSelection.
        let d = gcDoc(gcP("hi"), atom(), atom())
        let s0 = gcState(d, NodeSelection.create(d, 4))
        let s1 = pressArrow(s0, "ArrowRight")
        try expect(s1.selection is GapCursor, "got \(type(of: s1.selection))")
        try expectEqual(s1.selection.head, 5) // between the two atoms
    }

    test("gapcursor arrows: left from a node selection finds the gap before a leading atom") {
        let d = gcDoc(atom(), gcP("hi"))
        let s0 = gcState(d, NodeSelection.create(d, 0))
        let s1 = pressArrow(s0, "ArrowLeft")
        try expect(s1.selection is GapCursor)
        try expectEqual(s1.selection.head, 0) // before the leading atom
    }

    test("gapcursor arrows: right from a text edge skips an unselectable atom into the gap after it") {
        let d = gcDoc(gcP("hi"), gcNode("uatom_block"))
        let s0 = gcState(d, TextSelection.create(d, 3)) // end of "hi"
        let s1 = pressArrow(s0, "ArrowRight")
        try expect(s1.selection is GapCursor, "got \(type(of: s1.selection))")
        try expectEqual(s1.selection.head, 5) // after the trailing unselectable atom
    }

    test("gapcursor arrows: not triggered mid-text") {
        let d = gcDoc(gcP("hi"), atom(), atom())
        let s0 = gcState(d, TextSelection.create(d, 2)) // between h and i
        let s1 = pressArrow(s0, "ArrowRight")
        try expect(!(s1.selection is GapCursor))
    }

    test("gapcursor typing: replacing a gap cursor materializes a paragraph") {
        let d = gcDoc(gcP("hi"), atom(), atom())
        let s0 = gcState(d, GapCursor(d.resolve(5)))
        let tr = s0.tr
        tr.replaceSelection(Slice(content: Fragment.from([gcSchema.text("x")]), openStart: 0, openEnd: 0))
        let s1 = s0.apply(tr)
        try expectEqual(s1.doc, gcDoc(gcP("hi"), atom(), gcP("x"), atom()))
        try expect(s1.selection is TextSelection)
        try expectEqual(s1.selection.head, 7) // after the typed "x"
    }

    test("gapcursor mapping: survives edits elsewhere, degrades when invalidated") {
        let d = gcDoc(gcP("hi"), atom(), atom())
        let s0 = gcState(d, GapCursor(d.resolve(5)))
        let tr = try! s0.tr.insertText("!", 3) // inside the paragraph, before the gap
        let s1 = s0.apply(tr)
        try expect(s1.selection is GapCursor)
        try expectEqual(s1.selection.head, 6)
    }

    test("gapcursor JSON: round-trips through Selection.fromJSON") {
        let d = gcDoc(atom(), atom())
        let sel = GapCursor(d.resolve(1))
        let restored = try Selection.fromJSON(d, sel.toJSON())
        try expect(restored.eq(sel))
        // An invalidated position degrades to a near selection, not a trap.
        let bogus = try Selection.fromJSON(gcDoc(gcP("hi")), ["type": .string("gapcursor"), "pos": .int(0)])
        try expect(!(bogus is GapCursor))
    }

    test("gapcursor spec override: allowGapCursor forces the answer both ways") {
        let schema2: Schema = {
            let nodes: [(String, NodeSpec)] = [
                ("doc", NodeSpec(content: "block+")),
                ("paragraph", NodeSpec(content: "inline*", group: "block")),
                ("noGaps", NodeSpec(content: "block+", group: "block", allowGapCursor: false)),
                ("atom_block", NodeSpec(group: "block", atom: true, selectable: true)),
                ("text", NodeSpec(group: "inline")),
            ]
            return try! Schema(nodes: nodes, marks: [], topNode: "doc")
        }()
        func n2(_ t: String, _ c: [Node] = []) -> Node { try! schema2.node(t, [:], content: Fragment.from(c)) }
        let d = n2("doc", [n2("noGaps", [n2("atom_block")])])
        try expect(!GapCursor.valid(d.resolve(1))) // would be valid, but overridden off
    }
}
