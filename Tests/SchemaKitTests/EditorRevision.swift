import Foundation
import DocumentModel
import EditorStateKit
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
}
