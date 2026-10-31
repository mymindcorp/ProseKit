import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCollab
import EditorHistory
import TestHarness

private let graphemeSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("paragraph", NodeSpec(content: "inline*", group: "block")),
    ("text", NodeSpec(group: "inline")),
], marks: [("bold", MarkSpec())], topNode: "doc")

private func oneParagraph(_ text: String) -> Node {
    try! graphemeSchema.node("doc", [:], content: Fragment.from([
        try! graphemeSchema.node("paragraph", [:], content: Fragment.from([graphemeSchema.text(text)])),
    ]))
}

private func insertion(_ pos: Int, _ text: String) -> ReplaceStep {
    ReplaceStep(pos, pos, Slice(content: Fragment.from([graphemeSchema.text(text)]), openStart: 0, openEnd: 0))
}

private func collabState(_ text: String) -> EditorState {
    EditorState.create(EditorStateConfig(schema: graphemeSchema, doc: oneParagraph(text), plugins: [history(), collab(clientID: 1)]))
}

func registerMergedGraphemeTests() {
    test("merged grapheme: a raw step that would lie about its size is refused") {
        try expect(insertion(2, "\u{301}").apply(oneParagraph("e")).failed != nil)
    }

    test("merged grapheme: a transform widens the insert, so map and inverse hold") {
        let start = oneParagraph("e")
        let tr = Transform(start)
        try tr.step(insertion(2, "\u{301}"))
        try expectEqual(tr.doc.textContent, "e\u{301}")
        try expectEqual(tr.mapping.map(2, 1), 2)
        try expect(tr.steps[0].invert(start).apply(tr.doc).doc == start)
    }

    test("merged grapheme: a mark change that would merge text is refused") {
        let split = try! graphemeSchema.node("doc", [:], content: Fragment.from([
            try! graphemeSchema.node("paragraph", [:], content: Fragment.from([
                graphemeSchema.text("e", [graphemeSchema.marks["bold"]!.create()]), graphemeSchema.text("\u{301}"),
            ])),
        ]))
        try expect(AddMarkStep(1, 3, graphemeSchema.marks["bold"]!.create()).apply(split).failed != nil)
    }

    test("merged grapheme: undo after typing a mark restores the text") {
        var s = EditorState.create(EditorStateConfig(schema: graphemeSchema, doc: oneParagraph("world"), plugins: [history()]))
        s = s.apply(s.tr.setSelection(TextSelection.create(s.doc, 1)))
        for text in ["e", "\u{301}", "x"] {
            let tr = s.tr
            try tr.insertText(text, s.selection.from)
            s = s.apply(tr)
        }
        try expectEqual(s.doc.textContent, "e\u{301}xworld")
        _ = undo(s) { s = s.apply($0) }
        try expectEqual(s.doc.textContent, "world")
    }

    test("merged grapheme: receiving under an unconfirmed mark doesn't double it") {
        var s = collabState("e")
        let tr = s.tr
        try tr.insertText("\u{301}", 2)
        s = s.apply(tr)
        s = s.apply(receiveTransaction(s, [insertion(1, "X")], [2]))
        try expectEqual(s.doc.textContent, "Xe\u{301}")
    }

    test("merged grapheme: a remote delete under two unconfirmed marks doesn't crash") {
        var s = collabState("e")
        for _ in 0..<2 {
            let tr = s.tr
            try tr.insertText("\u{301}", 2)
            s = s.apply(tr)
        }
        s = s.apply(receiveTransaction(s, [ReplaceStep(1, 2, .empty)], [2]))
        try expect(s.doc.content.size >= 2)
    }

    test("rebase: redo restores a mark undone before a remote edit") {
        var s = collabState("hello")
        let tr = s.tr
        try tr.addMark(1, 6, graphemeSchema.marks["bold"]!.create())
        s = s.apply(tr)
        _ = undo(s) { s = s.apply($0) }
        s = s.apply(receiveTransaction(s, [insertion(1, "X")], [2]))
        _ = redo(s) { s = s.apply($0) }
        try expect(s.doc.rangeHasMark(2, 7, graphemeSchema.marks["bold"]!), "redo did not restore the bold")
    }

    test("rebase: redo restores a same-size replace undone before a remote edit") {
        var s = collabState("hello")
        let tr = s.tr
        tr.maybeStep(ReplaceStep(1, 2, Slice(content: Fragment.from([graphemeSchema.text("J")]), openStart: 0, openEnd: 0)))
        s = s.apply(tr)
        _ = undo(s) { s = s.apply($0) }
        s = s.apply(receiveTransaction(s, [insertion(6, "!")], [2]))
        _ = redo(s) { s = s.apply($0) }
        try expectEqual(s.doc.textContent, "Jello!")
    }
}
