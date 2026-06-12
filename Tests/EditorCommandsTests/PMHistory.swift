import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorHistory
import TestHarness

// Ported from prosemirror-history/test/test-history.ts — undo/redo grouping.

private func mkState(_ d: TaggedNode? = nil, _ options: HistoryOptions = HistoryOptions(),
                     plugins extra: [Plugin] = []) -> EditorState {
    EditorState.create(EditorStateConfig(schema: basicSchema, doc: d?.node, plugins: [history(options)] + extra))
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
    @Sendable func unsyncedComplex(_ doCompress: Bool) throws {
        var s = mkState()
        s = typeText(s, "hello")
        s = s.apply(closeHistory(s.tr))
        s = typeText(s, "!")
        s = s.apply(try! s.tr.insertText("....", 1).setMeta("addToHistory", false))
        s = s.apply(try! s.tr.split(3))
        try expectEqual(s.doc, doc(p(".."), p("..hello!")).node)
        s = s.apply(try! s.tr.split(2).setMeta("addToHistory", false))
        if doCompress { _compressHistory(s) }
        s = command(s, undo)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p("."), p("...hello")).node)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p("."), p("...")).node)
    }
    test("PM history: can handle complex editing sequences") {
        try unsyncedComplex(false)
    }
    test("PM history: can handle complex editing sequences with compression") {
        try unsyncedComplex(true)
    }
    test("PM history: supports overlapping edits") {
        var s = mkState()
        s = typeText(s, "hello")
        s = s.apply(closeHistory(s.tr))
        s = s.apply(try! s.tr.delete(1, 6))
        try expectEqual(s.doc, doc(p()).node)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p("hello")).node)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p()).node)
    }
    test("PM history: supports overlapping edits that aren't collapsed") {
        var s = mkState()
        s = s.apply(try! s.tr.insertText("h", 1).setMeta("addToHistory", false))
        s = typeText(s, "ello")
        s = s.apply(closeHistory(s.tr))
        s = s.apply(try! s.tr.delete(1, 6))
        try expectEqual(s.doc, doc(p()).node)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p("hello")).node)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p("h")).node)
    }
    test("PM history: supports overlapping unsynced deletes") {
        var s = mkState()
        s = typeText(s, "hi")
        s = s.apply(closeHistory(s.tr))
        s = typeText(s, "hello")
        s = s.apply(try! s.tr.delete(1, 8).setMeta("addToHistory", false))
        try expectEqual(s.doc, doc(p()).node)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p()).node)
    }
    test("PM history: can go back and forth through history multiple times") {
        var s = mkState()
        s = typeText(s, "one")
        s = typeText(s, " two")
        s = s.apply(closeHistory(s.tr))
        s = typeText(s, " three")
        s = s.apply(try! s.tr.insertText("zero ", 1))
        s = s.apply(closeHistory(s.tr))
        s = s.apply(try! s.tr.split(1))
        s = s.apply(s.tr.setSelection(TextSelection.create(s.doc, 1)))
        s = typeText(s, "top")
        for i in 0..<6 {
            let re = i % 2 == 1
            for _ in 0..<4 { s = command(s, re ? redo : undo) }
            try expectEqual(s.doc, re ? doc(p("top"), p("zero one two three")).node : doc(p()).node)
        }
    }
    test("PM history: supports non-tracked changes next to tracked changes") {
        var s = mkState()
        s = typeText(s, "o")
        s = s.apply(try! s.tr.split(1))
        s = s.apply(try! s.tr.insertText("zzz", 4).setMeta("addToHistory", false))
        s = command(s, undo)
        try expectEqual(s.doc, doc(p("zzz")).node)
    }
    test("PM history: can go back and forth through history when preserving items") {
        // preserveItems is always on in this port.
        var s = mkState()
        s = typeText(s, "one")
        s = typeText(s, " two")
        s = s.apply(closeHistory(s.tr))
        s = s.apply(try! s.tr.insertText("xxx", s.selection.head).setMeta("addToHistory", false))
        s = typeText(s, " three")
        s = s.apply(try! s.tr.insertText("zero ", 1))
        s = s.apply(closeHistory(s.tr))
        s = s.apply(try! s.tr.split(1))
        s = s.apply(s.tr.setSelection(TextSelection.create(s.doc, 1)))
        s = typeText(s, "top")
        s = s.apply(try! s.tr.insertText("yyy", 1).setMeta("addToHistory", false))
        for i in 0..<3 {
            if i == 2 { _compressHistory(s) }
            for _ in 0..<4 { s = command(s, undo) }
            try expectEqual(s.doc, doc(p("yyyxxx")).node)
            for _ in 0..<4 { s = command(s, redo) }
            try expectEqual(s.doc, doc(p("yyytop"), p("zero one twoxxx three")).node)
        }
    }
    test("PM history: restores selection on undo") {
        var s = mkState()
        s = typeText(s, "hi")
        s = s.apply(closeHistory(s.tr))
        s = s.apply(s.tr.setSelection(TextSelection.create(s.doc, 1, 3)))
        let selection = s.selection
        s = s.apply(try! s.tr.replaceWith(selection.from, selection.to, basicSchema.text("hello")))
        let selection2 = s.selection
        s = command(s, undo)
        try expect(s.selection.eq(selection))
        s = command(s, redo)
        try expect(s.selection.eq(selection2))
    }
    test("PM history: rebases selection on undo") {
        var s = mkState()
        s = typeText(s, "hi")
        s = s.apply(closeHistory(s.tr))
        s = s.apply(s.tr.setSelection(TextSelection.create(s.doc, 1, 3)))
        s = s.apply(try! s.tr.insert(1, basicSchema.text("hello")))
        s = s.apply(try! s.tr.insert(1, basicSchema.text("---")).setMeta("addToHistory", false))
        s = command(s, undo)
        try expectEqual(s.selection.head, 6)
    }
    test("PM history: handles change overwriting in item-preserving mode") {
        var s = mkState()
        s = typeText(s, "a")
        s = typeText(s, "b")
        s = s.apply(closeHistory(s.tr))
        s = s.apply(s.tr.setSelection(TextSelection.create(s.doc, 1, 3)))
        s = typeText(s, "c")
        s = command(s, undo)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p()).node)
    }
    test("PM history: truncates history") {
        var s = mkState(nil, HistoryOptions(depth: 2))
        for i in 1..<40 {
            s = typeText(s, "a")
            s = s.apply(closeHistory(s.tr))
            try expectEqual(undoDepth(s), (i - 2) % 21 + 2)
        }
    }
    test("PM history: combines appended transactions in the event started by the base transaction") {
        let appender = Plugin(appendTransaction: { _, _, state in
            state.doc.content.size == 4 ? try! state.tr.insert(1, basicSchema.text("A")) : nil
        })
        var s = mkState(doc(p("x")), plugins: [appender])
        s = s.apply(try! s.tr.insert(2, basicSchema.text("I")))
        try expectEqual(s.doc, doc(p("AxI")).node)
        try expectEqual(undoDepth(s), 1)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p("x")).node)
    }
    test("PM history: includes transactions appended to undo in the redo history") {
        let appender = Plugin(appendTransaction: { trs, _, state in
            guard let add = trs[0].getMeta("add") as? String else { return nil }
            return try! state.tr.insert(1, basicSchema.text(add))
        })
        var s = mkState(doc(p("x")), plugins: [appender])
        s = s.apply(try! s.tr.insert(2, basicSchema.text("I")).setMeta("add", "A"))
        try expectEqual(s.doc, doc(p("AxI")).node)
        _ = undo(s) { tr in s = s.apply(tr.setMeta("add", "B")) }
        try expectEqual(s.doc, doc(p("Bx")).node)
        _ = redo(s) { tr in s = s.apply(tr.setMeta("add", "C")) }
        try expectEqual(s.doc, doc(p("CAxI")).node)
        s = command(s, undo)
        try expectEqual(s.doc, doc(p("Bx")).node)
    }
    test("PM history: doesn't close the history on appended transactions") {
        let appender = Plugin(appendTransaction: { trs, _, state in
            guard let add = trs[0].getMeta("add") as? String else { return nil }
            return try! state.tr.insert(1, basicSchema.text(add))
        })
        var s = mkState(doc(p("x")), plugins: [appender])
        s = s.apply(try! s.tr.insert(2, basicSchema.text("R")).setMeta("add", "A"))
        s = s.apply(try! s.tr.insert(3, basicSchema.text("M")))
        s = command(s, undo)
        try expectEqual(s.doc, doc(p("x")).node)
    }
    test("PM history: supports rebasing") {
        // Simulates collab: a remote step arrives under our unconfirmed step.
        var s = mkState()
        s = typeText(s, "base")
        s = s.apply(closeHistory(s.tr))
        let baseDoc = s.doc

        let rightStep = ReplaceStep(5, 5, Slice(content: Fragment.from([basicSchema.text(" right")]), openStart: 0, openEnd: 0))
        let t1 = s.tr; _ = t1.maybeStep(rightStep); s = s.apply(t1)
        try expectEqual(s.doc, doc(p("base right")).node)
        try expectEqual(undoDepth(s), 2)
        let leftStep = ReplaceStep(1, 1, Slice(content: Fragment.from([basicSchema.text("left ")]), openStart: 0, openEnd: 0))

        let tr = s.tr
        _ = tr.maybeStep(rightStep.invert(baseDoc))
        _ = tr.maybeStep(leftStep)
        _ = tr.maybeStep(rightStep.map(tr.mapping.slice(1))!)
        tr.mapping.setMirror(0, tr.steps.count - 1)
        tr.setMeta("addToHistory", false)
        tr.setMeta("rebased", 1)
        s = s.apply(tr)
        try expectEqual(s.doc, doc(p("left base right")).node)
        try expectEqual(undoDepth(s), 2)

        s = command(s, undo)
        try expectEqual(s.doc, doc(p("left base")).node)
        s = command(s, redo)
        try expectEqual(s.doc, doc(p("left base right")).node)
    }
    test("PM history: properly maps selection when rebasing") {
        var s = mkState(doc(p("123456789ABCD")))
        s = s.apply(s.tr.setSelection(TextSelection.create(s.doc, 6, 13)))
        s = s.apply(try! s.tr.delete(6, 13))
        let rebase = try! s.tr.insert(6, basicSchema.text("6789ABC"))
        _ = try! rebase.insert(14, basicSchema.text("E"))
        _ = try! rebase.delete(6, 13)
        rebase.setMeta("rebased", 1)
        rebase.setMeta("addToHistory", false)
        rebase.mapping.setMirror(0, 2)
        s = s.apply(rebase)
        s = command(s, undo) // must not trap or corrupt
    }
}
