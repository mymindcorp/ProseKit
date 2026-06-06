import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

// Tests for the `highlight` mark: schema registration, the toggle command, the
// `==text==` input rule, and that a real ProseMirror document using highlight
// (plus wiki-links, links, tasks, code) decodes against the full schema.

private func hasMark(_ editor: Editor, _ name: String) -> Bool {
    guard let type = editor.schema.marks[name] else { return false }
    return editor.doc.rangeHasMark(0, editor.doc.content.size, type)
}

/// Type `prefix` then fire `trigger` through the input-rule plugins.
@Sendable private func highlightShortcut(_ prefix: String, _ trigger: String) throws -> Editor {
    let editor = try Editor(extensions: starterKit())
    if !prefix.isEmpty { try type(editor, prefix) }
    let pos = max(1, editor.doc.content.size - 1)
    _ = textInput(editor, at: pos, trigger)
    return editor
}

func registerHighlightTests() {
    test("highlight: mark type is registered in the schema") {
        let editor = try Editor(extensions: starterKit())
        try expectNotNil(editor.schema.marks["highlight"])
    }

    test("highlight: toggleHighlight applies then removes the mark") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.run("toggleHighlight"))
        try expect(editor.isActive(mark: "highlight"))
        try expect(editor.run("toggleHighlight"))
        try expect(!editor.isActive(mark: "highlight"))
    }

    test("highlight: '==text==' input rule strips markers and highlights") {
        let editor = try highlightShortcut("==text=", "=")
        try expectEqual(editor.doc.textContent, "text")
        try expect(hasMark(editor, "highlight"))
        try expect(!hasMark(editor, "bold"))
    }

    test("highlight: Mod-Shift-h toggles the mark") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(key(editor, "Mod-Shift-h"))
        try expect(editor.isActive(mark: "highlight"))
    }

    test("highlight: the provided ProseMirror document parses against fullKit") {
        let editor = try Editor(extensions: fullKit())
        guard let url = Bundle.module.url(forResource: "highlight-doc", withExtension: "json") else {
            try expect(false, "fixture highlight-doc.json not found"); return
        }
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(AttributeValue.self, from: data)
        guard case let .object(obj) = value else {
            try expect(false, "top-level JSON is not an object"); return
        }

        let doc = try Node.fromJSON(editor.schema, obj)

        try expectEqual(doc.type.name, "doc")
        // Spot-check structure and that the highlight mark actually landed.
        try expect(doc.textContent.contains("This is a one liner headline."))
        guard let highlight = editor.schema.marks["highlight"] else {
            try expect(false, "highlight mark missing from schema"); return
        }
        try expect(doc.rangeHasMark(0, doc.content.size, highlight),
                   "expected the decoded document to carry a highlight mark")
    }
}
