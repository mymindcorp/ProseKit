import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

/// Where `[[` is allowed to autocomplete. Prose — paragraphs, wherever they sit
/// — offers targets; a heading is a title and code is literal text, so neither
/// does. The trigger text is still typed either way; only the popup differs.

/// Put the cursor at the end of the document's last text position and type.
private func typeAtEnd(_ editor: Editor, _ text: String) throws {
    editor.dispatch(editor.state.tr.setSelection(
        TextSelection.near(editor.doc.resolve(editor.doc.content.size), -1)))
    let tr = editor.state.tr
    let at = editor.state.selection.from
    try tr.insertText(text, at)
    editor.dispatch(tr)
}

/// Type `[[Ar` at the end of a document made of `blocks`, and report whether the
/// popup opened.
private func suggestsAtEndOf(_ editor: Editor, _ blocks: [Node]) throws -> Bool {
    editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(blocks)))
    try typeAtEnd(editor, "[[Ar")
    return editor.wikiLinkSuggestion != nil
}

/// Type `@Ar` at the end of a document made of `blocks`, and report whether the
/// mention popup opened.
private func mentionsAtEndOf(_ editor: Editor, _ blocks: [Node]) throws -> Bool {
    editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(blocks)))
    try typeAtEnd(editor, "@Ar")
    return editor.mentionSuggestion != nil
}

func registerWikiLinkContextTests() {
    test("wiki suggestion: a paragraph offers targets") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        try expect(try suggestsAtEndOf(editor, [try s.node("paragraph", [:], content: Fragment.from([s.text("see ")]))]),
                   "a paragraph is prose")
    }

    test("wiki suggestion: a list item's paragraph offers targets") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let para = try s.node("paragraph", [:], content: Fragment.from([s.text("see ")]))
        let item = try s.node("listItem", [:], content: Fragment.from([para]))
        try expect(try suggestsAtEndOf(editor, [try s.node("bulletList", [:], content: Fragment.from([item]))]),
                   "a bullet item holds a paragraph")
    }

    test("wiki suggestion: a task item's paragraph offers targets") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let para = try s.node("paragraph", [:], content: Fragment.from([s.text("see ")]))
        let item = try s.node("taskItem", [:], content: Fragment.from([para]))
        try expect(try suggestsAtEndOf(editor, [try s.node("taskList", [:], content: Fragment.from([item]))]),
                   "a task item holds a paragraph")
    }

    test("wiki suggestion: a quoted paragraph offers targets") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let para = try s.node("paragraph", [:], content: Fragment.from([s.text("see ")]))
        try expect(try suggestsAtEndOf(editor, [try s.node("blockquote", [:], content: Fragment.from([para]))]),
                   "a quote holds a paragraph")
    }

    test("wiki suggestion: a table cell's paragraph offers targets") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let para = try s.node("paragraph", [:], content: Fragment.from([s.text("see ")]))
        let cell = try s.node("tableCell", [:], content: Fragment.from([para]))
        let row = try s.node("tableRow", [:], content: Fragment.from([cell]))
        try expect(try suggestsAtEndOf(editor, [try s.node("table", [:], content: Fragment.from([row]))]),
                   "a cell holds a paragraph")
    }

    test("wiki suggestion: a heading doesn't") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let heading = try s.node("heading", ["level": .int(2)], content: Fragment.from([s.text("Notes ")]))
        try expect(!(try suggestsAtEndOf(editor, [heading])), "a heading is a title, not prose")
        // The text is still typed — only the popup is withheld.
        try expectEqual(editor.doc.textBetween(0, editor.doc.content.size, blockSeparator: nil), "Notes [[Ar")
    }

    test("wiki suggestion: a code block doesn't") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let code = try s.node("codeBlock", [:], content: Fragment.from([s.text("let a = ")]))
        try expect(!(try suggestsAtEndOf(editor, [code])), "`[[` in code is brackets")
    }

    test("wiki suggestion: an inline code span doesn't") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        try expectNotNil(s.marks["code"])
        let text = s.text("let a = ", [s.marks["code"]!.create()])
        try expect(!(try suggestsAtEndOf(editor, [try s.node("paragraph", [:], content: Fragment.from([text]))])),
                   "a code span is code, paragraph or not")
    }

    // The `@` trigger answers to the same rule: code is literal text, and the
    // schema decides. (A heading differs — a mention in a title is ordinary.)

    test("mention suggestion: a paragraph offers names") {
        let editor = try Editor(extensions: fullKit(mentionSuggestions: { _ in ["Ari"] }))
        let s = editor.schema
        try expect(try mentionsAtEndOf(editor, [try s.node("paragraph", [:], content: Fragment.from([s.text("ask ")]))]),
                   "a paragraph is prose")
    }

    test("mention suggestion: a code block doesn't") {
        let editor = try Editor(extensions: fullKit(mentionSuggestions: { _ in ["Ari"] }))
        let s = editor.schema
        let code = try s.node("codeBlock", [:], content: Fragment.from([s.text("let a = ")]))
        try expect(!(try mentionsAtEndOf(editor, [code])), "`@` in code is an `@`")
        // The text is still typed — only the popup is withheld.
        try expectEqual(editor.doc.textBetween(0, editor.doc.content.size, blockSeparator: nil), "let a = @Ar")
    }

    test("mention suggestion: an inline code span doesn't") {
        let editor = try Editor(extensions: fullKit(mentionSuggestions: { _ in ["Ari"] }))
        let s = editor.schema
        let text = s.text("let a = ", [s.marks["code"]!.create()])
        try expect(!(try mentionsAtEndOf(editor, [try s.node("paragraph", [:], content: Fragment.from([text]))])),
                   "a code span is code, paragraph or not")
    }

    test("mention suggestion: a heading does") {
        let editor = try Editor(extensions: fullKit(mentionSuggestions: { _ in ["Ari"] }))
        let s = editor.schema
        let heading = try s.node("heading", ["level": .int(2)], content: Fragment.from([s.text("Notes ")]))
        try expect(try mentionsAtEndOf(editor, [heading]), "a mention in a title is ordinary")
    }
}
