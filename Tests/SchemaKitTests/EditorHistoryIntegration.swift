import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorHistory
import SchemaKit
import TestHarness

// Undo/redo through the `Editor` facade. The engine itself is covered by the
// ported ProseMirror suite (EditorCommandsTests/PMHistory.swift); what is tested
// here is the wiring `Editor` adds on top:
//
//   * the content-loading APIs opt out of history (`addToHistory: false`), so a
//     stray Cmd-Z can never undo a document *load* back to empty,
//   * `init` primes `appendTransaction` plugins with a seed that must not land
//     in history as a bogus first undo step,
//   * `history: false` drops the plugin and the undo/redo keymap entirely.

func registerEditorHistoryIntegrationTests() {
    // MARK: - Loading content is not undoable

    test("history: a freshly loaded document has nothing to undo") {
        // The init-time priming seed must not register as an undo step, or every
        // loaded document would open with one bogus Cmd-Z available.
        let editor = try Editor(extensions: starterKit())
        try editor.setContent(html: "<p>loaded</p>")
        try expectEqual(undoDepth(editor.state), 0, "loading content is not an edit")
        try expect(!key(editor, "Mod-z"), "there should be nothing to undo")
        try expect(editor.getText().contains("loaded"), "got: \(editor.getText())")
    }

    test("history: setContent(_:) is not undoable") {
        let editor = try Editor(extensions: starterKit())
        let s = editor.schema
        let doc = try s.node("doc", [:], content: .from([
            try s.node("paragraph", [:], content: .from([s.text("replaced")])),
        ]))
        editor.setContent(doc)
        try expectEqual(undoDepth(editor.state), 0)
    }

    test("history: clearContent() is not undoable") {
        let editor = try Editor(extensions: starterKit())
        try editor.setContent(html: "<p>something</p>")
        editor.clearContent()
        try expect(editor.isEmpty, "expected an empty document")
        try expectEqual(undoDepth(editor.state), 0, "clearing is not an undoable edit")
    }

    test("history: undo after a load stops at the loaded content") {
        // The guarantee a host actually depends on: edits made after a load are
        // undoable, but undo bottoms out at the loaded document rather than
        // erasing it.
        let editor = try Editor(extensions: starterKit())
        try editor.setContent(html: "<p>loaded</p>")
        let loaded = editor.getText()

        let tr = editor.state.tr
        try tr.insertText(" and edited", 7)
        editor.dispatch(tr)
        try expect(editor.getText() != loaded, "the edit should have changed the text")

        try expect(key(editor, "Mod-z"), "the edit is undoable")
        try expectEqual(editor.getText(), loaded, "undo returns to the loaded content")
        try expect(!key(editor, "Mod-z"), "and stops there — a load is not undoable")
        try expectEqual(editor.getText(), loaded, "the loaded document survives")
    }

    // MARK: - The keymap Editor installs

    test("history: Mod-z undoes and Mod-y redoes through the editor keymap") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        try expectEqual(undoDepth(editor.state), 1)

        try expect(key(editor, "Mod-z"))
        try expectEqual(editor.getText(), "", "undo emptied the document")
        try expectEqual(redoDepth(editor.state), 1)

        try expect(key(editor, "Mod-y"))
        try expectEqual(editor.getText(), "hello", "redo restored it")
        try expectEqual(redoDepth(editor.state), 0)
    }

    test("history: Shift-Mod-z is an alias for redo") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        try expect(key(editor, "Mod-z"))
        try expect(key(editor, "Shift-Mod-z"))
        try expectEqual(editor.getText(), "hello")
    }

    // MARK: - history: false

    test("history: the plugin and its keymap are absent when history is off") {
        let editor = try Editor(extensions: starterKit(), history: false)
        try type(editor, "hello")
        try expectEqual(undoDepth(editor.state), 0, "no history state is tracked")
        try expect(!key(editor, "Mod-z"), "Mod-z is unbound without history")
        try expectEqual(editor.getText(), "hello", "the edit stands")
    }
}
