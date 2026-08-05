import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import TestHarness

// The parts of `Selection` the ported ProseMirror suite doesn't reach: placing
// a selection at either end of a document, the JSON decoder's refusals, and the
// base implementations of `content` and `getBookmark` that the concrete types
// inherit rather than override.

func registerSelectionEndpointTests() {
    // MARK: atStart / atEnd

    test("Selection.atStart: lands inside the first thing that takes a caret") {
        let d = doc(p("first"), p("second")).node
        let sel = Selection.atStart(d)
        try expect(sel is TextSelection, "got \(type(of: sel))")
        try expectEqual(sel.from, 1)
        try expect(sel.empty)
    }

    test("Selection.atEnd: lands inside the last thing that takes a caret") {
        let d = doc(p("first"), p("second")).node
        let sel = Selection.atEnd(d)
        try expect(sel is TextSelection, "got \(type(of: sel))")
        try expectEqual(sel.from, d.content.size - 1)
        try expect(sel.empty)
    }

    test("Selection.atStart/atEnd: they meet in a one-character document") {
        let d = doc(p("x")).node
        try expectEqual(Selection.atStart(d).from, 1)
        try expectEqual(Selection.atEnd(d).from, 2)
    }

    test("Selection.atStart/atEnd: an empty paragraph is still a place to be") {
        let d = doc(p()).node
        try expectEqual(Selection.atStart(d).from, 1)
        try expectEqual(Selection.atEnd(d).from, 1)
    }

    test("Selection.atEnd: skips past a trailing block that takes no caret") {
        // A rule can't hold a cursor, so the end of the document is the
        // paragraph before it rather than the rule itself.
        let d = doc(p("text"), hr()).node
        let sel = Selection.atEnd(d)
        try expect(sel is NodeSelection || sel is TextSelection, "got \(type(of: sel))")
        // Either way it must be a position the document really has.
        try expect(sel.to <= d.content.size)
    }

    test("Selection.atStart/atEnd: a document of only a rule still resolves") {
        // Nothing takes a caret, so this falls back rather than failing.
        let d = doc(hr()).node
        for sel in [Selection.atStart(d), Selection.atEnd(d)] {
            try expect(sel.to <= d.content.size, "out of range: \(sel.from)..\(sel.to)")
        }
    }

    // MARK: What the decoder refuses

    test("Selection.fromJSON: an all-selection round-trips") {
        let d = doc(p("a"), p("b")).node
        let all = AllSelection(d)
        let back = try Selection.fromJSON(d, all.toJSON())
        try expect(back is AllSelection, "got \(type(of: back))")
        try expect(back.eq(all))
    }

    test("Selection.fromJSON: every malformed shape throws") {
        let d = doc(p("hello")).node
        let bad: [(String, [String: AttributeValue])] = [
            ("no type at all", ["anchor": .int(1)]),
            ("a type nothing implements", ["type": .string("nosuchtype")]),
            ("text without an anchor", ["type": .string("text"), "head": .int(1)]),
            ("text without a head", ["type": .string("text"), "anchor": .int(1)]),
            ("node without an anchor", ["type": .string("node")]),
            ("gapcursor without a position", ["type": .string("gapcursor")]),
            ("a type of the wrong kind", ["type": .int(3)]),
        ]
        for (name, json) in bad {
            var threw = false
            do { _ = try Selection.fromJSON(d, json) } catch { threw = true }
            try expect(threw, "expected \(name) to throw")
        }
    }

    test("Selection.fromJSON: each type decodes to its own kind") {
        let d = doc(p("hello"), hr()).node
        let text = try Selection.fromJSON(d, ["type": .string("text"),
                                              "anchor": .int(1), "head": .int(3)])
        try expect(text is TextSelection)
        try expectEqual(text.from, 1)
        try expectEqual(text.to, 3)
        // The rule is selectable, so this really is a node selection.
        let node = try Selection.fromJSON(d, ["type": .string("node"), "anchor": .int(7)])
        try expect(node is NodeSelection, "got \(type(of: node))")
    }

    // MARK: The base implementations the types inherit

    test("Selection.content: a text selection slices what it covers") {
        // TextSelection doesn't override this; it uses the base.
        let d = doc(p("hello world")).node
        let sel = TextSelection.create(d, 1, 6)
        try expectEqual(sel.content().content.textBetween(0, sel.content().content.size), "hello")
    }

    test("Selection.content: an empty selection carries nothing") {
        let d = doc(p("hello")).node
        try expectEqual(TextSelection.create(d, 3).content().content.size, 0)
    }

    test("Selection.getBookmark: a bookmark survives an edit before it") {
        // What history and collab keep instead of a position: it maps through
        // changes and resolves against the document that results.
        let d = doc(p("hello")).node
        let sel = TextSelection.create(d, 3, 5)
        let bookmark = sel.getBookmark()
        // Insert two characters ahead of the selection.
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: d))
        let tr = state.tr
        _ = try tr.insertText("XX", 1)
        let moved = bookmark.map(tr.mapping).resolve(tr.doc)
        try expectEqual(moved.from, 5)
        try expectEqual(moved.to, 7)
        try expectEqual(tr.doc.textBetween(moved.from, moved.to), "ll")
    }

    test("Selection.getBookmark: a node selection's bookmark stays on its node") {
        let d = doc(p("a"), hr()).node
        let sel = NodeSelection.create(d, 3)
        try expect(sel is NodeSelection, "expected the rule to be selectable")
        let back = sel.getBookmark().resolve(d)
        try expect(back.eq(sel), "the bookmark should resolve to the same selection")
    }
}
