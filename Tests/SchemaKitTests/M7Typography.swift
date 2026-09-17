import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

// Registered into the shared `collector` from main.swift.

func registerTypographyTests() {
    for (name, whitespace) in [("nonbreaking space", "\u{a0}"), ("narrow nonbreaking space", "\u{202f}"), ("em space", "\u{2003}"), ("carriage return", "\r")] {
        for single in [false, true] {
            test("typography: opening \(single ? "single" : "double") quote after \(name)") {
                let editor = try Editor(extensions: starterKit())
                try type(editor, "before" + whitespace)
                let end = editor.doc.content.size - 1
                try expect(textInput(editor, at: end, single ? "'" : "\""))
                try expectEqual(editor.doc.textContent, "before" + whitespace + (single ? "‘" : "“"))
                try editor.doc.check()
            }
        }
    }
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

    test("typography: apostrophe inside a word is a closing quote") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "don")
        try expect(textInput(editor, at: editor.doc.content.size - 1, "'"))
        try expectEqual(editor.doc.textContent, "don\u{2019}")
    }
}
