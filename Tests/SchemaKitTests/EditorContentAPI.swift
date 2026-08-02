import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness
import DocumentTransform

// The Editor content-IO conveniences (getHTML/getMarkdown/getText, setContent(html:))
// and attributes(ofMark:).

func registerEditorContentAPITests() {
    test("getHTML serializes the document") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p>Hello <strong>world</strong></p>")
        let html = editor.getHTML()
        try expect(html.contains("<strong>world</strong>"), "got: \(html)")
    }

    test("setContent(html:) replaces the document and round-trips") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<h1>Title</h1><p>Body</p>")
        try expect(editor.isActive(node: "heading", attrs: ["level": .int(1)]) || editor.doc.childCount == 2)
        try expectEqual(editor.doc.child(0).type.name, "heading")
        try expectEqual(editor.doc.child(1).type.name, "paragraph")
    }

    test("getText joins block text with newlines") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p>one</p><p>two</p>")
        try expectEqual(editor.getText(), "one\ntwo")
    }

    test("getMarkdown serializes the document") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<h2>Heading</h2><p>text</p>")
        let md = editor.getMarkdown()
        try expect(md.contains("## Heading"), "got: \(md)")
    }

    test("attributes(ofMark:) returns the active link's href") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p><a href=\"https://example.com\">link</a></p>")
        // Select inside the link.
        select(editor, 2, 4)
        let attrs = editor.attributes(ofMark: "link")
        try expectEqual(attrs?["href"], .string("https://example.com"))
    }

    test("attributes(ofMark:) returns the active text color") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.setTextColor("#112233"))
        try expectEqual(editor.attributes(ofMark: "textColor")?["color"], .string("#112233"))
    }

    test("attributes(ofMark:) is nil when the mark isn't active") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "plain")
        select(editor, 1, editor.doc.content.size - 1)
        try expectNil(editor.attributes(ofMark: "textColor"))
    }

    test("isEmpty reflects document content") {
        let editor = try Editor(extensions: fullKit())
        try expect(editor.isEmpty, "a fresh editor is empty")
        try type(editor, "x")
        try expect(!editor.isEmpty, "typing makes it non-empty")
    }

    test("clearContent resets to an empty document") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<h1>Title</h1><p>body</p>")
        try expect(!editor.isEmpty)
        editor.clearContent()
        try expect(editor.isEmpty, "clearContent empties the document")
        try expectEqual(editor.getText(), "")
    }

    test("insertContent inserts a block node at a position") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p>ab</p>")
        let hr = try editor.schema.node("horizontalRule")
        try expect(editor.insertContent(hr, at: editor.doc.content.size))
        try expectEqual(editor.doc.child(editor.doc.childCount - 1).type.name, "horizontalRule")
    }

    test("insertContent(html:) inserts parsed content at the selection") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p>start</p>")
        select(editor, 6, 6) // end of "start"
        try expect(try editor.insertContent(html: "<p>more</p>"))
        try expect(editor.getText().contains("more"), "got: \(editor.getText())")
    }

    test("onSelectionUpdate fires on a selection-only change") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hello")
        let box = Counter()
        editor.onSelectionUpdate = { _ in box.n += 1 }
        select(editor, 1, 3) // selection change, no doc change
        try expectEqual(box.n, 1)
    }

    test("onSelectionUpdate does not fire when the selection is unchanged") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hello")
        select(editor, 3, 3)
        let box = Counter()
        editor.onSelectionUpdate = { _ in box.n += 1 }
        // A transaction that sets the same selection shouldn't notify.
        let tr = editor.state.tr
        tr.setSelection(TextSelection.create(tr.doc, 3))
        editor.dispatch(tr)
        try expectEqual(box.n, 0)
    }
}

private final class Counter: @unchecked Sendable { var n = 0 }
