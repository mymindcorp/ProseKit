import Foundation
import DocumentModel
import EditorStateKit
import EditorHistory
import SchemaKit
import TestHarness

// Where `[[` is allowed to autocomplete. Prose — paragraphs, wherever they sit
// — offers targets; a heading is a title and code is literal text, so neither
// does. The trigger text is still typed either way; only the popup differs.

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
    for wiki in [false, true] {
        for backwards in [false, true] {
            test("suggestion acceptance: \(wiki ? "wiki" : "mention") puts the caret after the captured range (backwards \(backwards))") {
                let editor = try Editor(extensions: fullKit())
                let query = wiki ? "[[Pa" : "@Pa"
                try editor.setContent(html: "<p>before " + query + " after</p><p>elsewhere</p>")
                let from = 8, to = from + query.count
                let elsewhere = editor.doc.content.size - 2
                select(editor, elsewhere, elsewhere)
                let accepted = wiki
                    ? editor.acceptWikiLinkSuggestion(text: "Page", from: backwards ? to : from, to: backwards ? from : to)
                    : editor.acceptMentionSuggestion(id: "person", from: backwards ? to : from, to: backwards ? from : to)
                try expect(accepted)
                try expect(editor.state.selection.empty)
                try expectEqual(editor.state.selection.head, from + 1)
                try expectEqual(editor.doc.lastChild?.textContent, "elsewhere")
                try expectEqual(editor.doc.firstChild?.lastChild?.text, " after")
                try editor.doc.check()
            }
        }

        test("suggestion acceptance: \(wiki ? "wiki" : "mention") retains query formatting") {
            let editor = try Editor(extensions: fullKit())
            let query = wiki ? "[[Pa" : "@Pa"
            try editor.setContent(html: "<p>before <strong>" + query + "</strong> after</p>")
            let end = 8 + query.count
            select(editor, end, end)
            let original = editor.state
            try expect(wiki ? editor.acceptWikiLinkSuggestion(text: "Page") : editor.acceptMentionSuggestion(id: "person"))
            let inserted = editor.doc.firstChild!.child(1)
            try expectEqual(inserted.type.name, wiki ? "wikiLink" : "mention")
            try expect(inserted.marks.contains { $0.type.name == "bold" })
            try expectEqual(editor.doc.firstChild?.firstChild?.text, "before ")
            try expectEqual(editor.doc.firstChild?.lastChild?.text, " after")
            try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
            try expectEqual(editor.doc, original.doc)
            try expect(editor.state.selection.eq(original.selection))
        }
    }
    for wiki in [false, true] {
        let name = wiki ? "wikiLink" : "mention"
        test("suggestion schema: \(name) is allowed after a required leading node") {
            let editor = try Editor(extensions: [DocumentExtension(), SuggestionRestrictedParagraph("hardBreak (text|" + name + ")*"), TextExtension(), HardBreakExtension(), MentionExtension(), WikiLinkExtension()])
            let s = editor.schema
            editor.setContent(try s.node("doc", content: .from(s.node("paragraph", content: .from([
                try s.node("hardBreak"), s.text(wiki ? "before [[Pa" : "before @Pa")
            ])))))
            let end = editor.doc.content.size - 1
            select(editor, end, end)
            try expect(wiki ? editor.wikiLinkSuggestion != nil : editor.mentionSuggestion != nil)
            try expect(wiki ? editor.acceptWikiLinkSuggestion(text: "Page") : editor.acceptMentionSuggestion(id: "person"))
            try expectEqual(editor.doc.firstChild?.firstChild?.type.name, "hardBreak")
            try expectEqual(editor.doc.firstChild?.child(1).text, "before ")
            try expectEqual(editor.doc.firstChild?.lastChild?.type.name, name)
            try editor.doc.check()
        }

        test("suggestion schema: \(name) cannot reuse an occupied required slot") {
            let editor = try Editor(extensions: [DocumentExtension(), SuggestionRestrictedParagraph("(" + name + "|hardBreak) text*"), TextExtension(), HardBreakExtension(), MentionExtension(), WikiLinkExtension()])
            let s = editor.schema
            let existing = try s.node(name, wiki ? ["text": .string("existing")] : ["id": .string("existing")])
            editor.setContent(try s.node("doc", content: .from(s.node("paragraph", content: .from([
                existing, s.text(wiki ? " [[Pa" : " @Pa")
            ])))))
            let end = editor.doc.content.size - 1
            select(editor, end, end)
            try expect(wiki ? editor.wikiLinkSuggestion == nil : editor.mentionSuggestion == nil)
            let original = editor.state
            try expect(!(wiki ? editor.acceptWikiLinkSuggestion(text: "Page") : editor.acceptMentionSuggestion(id: "person")))
            try expect(editor.state === original)
            try editor.doc.check()
        }
    }
    for wiki in [false, true] {
        for (left, right) in [("e", "\u{301}"), ("🇺", "🇸"), ("👩", "\u{200d}💻")] {
            test("suggestion Unicode: \(wiki ? "wiki" : "mention") after \(left + right) preserves preceding text") {
                let editor = try Editor(extensions: fullKit())
                let s = editor.schema, bold = s.marks["bold"]!.create()
                let prefix = Fragment.from([s.text(left), s.text(right, [bold]), s.text(" ")])
                // Also split the two-character wiki trigger across marks.
                let trigger = wiki ? [s.text("["), s.text("[Pa", [bold])] : [s.text("@Pa")]
                editor.setContent(try s.node("doc", content: .from(s.node("paragraph", content: prefix.append(.from(trigger))))))
                let end = editor.doc.content.size - 1
                select(editor, end, end)
                let original = editor.state
                let from = wiki ? editor.wikiLinkSuggestion?.from : editor.mentionSuggestion?.from
                try expectEqual(from, prefix.size + 1)
                try expect(wiki ? editor.acceptWikiLinkSuggestion(text: "Page") : editor.acceptMentionSuggestion(id: "person"))
                let paragraph = editor.doc.firstChild!
                try expectEqual(paragraph.content.cut(0, prefix.size), prefix)
                try expectEqual(paragraph.lastChild?.type.name, wiki ? "wikiLink" : "mention")
                try editor.doc.check()
                try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
                try expectEqual(editor.doc, original.doc)
                try expect(editor.state.selection.eq(original.selection))
            }
        }
    }
    for source in ["[[Page]", "[[Page|Label]"] {
        test("wiki input safety: forbidden node preserves \(source)") {
            let editor = try Editor(extensions: [DocumentExtension(), WikiTextOnlyParagraph(), TextExtension(), WikiLinkExtension()])
            try type(editor, source)
            let original = editor.state, revision = editor.docRevision
            let end = source.count + 1
            try expect(!textInput(editor, at: end, "]"))
            try expect(editor.state === original)
            try expectEqual(editor.docRevision, revision)
            editor.dispatch(try editor.state.tr.insertText("]", end))
            try expectEqual(editor.doc.textContent, source + "]")
            try editor.doc.check()
        }
    }

    for atom in ["hardBreak", "mention", "inlineMath", "wikiLink"] {
        test("wiki input safety: shortcut cannot consume an embedded \(atom)") {
            let editor = try Editor(extensions: fullKit())
            let s = editor.schema
            let attrs: Attrs = atom == "mention" ? ["id": .string("person")]
                : atom == "inlineMath" ? ["latex": .string("x")]
                : atom == "wikiLink" ? ["text": .string("Existing")] : [:]
            let embedded = try s.node(atom, attrs)
            editor.setContent(try s.node("doc", content: .from(try s.node("paragraph", content: .from([
                s.text("[[before"), embedded, s.text("after]")
            ])))))
            let end = editor.doc.content.size - 1
            select(editor, end, end)
            let original = editor.state, revision = editor.docRevision
            try expect(!textInput(editor, at: end, "]"))
            try expect(editor.state === original)
            try expectEqual(editor.docRevision, revision)
            editor.dispatch(try editor.state.tr.insertText("]", end))
            try expectEqual(editor.doc.firstChild?.child(1), embedded)
            try expectEqual(editor.doc.firstChild?.lastChild?.text, "after]]")
            try editor.doc.check()
        }
    }

    test("wiki input safety: literal placeholder text remains valid label text") {
        let editor = try Editor(extensions: fullKit())
        let label = "before\u{fffc}after"
        try type(editor, "[[" + label + "]")
        let end = editor.doc.content.size - 1
        try expect(textInput(editor, at: end, "]"))
        try expectEqual(editor.doc.firstChild?.firstChild?.type.name, "wikiLink")
        try expectEqual(editor.doc.firstChild?.firstChild?.attrs["text"], .string(label))
        try editor.doc.check()
    }

    test("wiki input safety: text across mark boundaries still converts") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p>before [[<strong>Page</strong>|Label] after</p>")
        select(editor, 21, 21)
        try expect(textInput(editor, at: 21, "]"))
        try expectEqual(count(editor.doc, "wikiLink"), 1)
        try expectEqual(editor.doc.firstChild?.child(1).attrs["text"], .string("Label"))
        try expectEqual(editor.doc.firstChild?.firstChild?.text, "before ")
        try expectEqual(editor.doc.firstChild?.lastChild?.text, " after")
        try editor.doc.check()
    }
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

private final class WikiTextOnlyParagraph: NodeExtension {
    let name = "paragraph"
    var nodeSpec: NodeSpec { NodeSpec(content: "text*", group: "block") }
}

private final class SuggestionRestrictedParagraph: NodeExtension {
    let name = "paragraph"
    let content: String
    init(_ content: String) { self.content = content }
    var nodeSpec: NodeSpec { NodeSpec(content: content, group: "block") }
}
