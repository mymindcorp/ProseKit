import Foundation
import DocumentModel
import EditorStateKit
import EditorHistory
import SchemaKit
import TestHarness

func registerSlashMenuTests() {
    for (left, right) in [("e", "\u{301}"), ("🇺", "🇸"), ("👩", "\u{200d}💻")] {
        test("slash action: Unicode \(left + right) across marks preserves text before the trigger") {
            let editor = try Editor(extensions: starterKit() + [SlashMenuExtension(atLineStart: false)])
            let s = editor.schema
            let bold = s.marks["bold"]!.create()
            let prefix = [s.text(left), s.text(right, [bold]), s.text(" ")]
            let paragraph = try s.node("paragraph", content: .from(prefix + [s.text("/h1")]))
            editor.setContent(try s.node("doc", content: .from(paragraph)))
            let end = editor.doc.content.size - 1
            select(editor, end, end)
            let original = editor.state
            let expectedFrom = 1 + left.count + right.count + 1
            try expectEqual(editor.slashMenu?.from, expectedFrom)
            try expectEqual(editor.slashMenu?.query, "h1")
            try expect(editor.applySlashCommand(SlashCommandItem(title: "Heading", command: "toggleHeading1")))
            try expectEqual(editor.doc.firstChild?.type.name, "heading")
            try expectEqual(editor.doc.firstChild?.content, Fragment.from(prefix))
            try editor.doc.check()
            try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
            try expectEqual(editor.doc, original.doc)
            try expect(editor.state.selection.eq(original.selection))
        }
    }
    test("slash action: unavailable commands leave the query and selection untouched") {
        for command in ["unknownCommand", "unsetLink"] {
            let editor = try Editor(extensions: fullKit())
            try type(editor, "/action")
            let before = editor.doc
            let selection = editor.state.selection
            try expect(!editor.applySlashCommand(SlashCommandItem(title: "Action", command: command)))
            try expectEqual(editor.doc, before)
            try expect(editor.state.selection.eq(selection))
        }
    }

    test("slash action: captured range targets its original block after the caret moves") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p>/h1</p><p>keep</p>")
        select(editor, 4, 4)
        let menu = editor.slashMenu!
        select(editor, editor.doc.content.size - 1, editor.doc.content.size - 1)
        try expect(editor.applySlashCommand(SlashCommandItem(title: "Heading", command: "toggleHeading1"), from: menu.from, to: menu.to))
        try expectEqual(editor.doc.child(0).type.name, "heading")
        try expectEqual(editor.doc.child(1).type.name, "paragraph")
        try expectEqual(editor.doc.child(1).textContent, "keep")
    }

    test("slash action: stale entries do not edit newer content") {
        try MainActor.assumeIsolated {
            let editor = try Editor(extensions: fullKit())
            try type(editor, "/h1")
            let source = editor.suggestionSources.first { $0.context(editor) != nil }!
            let entry = source.entries("h1", editor)[0]
            try editor.setContent(html: "<p>keep this text</p>")
            let before = editor.doc
            entry.apply(editor)
            try expectEqual(editor.doc, before)
        }
    }

    test("slash query: hard breaks end the query") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p>/head<br>next</p>")
        select(editor, editor.doc.content.size - 1, editor.doc.content.size - 1)
        try expectNil(editor.slashMenu)
    }

    test("slash menu: activates when typing / at the start of a block") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "/")
        try expectNotNil(editor.slashMenu)
        try expectEqual(editor.slashMenu?.query, "")
    }

    test("slash menu: captures the query after /") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "/head")
        try expectEqual(editor.slashMenu?.query, "head")
    }

    test("slash menu: does not trigger mid-word (and/or)") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "and/or")
        try expect(editor.slashMenu == nil)
    }

    test("slash menu: a space closes the menu") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "/head ")
        try expect(editor.slashMenu == nil)
    }

    test("slash menu: atLineStart (default) ignores / that isn't at line start") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hello /") // after text, even though preceded by a space
        try expect(editor.slashMenu == nil)
    }

    test("slash menu: atLineStart=false triggers after whitespace") {
        let editor = try Editor(extensions: starterKit() + [SlashMenuExtension(atLineStart: false)])
        try type(editor, "hello /")
        try expectNotNil(editor.slashMenu)
        try expectEqual(editor.slashMenu?.query, "")
    }

    test("slash menu: matching filters by title and keywords") {
        let items = defaultSlashCommands()
        try expect(items.contains { $0.matches("h1") && $0.title == "Heading 1" })
        try expect(items.contains { $0.matches("todo") && $0.title == "Task List" })
        try expect(items.filter { $0.matches("list") }.count >= 2)
    }

    test("slash menu: applying over a captured range works even after the selection moved") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "/h1")
        let menu = editor.slashMenu
        try expectNotNil(menu)
        // Simulate a tap moving the caret, which clears the live slash menu — the
        // exact situation that made clicking a menu item a no-op.
        select(editor, 1, 1)
        try expect(editor.slashMenu == nil)
        let item = defaultSlashCommands().first { $0.command == "toggleHeading1" }
        try expectNotNil(item)
        try expect(editor.applySlashCommand(item!, from: menu!.from, to: menu!.to))
        try expect(editor.isActive(node: "heading", attrs: ["level": .int(1)]))
        try expectEqual(editor.doc.textContent, "")
    }

    test("slash menu: applying a command deletes the /query and runs it") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "/h1")
        let item = defaultSlashCommands().first { $0.command == "toggleHeading1" }
        try expectNotNil(item)
        try expect(editor.applySlashCommand(item!))
        try expect(editor.isActive(node: "heading", attrs: ["level": .int(1)]))
        try expectEqual(editor.doc.textContent, "") // the "/h1" text was removed
    }
}
