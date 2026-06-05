import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

// Registered into the shared `collector` from main.swift.

func registerTypographyTests() {
    test("typography: opening double quote at the start") {
        let editor = try Editor(extensions: starterKit())
        try expect(textInput(editor, at: 1, "\""))
        try expectEqual(editor.doc.textContent, "\u{201C}")
    }

    test("typography: closing double quote after a letter") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hi")
        try expect(textInput(editor, at: editor.doc.content.size - 1, "\""))
        try expectEqual(editor.doc.textContent, "hi\u{201D}")
    }

    test("typography: em-dash and ellipsis") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "a-")
        try expect(textInput(editor, at: editor.doc.content.size - 1, "-"))
        try expectEqual(editor.doc.textContent, "a\u{2014}")

        let editor2 = try Editor(extensions: starterKit())
        try type(editor2, "x..")
        try expect(textInput(editor2, at: editor2.doc.content.size - 1, "."))
        try expectEqual(editor2.doc.textContent, "x\u{2026}")
    }

    test("markdown shortcut: **bold** marks the inner text and strips the asterisks") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "**bold*")           // one closing star already typed
        try expect(textInput(editor, at: editor.doc.content.size - 1, "*"))  // type the final star
        try expectEqual(editor.doc.textContent, "bold")
        try expect(editor.isActive(mark: "bold"))
    }

    test("markdown shortcut: *italic* does not fire inside **bold**") {
        // Typing the first closing star of bold must not trigger italic.
        let editor = try Editor(extensions: starterKit())
        try type(editor, "**bold")
        // typing one '*' (now "**bold*") should NOT produce an italic mark
        _ = textInput(editor, at: editor.doc.content.size - 1, "*")
        try expect(!editor.isActive(mark: "italic"))
    }

    test("markdown shortcut: `code` strips the backticks") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "`x")
        try expect(textInput(editor, at: editor.doc.content.size - 1, "`"))
        try expectEqual(editor.doc.textContent, "x")
        try expect(editor.isActive(mark: "code"))
    }

    test("typography: apostrophe inside a word is a closing quote") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "don")
        try expect(textInput(editor, at: editor.doc.content.size - 1, "'"))
        try expectEqual(editor.doc.textContent, "don\u{2019}")
    }
}
