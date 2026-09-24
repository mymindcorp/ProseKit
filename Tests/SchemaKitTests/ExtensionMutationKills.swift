import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorChangeset
import SchemaKit
import TestHarness

// Tests written against mutants of the SchemaKit extensions that the rest of the
// suite let through: each one pins a behaviour that a single flipped comparison,
// dropped statement or swapped operand used to be able to break silently.

private func trackChangesEditor() throws -> Editor {
    try Editor(extensions: starterKit() + [SuggestionModeExtension(author: "alice")])
}

private func trackState(_ editor: Editor) -> SuggestionModeState {
    suggestionModeKey.getState(editor.state)!
}

private func setTracking(_ editor: Editor, _ on: Bool) {
    editor.dispatch(setSuggestionMode(editor.state.tr, enabled: on))
}

private func insertText(_ editor: Editor, _ text: String, at pos: Int) throws {
    let tr = editor.state.tr
    try tr.insertText(text, pos)
    editor.dispatch(tr)
}

private func deleteRange(_ editor: Editor, _ from: Int, _ to: Int) throws {
    let tr = editor.state.tr
    try tr.delete(from, to)
    editor.dispatch(tr)
}

// MARK: - Task sorting helpers

private func sortedTaskEditor(_ items: [(String, Bool)]) throws -> Editor {
    let editor = try Editor(extensions: fullKit(
        taskListOptions: TaskListOptions(sortCompletedToBottom: true)))
    let lis = items.map { text, checked in
        "<li data-type=\"taskItem\" data-checked=\"\(checked)\"><p>\(text)</p></li>"
    }.joined()
    try editor.setContent(html: "<ul data-type=\"taskList\">\(lis)</ul>")
    return editor
}

/// (text, checked) for every task item, in document order.
private func taskRows(_ editor: Editor) -> [String] {
    var out: [String] = []
    editor.doc.descendants { node, _, _, _ in
        if node.type.name == "taskItem" {
            out.append((node.attrs["checked"]?.boolValue == true ? "x " : "- ") + node.firstChild!.textContent)
        }
        return true
    }
    return out
}

private func taskItemPos(_ editor: Editor, _ text: String) -> Int {
    var found = -1
    editor.doc.descendants { node, pos, _, _ in
        if node.type.name == "taskItem", node.firstChild?.textContent == text, found < 0 { found = pos }
        return found < 0
    }
    return found
}

/// Tick or untick through the checkbox route (`setTaskChecked`).
private func tick(_ editor: Editor, _ text: String, _ checked: Bool) throws {
    let tr = setTaskChecked(editor.state, pos: taskItemPos(editor, text), checked: checked)
    try expectNotNil(tr)
    editor.dispatch(tr!)
}

// MARK: - Node building

/// A paragraph that may end in one wiki-link or mention, and hold nothing after it.
private final class TrailingAtomParagraph: NodeExtension {
    let name = "paragraph"
    var nodeSpec: NodeSpec { NodeSpec(content: "text* (wikiLink|mention)?", group: "block") }
}

/// Hands out a fixed script of ids, then "spare-N".
private final class ScriptedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String]
    private var spare = 0
    init(_ script: [String]) { self.script = script }
    func load(_ more: [String]) {
        lock.lock(); defer { lock.unlock() }
        script = more
    }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        if !script.isEmpty { return script.removeFirst() }
        spare += 1
        return "spare-\(spare)"
    }
}

private struct MissingValue: Error {}

private func required<T>(_ value: T?) throws -> T {
    guard let value else { throw MissingValue() }
    return value
}

private func mk(_ schema: Schema, _ type: String, _ attrs: Attrs = [:], _ kids: [Node] = []) throws -> Node {
    try schema.node(type, attrs, content: Fragment.from(kids))
}

private func para(_ schema: Schema, _ text: String) throws -> Node {
    try mk(schema, "paragraph", [:], text.isEmpty ? [] : [schema.text(text)])
}

/// The document's first position whose text node (or empty textblock) reads `text`.
private func textStart(_ doc: Node, _ text: String) -> Int {
    var found = -1
    doc.descendants { node, pos, _, _ in
        if found >= 0 { return false }
        if node.isTextblock && node.textContent == text { found = pos + 1 }
        return true
    }
    return found
}

func registerExtensionMutationKillTests() {
    // MARK: - Suggestion mode

    test("mutation kills: accepting an earlier change shifts a later deletion's base range") {
        // Accepting "X" grows the base by one, so the pending deletion of
        // "three" now starts one position later in the base. Rejecting it has
        // to restore exactly "three" from there.
        let editor = try trackChangesEditor()
        try type(editor, "one two three")
        setTracking(editor, true)
        try insertText(editor, "X", at: 4)             // "oneX two three"
        try deleteRange(editor, 10, 15)                // "oneX two "
        try expectEqual(trackState(editor).changes.count, 2)
        try expect(editor.run(acceptSuggestion(0)))
        try expectEqual(trackState(editor).changes.count, 1)
        try expectEqual(trackState(editor).baseDoc?.textContent, "oneX two three")
        try expectEqual(trackState(editor).deletedText(at: 0), "three")
        let change = trackState(editor).changes[0]
        try expectEqual(change.fromA, 10)
        try expectEqual(change.toA, 15)
        try expect(editor.run(rejectSuggestion(0)))
        try expectEqual(editor.doc.textContent, "oneX two three")
        try expectEqual(trackState(editor).changes.count, 0)
    }

    test("mutation kills: turning suggestion mode off before it was ever on tracks nothing") {
        let editor = try trackChangesEditor()
        try type(editor, "base")
        setTracking(editor, false)
        try expectNil(trackState(editor).changeSet)
        try insertText(editor, "!", at: 5)
        try expectNil(trackState(editor).changeSet)
        // Enabling later starts from the document as it stands then.
        setTracking(editor, true)
        try expectEqual(trackState(editor).baseDoc?.textContent, "base!")
    }
    test("mutation kills: text typed with tracking off next to a suggestion isn't drawn as one") {
        // "AB" is suggested; "C" typed right after it once tracking is off
        // lands in the same change but is committed. Only "AB" is an
        // insertion on screen.
        let editor = try trackChangesEditor()
        try type(editor, "base")
        setTracking(editor, true)
        try insertText(editor, "AB", at: 5)
        setTracking(editor, false)
        try insertText(editor, "C", at: 7)
        try expectEqual(editor.doc.textContent, "baseABC")
        let inserts = suggestionDecorations(editor.state)?.decorations
            .filter { $0.attributes["class"] == "insertion" } ?? []
        try expectEqual(inserts.map { [$0.from, $0.to] }, [[5, 7]])
        try expectEqual(inserts.first?.attributes["data-author"], "alice")
    }

    test("mutation kills: a deletion widget carries its author, and no widget without deleted text") {
        let editor = try trackChangesEditor()
        try type(editor, "abcdef")
        setTracking(editor, true)
        try deleteRange(editor, 2, 4) // "bc"
        let widgets = suggestionDecorations(editor.state)?.decorations
            .filter { $0.attributes["class"] == "deletion" } ?? []
        try expectEqual(widgets.count, 1)
        try expectEqual(widgets.first?.attributes["data-author"], "alice")
        try expectEqual(widgets.first?.attributes["data-text"], "bc")
        // A pure insertion has no deleted text, so it gets no widget.
        let other = try trackChangesEditor()
        try type(other, "abc")
        setTracking(other, true)
        try insertText(other, "X", at: 2)
        let decos = suggestionDecorations(other.state)?.decorations ?? []
        try expectEqual(decos.filter { $0.attributes["class"] == "deletion" }.count, 0)
        try expectEqual(decos.count, 1)
    }
    test("mutation kills: suggestionIndex includes both ends of a change, and a bare deletion point") {
        let editor = try trackChangesEditor()
        try type(editor, "abcdef")
        setTracking(editor, true)
        try insertText(editor, "XY", at: 2)   // aXYbcdef, change at 2..4
        try deleteRange(editor, 7, 8)          // drop "e": a deletion point at 7
        let changes = trackState(editor).changes
        try expectEqual(changes.map { [$0.fromB, $0.toB] }, [[2, 4], [7, 7]])
        try expectEqual(suggestionIndex(at: 2, editor.state), 0)
        try expectEqual(suggestionIndex(at: 4, editor.state), 0) // the caret just after "XY"
        try expectNil(suggestionIndex(at: 5, editor.state))
        try expectEqual(suggestionIndex(at: 7, editor.state), 1)
    }
    test("mutation kills: every committed change in one untracked edit folds into the base") {
        // One transaction, tracking off, edits both sides of a pending
        // suggestion: both edits are committed, and neither may linger.
        let editor = try trackChangesEditor()
        try type(editor, "abcdef")
        setTracking(editor, true)
        try insertText(editor, "X", at: 4)      // abcXdef
        setTracking(editor, false)
        let tr = editor.state.tr
        try tr.insertText("Q", 8)                // abcXdefQ
        try tr.insertText("P", 1)                // PabcXdefQ
        editor.dispatch(tr)
        try expectEqual(editor.doc.textContent, "PabcXdefQ")
        try expectEqual(trackState(editor).changes.count, 1)
        try expectEqual(trackState(editor).baseDoc?.textContent, "PabcdefQ")
        try expect(editor.run(rejectAllSuggestions))
        try expectEqual(editor.doc.textContent, "PabcdefQ")
    }
    // MARK: - Task sorting

    test("mutation kills: a task inserted right before a sorted item doesn't take its home") {
        let editor = try sortedTaskEditor([("a", false), ("b", false), ("c", false)])
        try tick(editor, "a", true)
        try expectEqual(taskRows(editor), ["- b", "- c", "x a"])
        // A new task lands exactly at "a"'s position: the remembered home has to
        // stay with "a", not with the newcomer standing where it was.
        let item = try editor.schema.node("taskItem", ["checked": .bool(false)],
            content: .from(editor.schema.node("paragraph", content: .from(editor.schema.text("n")))))
        let tr = editor.state.tr
        try tr.insert(taskItemPos(editor, "a"), Fragment.from(item))
        editor.dispatch(tr)
        try expectEqual(taskRows(editor), ["- b", "- c", "- n", "x a"])
        try tick(editor, "a", false)
        try expectEqual(taskRows(editor), ["- a", "- b", "- c", "- n"])
    }
    test("mutation kills: unchecking several tasks at once sends them home lowest index first") {
        let editor = try sortedTaskEditor([("a", false), ("b", false), ("c", false), ("d", false), ("e", false)])
        try tick(editor, "d", true)   // home 3
        try tick(editor, "b", true)   // home 1
        try expectEqual(taskRows(editor), ["- a", "- c", "- e", "x d", "x b"])
        // One transaction unchecking both — a paste or collab step, sorted by
        // the plugin's appendTransaction.
        let tr = editor.state.tr
        try tr.setNodeAttribute(taskItemPos(editor, "d"), "checked", .bool(false))
        try tr.setNodeAttribute(taskItemPos(editor, "b"), "checked", .bool(false))
        editor.dispatch(tr)
        try expectEqual(taskRows(editor), ["- a", "- b", "- c", "- d", "- e"])
    }
    // MARK: - List commands

    test("mutation kills: Enter in an empty paragraph mid-item splits the item") {
        // Only an empty block that *ends* its item bails out to lifting; one
        // followed by more content splits like any other (prosemirror-schema-list).
        let editor = try makeEditor()
        let s = editor.schema
        editor.setContent(try mk(s, "doc", [:], [mk(s, "bulletList", [:], [
            mk(s, "listItem", [:], [para(s, "a"), para(s, ""), para(s, "b")])])]))
        let empty = textStart(editor.doc, "a") + 3
        select(editor, empty, empty)
        try expect(editor.run(splitListItem(s.nodes["listItem"]!)))
        let list = editor.doc.firstChild!
        try expectEqual(list.childCount, 2)
        try expectEqual(list.child(0).textContent, "a")
        try expectEqual(list.child(1).textContent, "b")
    }

    test("mutation kills: Enter at the end of a heading inside an item starts a paragraph item") {
        let editor = try makeEditor()
        let s = editor.schema
        let heading = try mk(s, "heading", ["level": .int(2)], [s.text("Title")])
        editor.setContent(try mk(s, "doc", [:], [mk(s, "bulletList", [:], [
            mk(s, "listItem", [:], [para(s, "a"), heading])])]))
        let item = s.nodes["listItem"]!
        // Mid-heading: the lower half would have to start an item with a
        // heading, which the item's content forbids.
        let mid = textStart(editor.doc, "Title") + 2
        select(editor, mid, mid)
        try expect(!editor.run(splitListItem(item)))
        let end = textStart(editor.doc, "Title") + 5
        select(editor, end, end)
        try expect(editor.run(splitListItem(item)))
        let list = editor.doc.firstChild!
        try expectEqual(list.childCount, 2)
        try expectEqual(list.child(0).lastChild?.type.name, "heading")
        try expectEqual(list.child(1).firstChild?.type.name, "paragraph")
        try expectEqual(list.child(1).textContent, "")
    }

    test("mutation kills: lifting the first item out checks the parent can hold item-then-list") {
        // A parent that may hold paragraphs before one trailing list. Lifting the
        // first of two items puts its paragraph where the list was and the rest of
        // the list after it — allowed. (Checking the wrong index would ask for the
        // item to go after the untouched list instead, which this parent forbids.)
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "paragraph* bulletList?")),
            ("paragraph", NodeSpec(content: "text*")),
            ("text", NodeSpec(group: "inline")),
            ("bulletList", NodeSpec(content: "listItem+")),
            ("listItem", NodeSpec(content: "paragraph")),
        ])
        let doc = try mk(schema, "doc", [:], [mk(schema, "bulletList", [:], [
            mk(schema, "listItem", [:], [para(schema, "a")]),
            mk(schema, "listItem", [:], [para(schema, "b")])])])
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc,
                                                         selection: TextSelection.create(doc, 3)))
        var out: Transaction?
        try expect(liftListItem(schema.nodes["listItem"]!)(state, { out = $0 }, nil))
        let lifted = try required(out).doc
        try expectEqual(lifted.childCount, 2)
        try expectEqual(lifted.child(0).type.name, "paragraph")
        try expectEqual(lifted.child(0).textContent, "a")
        try expectEqual(lifted.child(1).type.name, "bulletList")
        try expectEqual(lifted.child(1).childCount, 1)
    }

    test("mutation kills: lifting items that can't be merged declines instead of lifting one") {
        // Items hold exactly one paragraph, so the items after the first can't
        // be folded into it; lifting a range of them must refuse outright.
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "text*", group: "block")),
            ("text", NodeSpec(group: "inline")),
            ("bulletList", NodeSpec(content: "listItem+", group: "block")),
            ("listItem", NodeSpec(content: "paragraph")),
        ])
        let doc = try mk(schema, "doc", [:], [mk(schema, "bulletList", [:], [
            mk(schema, "listItem", [:], [para(schema, "a")]),
            mk(schema, "listItem", [:], [para(schema, "b")]),
            mk(schema, "listItem", [:], [para(schema, "c")])])])
        let from = textStart(doc, "a"), to = textStart(doc, "b") + 1
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc,
                                                         selection: TextSelection.create(doc, from, to)))
        var out: Transaction?
        let ran = liftListItem(schema.nodes["listItem"]!)(state, { out = $0 }, nil)
        try expect(!ran, "a lift that can't move every selected item must decline")
        try expectNil(out)
    }

    test("mutation kills: Tab on a selected task item nested in a bullet item sinks the task") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let task = { (t: String) in try mk(s, "taskItem", ["checked": .bool(false)], [para(s, t)]) }
        editor.setContent(try mk(s, "doc", [:], [mk(s, "bulletList", [:], [
            mk(s, "listItem", [:], [para(s, "a")]),
            mk(s, "listItem", [:], [para(s, "b"), mk(s, "taskList", [:], [task("t1"), task("t2")])])])]))
        let t2 = textStart(editor.doc, "t2") - 2
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, t2)))
        try expect(key(editor, "Tab"))
        let bullets = editor.doc.firstChild!
        try expectEqual(bullets.childCount, 2)  // the bullet item was not the one sunk
        let tasks = bullets.child(1).child(1)
        try expectEqual(tasks.type.name, "taskList")
        try expectEqual(tasks.childCount, 1)
        try expectEqual(tasks.child(0).child(1).type.name, "taskList") // t2 under t1
        try expectEqual(tasks.child(0).child(1).textContent, "t2")
    }
    // MARK: - Suggestion triggers

    test("mutation kills: turning inline code on at the caret closes the @ popup") {
        // The stored marks are what the next character takes on; with code
        // stored, the next keystroke is code, and an @ query there is literal.
        let editor = try Editor(extensions: fullKit(mentionSuggestions: { _ in ["jo"] }))
        try type(editor, "hi @jo")
        try expectEqual(editor.mentionSuggestion?.query, "jo")
        try expect(editor.run("toggleCode"))
        try expectNotNil(editor.state.storedMarks)
        try expectNil(editor.mentionSuggestion)
        // And the reverse: code text with code switched off at the caret.
        try expect(editor.run("toggleCode"))
        try expectEqual(editor.mentionSuggestion?.query, "jo")
    }
    // MARK: - Wiki links

    test("mutation kills: [[ Page ]] makes a link reading the trimmed target") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "see [[  Page  ]")
        try expect(textInput(editor, at: editor.state.selection.head, "]"))
        var link: Node?
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "wikiLink" { link = node }
            return true
        }
        try expectEqual(link.map(wikiLinkText), "Page")
        try expectEqual(editor.doc.child(0).childCount, 2) // "see " + the link, nothing left over
    }

    test("mutation kills: a closing bracket after [[ ends the query") {
        let editor = try Editor(extensions: fullKit(wikiLinkSuggestions: { _ in ["Page"] }))
        try type(editor, "see [[Pa")
        try expectEqual(editor.wikiLinkSuggestion?.query, "Pa")
        let closed = try Editor(extensions: fullKit(wikiLinkSuggestions: { _ in ["Page"] }))
        try type(closed, "see [[Pa]ge")
        try expectEqual(closed.state.selection.head, 12)
        try expectNil(closed.wikiLinkSuggestion)
    }
    // MARK: - Unique IDs

    test("mutation kills: a generated id keeps being redrawn while it collides") {
        // The generator offers the taken id twice in a row. The one transaction
        // that assigns ids must already leave them unique — not hand a duplicate
        // to a second round to clean up.
        let ids = ScriptedIDs([])
        let editor = try Editor(extensions: starterKit() + [
            UniqueIDExtension(types: ["paragraph"], generateID: { ids.next() })])
        let s = editor.schema
        editor.setContent(try mk(s, "doc", [:], [mk(s, "paragraph", ["id": .string("taken")], [s.text("a")])]))
        try expectEqual(editor.doc.child(0).attrs["id"]?.stringValue, "taken")
        ids.load(["taken", "taken", "fresh"])
        let state = editor.state
        let tr = state.tr
        try tr.insert(state.doc.content.size, para(s, "b"))
        let (after, transactions) = state.applyTransaction(tr)
        try expectEqual(transactions.count, 2)
        let found = (0..<after.doc.childCount).map { after.doc.child($0).attrs["id"]?.stringValue }
        try expectEqual(found, ["taken", "fresh"])
    }

    // MARK: - Typography

    test("mutation kills: a quote right after an opening curly quote opens too") {
        let editor = try Editor(extensions: starterKit() + [TypographyExtension()])
        try type(editor, "say \u{201C}")
        try expect(textInput(editor, at: editor.state.selection.head, "'"))
        try expectEqual(editor.doc.textContent, "say \u{201C}\u{2018}")
        let other = try Editor(extensions: starterKit() + [TypographyExtension()])
        try type(other, "say \u{2018}")
        try expect(textInput(other, at: other.state.selection.head, "\""))
        try expectEqual(other.doc.textContent, "say \u{2018}\u{201C}")
    }

    // MARK: - Command helpers

    test("mutation kills: isNodeActive checks a selected node's attributes") {
        let editor = try makeEditor()
        let s = editor.schema
        editor.setContent(try mk(s, "doc", [:], [
            mk(s, "heading", ["level": .int(1)], [s.text("Title")]), para(s, "body")]))
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 0)))
        let heading = s.nodes["heading"]!
        try expect(isNodeActive(editor.state, heading))
        try expect(isNodeActive(editor.state, heading, ["level": .int(1)]))
        try expect(!isNodeActive(editor.state, heading, ["level": .int(2)]))
    }

    // MARK: - Search

    test("mutation kills: a selection that only starts a match isn't on it") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "ab ab")
        editor.setSearch("ab")
        select(editor, 4, 5) // just the "a" of the second match
        try expect(editor.replaceCurrentMatch(with: "X"))
        try expectEqual(editor.doc.textContent, "X ab")
    }
    test("mutation kills: wrapping blocks in a list splits between them, never before the first") {
        // Items that may be empty, so a split before the first block would be
        // allowed — and would leave an empty leading item.
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "text*", group: "block")),
            ("text", NodeSpec(group: "inline")),
            ("bulletList", NodeSpec(content: "listItem+", group: "block")),
            ("listItem", NodeSpec(content: "block*")),
        ])
        let doc = try mk(schema, "doc", [:], [para(schema, "a"), para(schema, "b")])
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc,
            selection: TextSelection.create(doc, 1, textStart(doc, "b") + 1)))
        var out: Transaction?
        try expect(wrapInList(schema.nodes["bulletList"]!)(state, { out = $0 }, nil))
        let list = try required(out).doc.child(0)
        try expectEqual(list.type.name, "bulletList")
        try expectEqual((0..<list.childCount).map { list.child($0).textContent }, ["a", "b"])
    }
    for wiki in [false, true] {
        test("mutation kills: \(wiki ? "[[" : "@") isn't offered where text after the query couldn't follow the node") {
            let editor = try Editor(extensions: [DocumentExtension(), TrailingAtomParagraph(), TextExtension(),
                                                 MentionExtension(), WikiLinkExtension()])
            let s = editor.schema
            let query = wiki ? "see [[Pa" : "see @Pa"
            editor.setContent(try mk(s, "doc", [:], [mk(s, "paragraph", [:], [s.text(query + " tail")])]))
            let caret = 1 + query.count
            select(editor, caret, caret)
            try expect(wiki ? editor.wikiLinkSuggestion == nil : editor.mentionSuggestion == nil)
            // At the end, where the node may go, it is offered.
            let end = editor.doc.content.size - 1
            let tr = editor.state.tr
            try tr.delete(caret, end)
            editor.dispatch(tr)
            try expectEqual(editor.state.selection.head, caret)
            try expect(wiki ? editor.wikiLinkSuggestion != nil : editor.mentionSuggestion != nil)
        }
    }
    test("mutation kills: a space after the @ query closes it") {
        let editor = try Editor(extensions: fullKit(mentionSuggestions: { _ in ["jo"] }))
        try type(editor, "hi @jo e")
        try expectEqual(editor.state.selection.head, 9)
        try expectNil(editor.mentionSuggestion)
    }

    // MARK: - Details

    test("mutation kills: unwrapping details keeps a node selection on the first body block") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try mk(s, "doc", [:], [mk(s, "details", ["open": .bool(true)], [
            mk(s, "detailsSummary", [:], [s.text("t")]),
            mk(s, "detailsContent", [:], [mk(s, "horizontalRule"), para(s, "x")])])]))
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 5)))
        try expectEqual((editor.state.selection as? NodeSelection)?.node.type.name, "horizontalRule")
        try expect(editor.run("unsetDetails"))
        try expectEqual((0..<editor.doc.childCount).map { editor.doc.child($0).type.name },
                        ["paragraph", "horizontalRule", "paragraph"])
        let selected = editor.state.selection as? NodeSelection
        try expectEqual(selected?.node.type.name, "horizontalRule")
        try expectEqual(selected?.from, 3)
    }
}
