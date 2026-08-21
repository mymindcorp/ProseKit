import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// `Editor.docRevision` drives the renderer's layout cache: it must change only
// when the document changes, never for selection-only transactions (else every
// caret move would invalidate the layout and rebuild it).
func registerEditorRevisionTests() {
    test("docRevision: unchanged by a selection-only transaction") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello world")
        let before = editor.docRevision
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 1)))
        try expectEqual(editor.docRevision, before)
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 1, 6)))
        try expectEqual(editor.docRevision, before)
    }

    test("docRevision: bumps when the document changes") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        let before = editor.docRevision
        try type(editor, "!")
        try expect(editor.docRevision > before)
    }

    test("docRevision: unchanged by a stored-marks-only transaction") {
        // Arming bold for the next keystroke changes neither the document nor
        // the selection — the layout it produced is still valid.
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 3, 3)
        guard let bold = editor.schema.marks["bold"] else { try expect(false, "no bold mark"); return }
        let before = editor.docRevision
        editor.dispatch(editor.state.tr.setStoredMarks([bold.create()]))
        try expectEqual(editor.docRevision, before)
    }

    test("docRevision: bumps once for a multi-step transaction") {
        // The cache key counts dispatches that changed the document, not steps.
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        let before = editor.docRevision
        let tr = editor.state.tr
        try tr.insertText("A", 1)
        try tr.insertText("B", 1)
        try expect(tr.steps.count >= 2, "expected a multi-step transaction, got \(tr.steps.count)")
        editor.dispatch(tr)
        try expectEqual(editor.docRevision, before + 1)
    }

    test("docRevision: bumps once for a chain of doc-changing commands") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, 6)
        guard let bold = editor.schema.marks["bold"],
              let italic = editor.schema.marks["italic"] else {
            try expect(false, "starterKit should carry bold and italic"); return
        }
        let before = editor.docRevision
        try expect(editor.chain([toggleMark(bold), toggleMark(italic)]))
        try expectEqual(editor.docRevision, before + 1, "a chain is one layout invalidation, not one per command")
    }

    test("docRevision: unchanged by a chain of selection-only commands") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        let before = editor.docRevision
        try expect(editor.chain([{ state, dispatch, _ in
            dispatch?(state.tr.setSelection(TextSelection.create(state.doc, 1, 3)))
            return true
        }]))
        try expectEqual(editor.docRevision, before)
    }
}
