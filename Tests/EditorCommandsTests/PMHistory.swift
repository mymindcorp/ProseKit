import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorHistory
import TestHarness

// Ported from prosemirror-history/test/test-history.ts — undo/redo grouping.

private func mkState(_ d: TaggedNode? = nil, _ options: HistoryOptions = HistoryOptions()) -> EditorState {
    EditorState.create(EditorStateConfig(schema: basicSchema, doc: d?.node, plugins: [history(options)]))
}
private func typeText(_ state: EditorState, _ text: String) -> EditorState {
    state.apply(try! state.tr.insertText(text))
}
private func command(_ state: EditorState, _ cmd: (EditorState, ((Transaction) -> Void)?) -> Bool) -> EditorState {
    var s = state
    _ = cmd(s, { tr in s = s.apply(tr) })
    return s
}

func registerPMHistoryTests() {
    test("PM history: enables undo") {
        var s = mkState()
        s = typeText(s, "a"); s = typeText(s, "b")
        try expectEqual(s.doc, doc(p("ab")).node)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p()).node)
    }
    test("PM history: enables redo") {
        var s = mkState()
        s = typeText(s, "a"); s = typeText(s, "b")
        s = command(s, undo); try expectEqual(s.doc, doc(p()).node)
        s = command(s, redo); try expectEqual(s.doc, doc(p("ab")).node)
    }
    test("PM history: tracks multiple levels of history") {
        var s = mkState()
        s = typeText(s, "a"); s = typeText(s, "b")
        s = s.apply(try! s.tr.insertText("c", 1))
        try expectEqual(s.doc, doc(p("cab")).node)
        s = command(s, undo); try expectEqual(s.doc, doc(p("ab")).node)
        s = command(s, undo); try expectEqual(s.doc, doc(p()).node)
        s = command(s, redo); try expectEqual(s.doc, doc(p("ab")).node)
        s = command(s, redo); try expectEqual(s.doc, doc(p("cab")).node)
        s = command(s, undo); try expectEqual(s.doc, doc(p("ab")).node)
    }
    test("PM history: starts a new event when newGroupDelay elapses") {
        var s = mkState(nil, HistoryOptions(newGroupDelay: 1000))
        let t1 = try! s.tr.insertText("a"); t1.time = 1000; s = s.apply(t1)
        let t2 = try! s.tr.insertText("b"); t2.time = 1600; s = s.apply(t2)
        try expectEqual(undoDepth(s), 1)
        let t3 = try! s.tr.insertText("c"); t3.time = 2700; s = s.apply(t3)
        try expectEqual(undoDepth(s), 2)
    }
    test("PM history: starts a new event for non-adjacent changes") {
        var s = mkState(doc(p("abc")), HistoryOptions(newGroupDelay: 1000))
        s = s.apply(try! s.tr.insertText("x", 1))
        s = s.apply(try! s.tr.insertText("y", 5))
        try expectEqual(undoDepth(s), 2)
    }
    test("PM history: doesn't get confused by non-replacement steps when checking adjacency") {
        var s = mkState(doc(p()), HistoryOptions(newGroupDelay: 1000))
        let t1 = try! s.tr.insertText("x", 1); try t1.addMark(1, 2, basicSchema.mark("em")); s = s.apply(t1)
        let t2 = try! s.tr.insertText("y", 2); try t2.addMark(2, 3, basicSchema.mark("em")); s = s.apply(t2)
        try expectEqual(undoDepth(s), 1)
    }
    test("PM history: allows changes that aren't part of the history") {
        var s = mkState()
        s = typeText(s, "hello")
        s = s.apply(try! s.tr.insertText("oops", 1).setMeta("addToHistory", false))
        s = s.apply(try! s.tr.insertText("!", 10).setMeta("addToHistory", false))
        s = command(s, undo)
        try expectEqual(s.doc, doc(p("oops!")).node)
    }
    test("PM history: doesn't get confused by an undo not adding any redo item") {
        var s = mkState()
        s = s.apply(try! s.tr.insertText("foo"))
        s = s.apply(try! s.tr.replaceWith(1, 4, basicSchema.text("bar")).setMeta("addToHistory", false))
        s = command(s, undo)
        s = command(s, redo)
        try expectEqual(s.doc, doc(p("bar")).node)
    }
    test("PM history: supports querying for the undo and redo depth") {
        var s = mkState()
        s = typeText(s, "a")
        try expectEqual(undoDepth(s), 1); try expectEqual(redoDepth(s), 0)
        s = s.apply(try! s.tr.insertText("b", 1).setMeta("addToHistory", false))
        try expectEqual(undoDepth(s), 1); try expectEqual(redoDepth(s), 0)
        s = command(s, undo)
        try expectEqual(undoDepth(s), 0); try expectEqual(redoDepth(s), 1)
        s = command(s, redo)
        try expectEqual(undoDepth(s), 1); try expectEqual(redoDepth(s), 0)
    }
    test("PM history: all functions gracefully handle EditorStates without history") {
        let s = EditorState.create(EditorStateConfig(schema: basicSchema))
        try expectEqual(undoDepth(s), 0); try expectEqual(redoDepth(s), 0)
        try expect(undo(s, nil) == false)
        try expect(redo(s, nil) == false)
    }
    test("PM history: supports transactions with multiple steps") {
        var s = mkState()
        s = s.apply(try! { let tr = try s.tr.insertText("a"); return try tr.insertText("b") }())
        s = s.apply(try! s.tr.insertText("c", 1))
        try expectEqual(s.doc, doc(p("cab")).node)
        s = command(s, undo); try expectEqual(s.doc, doc(p("ab")).node)
        s = command(s, undo); try expectEqual(s.doc, doc(p()).node)
        s = command(s, redo); try expectEqual(s.doc, doc(p("ab")).node)
        s = command(s, redo); try expectEqual(s.doc, doc(p("cab")).node)
        s = command(s, undo); try expectEqual(s.doc, doc(p("ab")).node)
    }
}
