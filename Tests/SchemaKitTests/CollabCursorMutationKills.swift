import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

// The collab-cursor cases only follow a collapsed cursor's head. These pin the
// anchor's own mapping and the clamping of out-of-range positions.

func registerCollabCursorMutationKillTests() {
    test("collab cursor kills: a ranged cursor maps its anchor as well as its head") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hello world")
        editor.setCollabCursor(id: "a", anchor: 3, head: 7, color: "#FF3B30", label: "Ada")
        let tr = editor.state.tr
        try tr.insertText("XXX", 1)
        editor.dispatch(tr)
        let cursor = editor.collabCursors.first
        try expectEqual(editor.collabCursors.count, 1)
        try expectEqual(cursor?.anchor, 6)
        try expectEqual(cursor?.head, 10)
        try expectEqual(cursor?.color, "#FF3B30")
        try expectEqual(cursor?.label, "Ada")
    }

    test("collab cursor kills: positions are clamped into the document on both sides") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hello")
        let size = editor.doc.content.size
        editor.setCollabCursor(id: "a", anchor: size + 50, head: -5, color: "#000000", label: "A")
        var cursor = editor.collabCursors.first
        try expectEqual(editor.collabCursors.count, 1)
        try expectEqual(cursor?.anchor, size)
        try expectEqual(cursor?.head, 0)
        editor.setCollabCursor(id: "a", anchor: -3, head: size + 1, color: "#000000", label: "A")
        cursor = editor.collabCursors.first
        try expectEqual(cursor?.anchor, 0)
        try expectEqual(cursor?.head, size)
    }
}
