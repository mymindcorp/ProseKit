import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// Tests written against mutants of the editor facade, the extension manager and
// a handful of extensions that the rest of the suite let through. Each pins a
// behaviour a single flipped comparison, dropped statement or dropped guard
// used to be able to break without any other test noticing.

// MARK: - Fixtures

/// Contributes a global attribute that collides with one heading already has,
/// plus one it doesn't.
private final class HeadingLevelClash: Extension {
    let name = "headingLevelClash"
    func globalAttributes() -> [GlobalAttribute] {
        [GlobalAttribute(types: ["heading"], attributes: [
            "level": AttributeSpec(default: .int(6)),
            "tone": AttributeSpec(default: .string("plain")),
        ])]
    }
}

/// A block that may only hold blockquotes, so the paragraphs of a quote inside
/// it can't be lifted into it — only past it.
private final class QuoteShelf: NodeExtension {
    let name = "quoteShelf"
    var nodeSpec: NodeSpec { NodeSpec(content: "blockquote+", group: "block") }
}

/// Thread-safe record of the queries a suggestion provider saw.
private final class QueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    func record(_ q: String) { lock.lock(); queries.append(q); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return queries }
}

private func taskItemPositions(_ editor: Editor) -> [Int] {
    var positions: [Int] = []
    editor.doc.descendants { node, pos, _, _ in
        if node.type.name == "taskItem" { positions.append(pos) }
        return true
    }
    return positions
}

private func taskItemPosition(_ editor: Editor, named text: String) -> Int? {
    var found: Int?
    editor.doc.descendants { node, pos, _, _ in
        if found == nil, node.type.name == "taskItem", node.firstChild?.textContent == text { found = pos }
        return found == nil
    }
    return found
}

private func check(_ editor: Editor, _ text: String) throws {
    guard let pos = taskItemPosition(editor, named: text),
          let tr = setTaskChecked(editor.state, pos: pos, checked: true) else {
        try expect(false, "no task item \(text)"); return
    }
    editor.dispatch(tr)
}

func registerEditorWiringMutationKillTests() {
    // MARK: - ExtensionManager

    test("editor wiring: a global attribute never overwrites one the node declares") {
        let manager = try ExtensionManager(starterKit() + [HeadingLevelClash()])
        let heading = try manager.schema.node("heading")
        try expectEqual(heading.attrs["level"], .int(1))
        try expectEqual(heading.attrs["tone"], .string("plain"))
    }

    // MARK: - Editor

    test("editor wiring: a chain that edits the document bumps the revision once") {
        let editor = try makeEditor()
        let before = editor.docRevision
        let insert: Command = { state, dispatch, _ in
            let tr = state.tr
            guard (try? tr.insertText("hi", 1)) != nil else { return false }
            dispatch?(tr)
            return true
        }
        try expect(editor.chain([insert, insert]))
        try expectEqual(editor.docRevision, before + 1)
        try expectEqual(editor.getText(), "hihi")
        // A selection-only chain leaves the revision alone.
        let caret: Command = { state, dispatch, _ in
            dispatch?(state.tr.setSelection(TextSelection.create(state.doc, 2, 2)))
            return true
        }
        try expect(editor.chain([caret]))
        try expectEqual(editor.docRevision, before + 1)
    }

    test("editor wiring: a mark is not active over a range with no text in it") {
        let editor = try makeEditor()
        try editor.setContent(html: "<p></p><p></p>")
        select(editor, 1, 3)
        try expect(!editor.isActive(mark: "bold"))
        try expect(!editor.isActive("bold"))
    }

    test("editor wiring: a mark's attributes come from its first instance in the selection") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p><a href=\"https://a.example\">aa</a><a href=\"https://b.example\">bb</a></p>")
        select(editor, 1, 5)
        try expectEqual(editor.getAttributes("link")["href"], .string("https://a.example"))
        try expectEqual(editor.attributes(ofMark: "link")?["href"], .string("https://a.example"))
    }

    test("editor wiring: inserting past the end of the document appends") {
        let editor = try makeEditor()
        try editor.setContent(html: "<p>abc</p>")
        let paragraph = try editor.schema.node("paragraph", content: .from(editor.schema.text("end")))
        try expect(editor.insertContent(paragraph, at: 10_000))
        try expectEqual(editor.doc.childCount, 2)
        try expectEqual(editor.doc.child(0).textContent, "abc")
        try expectEqual(editor.doc.child(1).textContent, "end")
    }

    test("editor wiring: HTML inserted at a position leaves the selected text alone") {
        let editor = try makeEditor()
        try editor.setContent(html: "<p>abcdef</p>")
        select(editor, 2, 4)
        try expect(try editor.insertContent(html: "<p>X</p>", at: editor.doc.content.size))
        try expectEqual(editor.doc.childCount, 2)
        try expectEqual(editor.doc.child(0).textContent, "abcdef")
        try expectEqual(editor.doc.child(1).textContent, "X")
    }

    // MARK: - Extensions

    test("editor wiring: a nested task's home moves with its item and leaves nothing behind") {
        let editor = try Editor(extensions: fullKit(
            taskListOptions: TaskListOptions(sortCompletedToBottom: true)))
        func outer(_ name: String, _ a: String, _ b: String) -> String {
            "<li data-type=\"taskItem\" data-checked=\"false\"><p>\(name)</p><ul data-type=\"taskList\">"
                + "<li data-type=\"taskItem\" data-checked=\"false\"><p>\(a)</p></li>"
                + "<li data-type=\"taskItem\" data-checked=\"false\"><p>\(b)</p></li></ul></li>"
        }
        try editor.setContent(html: "<ul data-type=\"taskList\">" + outer("A", "a1", "a2") + outer("B", "b1", "b2") + "</ul>")
        try check(editor, "a1")   // records a home inside A's nested list
        try check(editor, "A")    // A drops below B, carrying that home with it
        let homes = taskSortKey.getState(editor.state) ?? [:]
        try expectEqual(homes.count, 2)
        for pos in homes.keys {
            let node = editor.doc.nodeAt(pos)
            try expectEqual(node?.type.name, "taskItem", "home at \(pos)")
            try expectEqual(node?.attrs["checked"], .bool(true), "home at \(pos)")
        }
        try expectEqual(taskItemPositions(editor).count, 6)
    }

    test("editor wiring: Backspace one character into a summary is an ordinary delete") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<details open><summary>title</summary><p>body</p></details>")
        var summaryStart = -1
        editor.doc.descendants { node, pos, _, _ in
            if summaryStart < 0, node.type.name == "detailsSummary" { summaryStart = pos + 1 }
            return summaryStart < 0
        }
        select(editor, summaryStart + 1, summaryStart + 1)
        try expect(!key(editor, "Backspace"), "the keymap leaves a mid-summary deletion to the view")
        try expect(editor.isActive(node: "details"))
    }

    test("editor wiring: checklist import matches a no-break space to a plain one") {
        let schema = try Editor(extensions: fullKit()).schema
        let item = try schema.node("listItem", content: .from(
            schema.node("paragraph", content: .from(schema.text("buy milk")))))
        let list = try schema.node("bulletList", content: .from(item))
        let out = applyChecklistMarkers(.from(list), checkedTexts: ["buy\u{00A0}milk"], schema: schema)
        try expectEqual(out.firstChild?.type.name, "taskList")
        try expectEqual(out.firstChild?.firstChild?.attrs["checked"], .bool(true))
    }

    test("editor wiring: a selection that only starts on a match isn't that match") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p>abc abc</p>")
        editor.setSearch("abc")
        try expectEqual(editor.searchMatches.count, 2)
        select(editor, 1, 4)
        try expectEqual(editor.currentSearchMatchIndex, 0)
        select(editor, 1, 2)
        try expectEqual(editor.currentSearchMatchIndex, -1)
        select(editor, 5, 5)
        try expectEqual(editor.currentSearchMatchIndex, -1)
    }

    test("editor wiring: pulling a query already in flight doesn't restart its fetch") {
        try MainActor.assumeIsolated {
            let log = QueryLog()
            let editor = try Editor(extensions: fullKit(wikiLinkAsyncSuggestions: { q in
                log.record(q)
                return ["Archive"]
            }))
            try type(editor, "[[Ar")
            guard let source = editor.suggestionSources.first(where: { $0.context(editor) != nil }) else {
                try expect(false, "no live wiki suggestion"); return
            }
            var changed = false
            source.onChange = { changed = true }
            // Every keystroke and scroll frame pulls the entries again. Keep
            // pulling well past the debounce: the one fetch must still land.
            let deadline = Date().addingTimeInterval(1.5)
            while !changed && Date() < deadline {
                _ = source.entries("Ar", editor)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            try expect(changed, "the fetch never completed while the query was being pulled")
            try expectEqual(log.all, ["Ar"])
        }
    }

    test("editor wiring: toggling a quote that can only be lifted past its parent does nothing") {
        let editor = try Editor(extensions: fullKit() + [QuoteShelf()])
        let s = editor.schema
        let paragraph = try s.node("paragraph", content: .from(s.text("quoted")))
        let quote = try s.node("blockquote", content: .from(paragraph))
        let shelf = try s.node("quoteShelf", content: .from(quote))
        editor.setContent(try s.node("doc", content: .from(shelf)))
        let before = editor.doc
        select(editor, 4, 4)
        try expect(editor.isActive(node: "blockquote"))
        try expect(!editor.run("toggleBlockquote"))
        try expectEqual(editor.doc, before)
    }

    test("editor wiring: the wiki-link provider sees the query without its padding") {
        try MainActor.assumeIsolated {
            let log = QueryLog()
            let editor = try Editor(extensions: fullKit(wikiLinkSuggestions: { q in
                log.record(q)
                return ["Archive"]
            }))
            try type(editor, "[[Ar")
            guard let source = editor.suggestionSources.first(where: { $0.context(editor) != nil }) else {
                try expect(false, "no live wiki suggestion"); return
            }
            try expectEqual(source.entries("  Ar ", editor).count, 1)
            try expectEqual(log.all, ["Ar"])
        }
    }
}
