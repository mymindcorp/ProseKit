import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

// Registered into the shared `collector` from main.swift.

@Sendable func editorWith(_ text: String) throws -> Editor {
    let e = try Editor(extensions: fullKit())
    try type(e, text)
    return e
}

func registerSearchTests() {
    test("search: setSearch produces matches and highlight decorations") {
        let editor = try editorWith("the cat sat on the mat")
        editor.setSearch("the")
        try expectEqual(editor.searchMatches.count, 2)
        // The search plugin should emit highlight decorations.
        var decoCount = 0
        for plugin in editor.state.plugins {
            if let provider = plugin.props?.decorations, let set = provider(editor.state) {
                decoCount += set.find().count
            }
        }
        try expectEqual(decoCount, 2)
    }

    test("search: findNext moves the selection through matches") {
        let editor = try editorWith("ab ab ab")
        editor.setSearch("ab")
        editor.findNext()
        let first = editor.state.selection
        try expectEqual(first.from, 1)
        try expectEqual(first.to, 3)
        editor.findNext()
        try expectEqual(editor.state.selection.from, 4)
    }

    test("search: replaceAll replaces every match") {
        let editor = try editorWith("foo foo foo")
        editor.setSearch("foo")
        let n = editor.replaceAllMatches(with: "bar")
        try expectEqual(n, 3)
        try expectEqual(editor.doc.textContent, "bar bar bar")
    }

    test("search: replaceCurrentMatch replaces only the current match") {
        let editor = try editorWith("x x x")
        editor.setSearch("x")
        editor.findNext() // current = index 0
        try expect(editor.replaceCurrentMatch(with: "y"))
        try expectEqual(editor.doc.textContent, "y x x")
    }

    test("search: replaceCurrentMatch before Find-next replaces the first (no crash)") {
        let editor = try editorWith("x x x")
        editor.setSearch("x") // currentIndex is -1 ("before first match")
        try expectEqual(editor.searchState?.currentIndex, -1)
        try expect(editor.replaceCurrentMatch(with: "y")) // used to index matches[-1]
        try expectEqual(editor.doc.textContent, "y x x")
    }

    test("search: clearSearch removes matches") {
        let editor = try editorWith("hello hello")
        editor.setSearch("hello")
        try expectEqual(editor.searchMatches.count, 2)
        editor.clearSearch()
        try expectEqual(editor.searchMatches.count, 0)
    }
}
