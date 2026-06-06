import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

func registerSlashMenuTests() {
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
