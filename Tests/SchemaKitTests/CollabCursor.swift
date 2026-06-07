import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

func registerCollabCursorTests() {
    test("collab cursor: maps through an insertion made before it") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hello world")
        editor.setCollabCursor(id: "a", anchor: 7, head: 7, color: "#FF3B30", label: "Ada")
        try expectEqual(editor.collabCursors.first?.head, 7)
        // The local user inserts 3 characters before the remote cursor.
        let tr = editor.state.tr
        try tr.insertText("XXX", 1)
        editor.dispatch(tr)
        try expectEqual(editor.collabCursors.first?.head, 10) // 7 + 3
    }

    test("collab cursor: setting a meta cursor does not change docRevision") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hi")
        let rev = editor.docRevision
        editor.setCollabCursor(id: "a", anchor: 1, head: 1, color: "#34C759", label: "Bob")
        try expectEqual(editor.docRevision, rev) // cursor-only update, no layout invalidation
    }

    test("collab cursor: remove clears it") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hi")
        editor.setCollabCursor(id: "a", anchor: 1, head: 1, color: "#000000", label: "X")
        try expectEqual(editor.collabCursors.count, 1)
        editor.removeCollabCursor(id: "a")
        try expect(editor.collabCursors.isEmpty)
    }

    test("interleaving: an agent insert before the user's cursor shifts the user selection") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hello")
        // The user's cursor sits at the end.
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 6)))
        // The "agent" inserts text at the start, as its own transaction.
        let agent = editor.state.tr
        try agent.insertText("AGENT ", 1)
        editor.dispatch(agent)
        // Both edits coexist and the user's cursor mapped forward correctly.
        try expectEqual(editor.doc.textContent, "AGENT hello")
        try expectEqual(editor.state.selection.head, 12) // 6 + len("AGENT ")
    }

    test("interleaving: an agent insert after the user's cursor leaves it put") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hello")
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 3)))
        let agent = editor.state.tr
        try agent.insertText("!!!", 6) // after the user's cursor
        editor.dispatch(agent)
        try expectEqual(editor.state.selection.head, 3) // unchanged
        try expectEqual(editor.doc.textContent, "hello!!!")
    }
}
