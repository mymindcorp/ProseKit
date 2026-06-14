import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

// Subscript / superscript (mutually exclusive) and text / background color marks.

private func colorAttr(_ editor: Editor, _ markName: String) -> String? {
    guard let type = editor.schema.marks[markName] else { return nil }
    var found: String?
    editor.doc.descendants { node, _, _, _ in
        if let m = node.marks.first(where: { $0.type === type }) { found = m.attrs["color"]?.stringValue }
        return true
    }
    return found
}

func registerMarksParityTests() {
    test("marks: subscript/superscript/textColor/backgroundColor are registered") {
        let editor = try Editor(extensions: starterKit())
        for name in ["subscript", "superscript", "textColor", "backgroundColor"] {
            try expectNotNil(editor.schema.marks[name])
        }
    }

    test("subscript: toggleSubscript applies then removes the mark") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.run("toggleSubscript"))
        try expect(editor.isActive(mark: "subscript"))
        try expect(editor.run("toggleSubscript"))
        try expect(!editor.isActive(mark: "subscript"))
    }

    test("subscript/superscript are mutually exclusive") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.run("toggleSubscript"))
        try expect(editor.isActive(mark: "subscript"))
        // Applying superscript over the same range removes the subscript.
        try expect(editor.run("toggleSuperscript"))
        try expect(editor.isActive(mark: "superscript"))
        try expect(!editor.isActive(mark: "subscript"))
    }

    test("superscript: Mod-. toggles the mark") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(key(editor, "Mod-."))
        try expect(editor.isActive(mark: "superscript"))
    }

    test("textColor: setTextColor sets the color attr, nil removes it") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.setTextColor("#ff0000"))
        try expect(editor.isActive(mark: "textColor"))
        try expectEqual(colorAttr(editor, "textColor"), "#ff0000")
        try expect(editor.setTextColor(nil))
        try expect(!editor.isActive(mark: "textColor"))
    }

    test("textColor: a new color replaces the previous one") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.setTextColor("red"))
        try expect(editor.setTextColor("blue"))
        try expectEqual(colorAttr(editor, "textColor"), "blue")
    }

    test("backgroundColor: setBackgroundColor sets the color attr") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.setBackgroundColor("yellow"))
        try expect(editor.isActive(mark: "backgroundColor"))
        try expectEqual(colorAttr(editor, "backgroundColor"), "yellow")
    }
}
