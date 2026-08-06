import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

// The two halves of the slash menu that `SlashMenu.swift` doesn't reach.
//
// The first is the `SuggestionSource` — the whole bridge between the tracked
// query and the popup the renderer draws. It was uncovered for a reason rather
// than an oversight: it's `@MainActor` and this harness isn't, so reaching it
// needs `MainActor.assumeIsolated`. It is also the only part of the extension
// the user actually sees, so leaving it untested meant the menu could offer
// nothing, or offer everything, without a test noticing.
//
// The second is `defaultSlashCommands()`, which is a table. Line coverage
// counts it as covered the moment it's called, and says nothing about whether
// the twelve command *names* in it — plain strings — are commands that exist.
// A typo there is a menu row that quietly does nothing when tapped.

/// Run `body` on the main actor, where the suggestion sources live. The harness
/// runs its tests on the main thread, so this is an assertion about where we
/// already are rather than a hop.
private func onMain(_ body: @MainActor () throws -> Void) rethrows {
    try MainActor.assumeIsolated(body)
}

func registerSlashMenuSourceTests() {
    // MARK: The table

    test("slash menu: every default command is one the editor can run") {
        // The test this file exists for. Each entry names its command with a
        // string, and nothing else checks that string against anything — a
        // renamed or mistyped command leaves a row that looks fine and does
        // nothing.
        var dead: [String] = []
        for item in defaultSlashCommands() {
            let editor = try Editor(extensions: fullKit())
            if !editor.run(item.command) { dead.append("  \(item.title) → \(item.command)") }
        }
        try expect(dead.isEmpty, "\(dead.count) menu entries name a command that didn't run:\n"
                   + dead.joined(separator: "\n"))
    }

    test("slash menu: no two entries are the same row") {
        // Two rows with one title are indistinguishable in the popup; two rows
        // with one command are the same row written twice.
        let items = defaultSlashCommands()
        try expectEqual(Set(items.map(\.title)).count, items.count, "duplicate titles")
        try expectEqual(Set(items.map(\.command)).count, items.count, "duplicate commands")
    }

    test("slash menu: every entry is presentable") {
        // A row draws a title, an icon and a subtitle. An entry missing one
        // isn't a crash, it's a row that looks broken next to the others.
        var problems: [String] = []
        for item in defaultSlashCommands() {
            if item.title.isEmpty { problems.append("  a command has no title: \(item.command)") }
            if item.icon?.isEmpty ?? true { problems.append("  \(item.title) has no icon") }
            if item.subtitle?.isEmpty ?? true { problems.append("  \(item.title) has no subtitle") }
            if item.keywords.isEmpty { problems.append("  \(item.title) has no keywords") }
        }
        try expect(problems.isEmpty, problems.joined(separator: "\n"))
    }

    test("slash menu: every entry can be found by typing") {
        // Each row has to be reachable by *something* short, or it's in the
        // menu but not findable. Its own keywords are the promise.
        for item in defaultSlashCommands() {
            for keyword in item.keywords {
                try expect(item.matches(keyword), "\(item.title) doesn't match its own \(keyword)")
            }
        }
    }

    // MARK: What `matches` counts as a match

    test("slash menu: matching ignores case, on titles and keywords alike") {
        let heading = SlashCommandItem(title: "Heading 1", keywords: ["h1", "Title"],
                                       command: "toggleHeading1")
        for query in ["heading", "HEADING", "HeAdInG", "h1", "H1", "title", "TITLE"] {
            try expect(heading.matches(query), "should match \(query)")
        }
    }

    test("slash menu: matching is on any part of the word, not just its start") {
        let item = SlashCommandItem(title: "Bullet List", keywords: ["unordered"],
                                    command: "toggleBulletList")
        try expect(item.matches("ullet"), "a title substring")
        try expect(item.matches("order"), "a keyword substring")
        try expect(item.matches("List"))
        try expect(!item.matches("numbered"))
    }

    test("slash menu: an empty query offers everything") {
        // What the menu shows the moment "/" is typed.
        let items = defaultSlashCommands()
        try expectEqual(items.filter { $0.matches("") }.count, items.count)
    }

    // MARK: The bridge to the popup

    test("slash menu source: it reports the trigger the plugin tracked") {
        try onMain {
            let editor = try Editor(extensions: fullKit())
            try type(editor, "/head")
            let menu = editor.slashMenu
            try expectNotNil(menu)
            let context = editor.suggestionSources.compactMap { $0.context(editor) }.first
            try expect(context != nil, "the source should be offering the live trigger")
            try expectEqual(context?.query, "head")
            try expectEqual(context?.from, menu?.from)
            try expectEqual(context?.to, menu?.to)
        }
    }

    test("slash menu source: nothing to offer when no menu is open") {
        try onMain {
            let editor = try Editor(extensions: fullKit())
            try type(editor, "hello")
            try expect(editor.slashMenu == nil)
            for source in editor.suggestionSources {
                try expect(source.context(editor) == nil, "\(type(of: source)) offered a context")
                try expect(source.entries("head", editor).isEmpty,
                           "\(type(of: source)) offered entries with no menu open")
            }
        }
    }

    test("slash menu source: the entries are the matching commands, in order") {
        try onMain {
            let editor = try Editor(extensions: fullKit())
            try type(editor, "/head")
            let entries = editor.suggestionSources.flatMap { $0.entries("head", editor) }
            try expectEqual(entries.map(\.title), ["Heading 1", "Heading 2", "Heading 3"])
            // The row carries what it draws.
            try expectEqual(entries[0].subtitle, "Big section heading")
            try expectNotNil(entries[0].icon)
        }
    }

    test("slash menu source: an unmatched query offers nothing") {
        try onMain {
            let editor = try Editor(extensions: fullKit())
            try type(editor, "/zzz")
            try expect(editor.suggestionSources.flatMap { $0.entries("zzz", editor) }.isEmpty)
        }
    }

    test("slash menu source: choosing an entry runs it and clears the trigger") {
        // End to end, the way the renderer does it: pull the entries, then call
        // the one the user tapped. The `/head` text has to go with it.
        try onMain {
            let editor = try Editor(extensions: fullKit())
            try type(editor, "/head")
            let entries = editor.suggestionSources.flatMap { $0.entries("head", editor) }
            try expectEqual(entries.first?.title, "Heading 1")
            entries[0].apply(editor)
            try expect(editor.isActive(node: "heading", attrs: ["level": .int(1)]))
            try expectEqual(editor.doc.textContent, "", "the /head text should be gone")
        }
    }

    test("slash menu source: a custom command list is what gets offered") {
        // The extension takes its commands as an argument, and a host that
        // passes its own must see those rather than the defaults.
        try onMain {
            let mine = [SlashCommandItem(title: "Only This", keywords: ["only"],
                                         command: "toggleBulletList")]
            let editor = try Editor(extensions: starterKit() + [SlashMenuExtension(commands: mine)])
            try type(editor, "/")
            let entries = editor.suggestionSources.flatMap { $0.entries("", editor) }
            try expectEqual(entries.map(\.title), ["Only This"])
        }
    }

    // MARK: Where the trigger doesn't fire

    test("slash menu: atLineStart=false still won't trigger inside a word") {
        // The branch the default configuration can't reach: with the Notion
        // rule, a "/" is a trigger after whitespace but not in "and/or" — which
        // is the whole reason the rule checks the character before it.
        let editor = try Editor(extensions: starterKit() + [SlashMenuExtension(atLineStart: false)])
        try type(editor, "and/or")
        try expect(editor.slashMenu == nil, "and/or is a word, not a command")
        // And to be sure it isn't simply never triggering.
        let other = try Editor(extensions: starterKit() + [SlashMenuExtension(atLineStart: false)])
        try type(other, "and /or")
        try expectEqual(other.slashMenu?.query, "or")
    }

    test("slash menu: a code block takes no commands") {
        let editor = try Editor(extensions: fullKit())
        try expect(editor.run("toggleCodeBlock"))
        try type(editor, "/head")
        try expect(editor.slashMenu == nil, "the menu must stay shut inside code")
    }

    test("slash menu: applying with no menu open changes nothing") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hello")
        let item = defaultSlashCommands().first { $0.command == "toggleHeading1" }
        try expectNotNil(item)
        try expect(!editor.applySlashCommand(item!), "there is no trigger range to apply over")
        try expectEqual(editor.doc.textContent, "hello", "and nothing was deleted")
    }
}
