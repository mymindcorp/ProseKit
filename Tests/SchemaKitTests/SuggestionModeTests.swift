import DocumentModel
import EditorChangeset
import EditorHistory
import EditorStateKit
import SchemaKit
import TestHarness
import DocumentTransform

// Suggestion mode (track changes on prosemirror-changeset).

private func suggestionEditor() throws -> Editor {
    try Editor(extensions: starterKit() + [SuggestionModeExtension(author: "alice")])
}

private func state(_ editor: Editor) -> SuggestionModeState {
    suggestionModeKey.getState(editor.state)!
}

private func enable(_ editor: Editor) {
    editor.dispatch(setSuggestionMode(editor.state.tr, enabled: true))
}

/// Insert text at a document position (the shared `type` helper always
/// inserts at 1; `textInput` only fires input rules).
private func insert(_ editor: Editor, _ text: String, at pos: Int) throws {
    let tr = editor.state.tr
    try tr.insertText(text, pos)
    editor.dispatch(tr)
}

func registerSuggestionModeTests() {
    for wasEnabled in [false, true] {
        for enabled in [false, true] {
            test("suggestion: editing while setting mode from \(wasEnabled) to \(enabled) updates pending changes") {
                let editor = try suggestionEditor()
                try type(editor, "base")
                enable(editor)
                try insert(editor, "!", at: 5)
                editor.dispatch(setSuggestionMode(editor.state.tr, enabled: wasEnabled))
                let tr = try editor.state.tr.insertText("X", 1)
                editor.dispatch(setSuggestionMode(tr, enabled: enabled))
                try expectEqual(editor.doc.textContent, "Xbase!")
                try expectEqual(state(editor).enabled, enabled)
                try expect(state(editor).changes.contains { $0.fromB == 6 && $0.toB == 7 },
                    "The pending suffix must move with the inserted prefix")
                try expectEqual(state(editor).changes.count, enabled ? 2 : 1)
                try expect(editor.run(rejectAllSuggestions))
                try expectEqual(editor.doc.textContent, enabled ? "base" : "Xbase")
                try expectEqual(state(editor).changes.count, 0)
            }
    }
    }

    test("suggestion: first enable with an edit uses the edited document as its base") {
        let editor = try suggestionEditor()
        try type(editor, "base")
        editor.dispatch(setSuggestionMode(try editor.state.tr.insertText("X", 1), enabled: true))
        try expectEqual(state(editor).baseDoc, editor.doc)
        try expectEqual(state(editor).changes.count, 0)
        try insert(editor, "!", at: 6)
        try expectEqual(state(editor).changes.count, 1)
        try expect(editor.run(rejectAllSuggestions))
        try expectEqual(editor.doc.textContent, "Xbase")
    }

    test("suggestion: disabled by default, edits not recorded") {
        let editor = try suggestionEditor()
        try type(editor, "hello")
        try expect(!state(editor).enabled)
        try expectEqual(state(editor).changes.count, 0)
    }

    test("suggestion: typing while enabled records an insertion change") {
        let editor = try suggestionEditor()
        try type(editor, "hello")
        enable(editor)
        try insert(editor, " world", at: editor.doc.content.size - 1)
        let st = state(editor)
        try expectEqual(st.changes.count, 1)
        let change = st.changes[0]
        try expectEqual(change.toB - change.fromB, 6)
        try expectEqual(change.fromA, change.toA) // nothing deleted
        try expectEqual(change.inserted.first?.data, "alice")
        try expectEqual(editor.doc.textContent, "hello world")
    }

    test("suggestion: deleting while enabled records a deletion, doc loses text") {
        let editor = try suggestionEditor()
        try type(editor, "hello world")
        enable(editor)
        let tr = editor.state.tr
        try tr.delete(6, 12) // " world"
        editor.dispatch(tr)
        let st = state(editor)
        try expectEqual(editor.doc.textContent, "hello")
        try expectEqual(st.changes.count, 1)
        try expectEqual(st.deletedText(at: 0), " world")
    }

    test("suggestion: decorations mark insertions inline and deletions as widgets") {
        let editor = try suggestionEditor()
        try type(editor, "abcdef")
        enable(editor)
        let tr = editor.state.tr
        try tr.delete(2, 4) // "bc"
        editor.dispatch(tr)
        try insert(editor, "XY", at: editor.doc.content.size - 1)
        let decos = suggestionDecorations(editor.state)!.decorations
        let widget = decos.first { $0.attributes["class"] == "deletion" }
        let inline = decos.first { $0.attributes["class"] == "insertion" }
        try expectNotNil(widget)
        try expectEqual(widget?.attributes["data-text"], "bc")
        try expectNotNil(inline)
        try expectEqual(inline.map { $0.to - $0.from }, 2)
        try expectEqual(inline?.attributes["data-author"], "alice")
    }

    test("suggestion: accept keeps doc content and clears the change") {
        let editor = try suggestionEditor()
        try type(editor, "hello")
        enable(editor)
        try insert(editor, "!", at: editor.doc.content.size - 1)
        try expect(acceptSuggestion(0)(editor.state, { editor.dispatch($0) }, nil))
        try expectEqual(editor.doc.textContent, "hello!")
        try expectEqual(state(editor).changes.count, 0)
        // The base advanced: further edits diff against the accepted doc.
        try expectEqual(state(editor).baseDoc?.textContent, "hello!")
    }

    test("suggestion: reject an insertion removes it from the doc") {
        let editor = try suggestionEditor()
        try type(editor, "hello")
        enable(editor)
        try insert(editor, " world", at: editor.doc.content.size - 1)
        try expect(rejectSuggestion(0)(editor.state, { editor.dispatch($0) }, nil))
        try expectEqual(editor.doc.textContent, "hello")
        try expectEqual(state(editor).changes.count, 0)
    }

    test("suggestion: reject a deletion restores the deleted text") {
        let editor = try suggestionEditor()
        try type(editor, "hello world")
        enable(editor)
        let tr = editor.state.tr
        try tr.delete(6, 12)
        editor.dispatch(tr)
        try expectEqual(editor.doc.textContent, "hello")
        try expect(rejectSuggestion(0)(editor.state, { editor.dispatch($0) }, nil))
        try expectEqual(editor.doc.textContent, "hello world")
        try expectEqual(state(editor).changes.count, 0)
    }

    test("suggestion: accept first of two changes keeps the second consistent") {
        let editor = try suggestionEditor()
        try type(editor, "one two three")
        enable(editor)
        try insert(editor, "X", at: 4) // "oneX two three"
        try insert(editor, "Y", at: editor.doc.content.size - 1) // "...threeY"
        try expectEqual(state(editor).changes.count, 2)
        try expect(acceptSuggestion(0)(editor.state, { editor.dispatch($0) }, nil))
        try expectEqual(state(editor).changes.count, 1)
        // Rejecting the remaining change must remove Y, not corrupt the doc.
        try expect(rejectSuggestion(0)(editor.state, { editor.dispatch($0) }, nil))
        try expectEqual(editor.doc.textContent, "oneX two three")
        try expectEqual(state(editor).changes.count, 0)
    }

    test("suggestion: acceptAll and rejectAll") {
        let editor = try suggestionEditor()
        try type(editor, "base")
        enable(editor)
        try insert(editor, "A", at: 1)
        try insert(editor, "Z", at: editor.doc.content.size - 1)
        try expect(state(editor).changes.count >= 1)
        try expect(acceptAllSuggestions(editor.state, { editor.dispatch($0) }, nil))
        try expectEqual(state(editor).changes.count, 0)
        try expectEqual(editor.doc.textContent, "AbaseZ")

        try insert(editor, "Q", at: 2)
        try expectEqual(state(editor).changes.count, 1)
        try expect(rejectAllSuggestions(editor.state, { editor.dispatch($0) }, nil))
        try expectEqual(editor.doc.textContent, "AbaseZ")
        try expectEqual(state(editor).changes.count, 0)
    }

    // Wrapping a paragraph is recorded as two insertions: the blockquote's
    // opening token and its closing one. Neither can be taken out alone — the
    // schema has no way to delete half a node — so reverting them one by one
    // leaves the quote in place, and rejectAll has to finish the job by
    // restoring the whole base document.
    test("suggestion: rejectAll undoes a wrap the per-change revert can't") {
        let editor = try suggestionEditor()
        try type(editor, "ab")
        let base = editor.doc
        enable(editor)
        try expect(editor.run("toggleBlockquote"))
        try expectEqual(editor.doc.firstChild?.type.name, "blockquote")
        try expectEqual(state(editor).changes.count, 2)
        try expect(editor.run(rejectAllSuggestions))
        try expectEqual(editor.doc, base)
        try expectEqual(state(editor).changes.count, 0)
    }

    test("suggestion: toggling off keeps pending suggestions, stops recording") {
        let editor = try suggestionEditor()
        try type(editor, "hello")
        enable(editor)
        try insert(editor, "!", at: editor.doc.content.size - 1)
        editor.dispatch(setSuggestionMode(editor.state.tr, enabled: false))
        try expectEqual(state(editor).changes.count, 1)
        // An edit elsewhere while off is NOT a suggestion; it folds into the
        // base and the original suggestion survives with valid coordinates.
        try insert(editor, "Z", at: 1)
        let st = state(editor)
        try expectEqual(editor.doc.textContent, "Zhello!")
        try expectEqual(st.changes.count, 1)
        let change = st.changes[0]
        try expectEqual(editor.doc.textBetween(change.fromB, change.toB), "!")
        try expect(st.baseDoc?.textContent.contains("Z") == true)
    }

    test("suggestion: undo of a suggested edit clears the change") {
        let editor = try suggestionEditor()
        try type(editor, "hello")
        // Close the history group so undo only reverts the suggested edit.
        editor.dispatch(EditorHistory.closeHistory(editor.state.tr))
        enable(editor)
        try insert(editor, " world", at: editor.doc.content.size - 1)
        try expectEqual(state(editor).changes.count, 1)
        try expect(key(editor, "Mod-z"))
        try expectEqual(editor.doc.textContent, "hello")
        try expectEqual(state(editor).changes.count, 0)
    }

    test("suggestion: suggestionIndex finds the change at a position") {
        let editor = try suggestionEditor()
        try type(editor, "hello")
        enable(editor)
        try insert(editor, "!!", at: editor.doc.content.size - 1)
        let st = state(editor)
        let change = st.changes[0]
        try expectEqual(suggestionIndex(at: change.fromB + 1, editor.state), 0)
        try expectNil(suggestionIndex(at: 1, editor.state))
    }

    test("suggestion: replace records both deletion and insertion in one change") {
        let editor = try suggestionEditor()
        try type(editor, "hello world")
        enable(editor)
        let tr = editor.state.tr
        try tr.replaceWith(7, 12, editor.schema.text("there"))
        editor.dispatch(tr)
        let st = state(editor)
        try expectEqual(editor.doc.textContent, "hello there")
        try expectEqual(st.changes.count, 1)
        try expectEqual(st.deletedText(at: 0), "world")
        try expect(!st.changes[0].inserted.isEmpty)
    }
}
