import DocumentModel
import DocumentTransform
import EditorHistory
import EditorStateKit
import SchemaKit
import TestHarness

private final class BoundaryEvents: @unchecked Sendable { var count = 0 }

private func assertHistoryRoundTrip(_ editor: Editor, original: Node, selection: Selection, edited: Node) throws {
    try edited.check()
    try expectEqual(EditorHistory.undoDepth(editor.state), 1)
    try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
    try expectEqual(editor.doc, original)
    try expect(editor.state.selection.eq(selection))
    try expect(EditorHistory.redo(editor.state, { editor.dispatch($0) }))
    try expectEqual(editor.doc, edited)
    try editor.doc.check()
}

func registerBoundaryCoverageTests() {
    // Upper-bound clipping follows prosemirror-search 1.1.1 src/query.ts.
    // Lower bounds use lastIndex upstream; they do not create regex anchors.
    let searches: [(String, String, String, Int, Int, [[Int]])] = [
        ("start anchor ignores a range start inside the block", "cat cat", "^cat", 5, 8, []),
        ("end anchor uses the requested upper bound", "cat dog", "cat$", 1, 4, [[1, 4]]),
        ("positive lookbehind sees text before the range", "a cat", "(?<=a )cat", 3, 6, [[3, 6]]),
        ("positive lookahead cannot see beyond the upper bound", "cat!", "cat(?=!)", 1, 4, []),
        ("negative lookbehind sees text before the range", "a cat", "(?<!a )cat", 3, 6, []),
        ("negative lookahead uses the requested upper bound", "cat!", "cat(?!!)", 1, 4, [[1, 4]]),
        ("word start is not created by clipping the range", "scat", "\\bcat", 2, 5, []),
        ("word end uses the requested upper bound", "cats", "cat\\b", 1, 4, [[1, 4]]),
        ("zero-width lookaheads never become highlights", "cat cat", "(?=cat)", 1, 8, []),
        ("anchors still recognize a complete block", "cat", "^cat$", 1, 4, [[1, 4]]),
        ("consuming matches cannot extend beyond the range", "cats", "cats", 1, 4, []),
        ("lookahead respects the upper bound after emoji", "🙂 cat!", "cat(?=!)", 3, 6, [])
    ]
    for (name, text, pattern, from, to, expected) in searches {
        test("boundary coverage: " + name) {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<p>" + text + "</p>")
            let query = SearchQuery(search: pattern, regexp: true)
            try expect(query.valid)
            try expectEqual(query.findNext(editor.state, from, to).map { [$0.from, $0.to] }, expected.first)
            try expectEqual(query.findPrev(editor.state, to, from).map { [$0.from, $0.to] }, expected.last)
            try expectEqual(query.findAll(editor.state, from, to).map { [$0.from, $0.to] }, expected)
            editor.dispatch(setSearchState(editor.state.tr, query, SearchRange(from: from, to: to)))
            try expectEqual(editor.searchMatches.map { [$0.from, $0.to] }, expected)
            try expectEqual(searchQueryKey.getState(editor.state)!.deco.find().map { [$0.from, $0.to] }, expected)
            let original = editor.doc
            let replaced = editor.replaceAllMatches(with: "X")
            try expectEqual(replaced, expected.count)
            if expected.isEmpty {
                try expectEqual(editor.doc, original)
                try expectEqual(EditorHistory.undoDepth(editor.state), 0)
            } else {
                try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
                try expectEqual(editor.doc, original)
            }
        }
    }

    for wiki in [true, false] {
        let name = wiki ? "wiki link" : "mention"
        let trigger = wiki ? "[[Page" : "@jane"
        test("boundary coverage: \(name) acceptance restores the query and selection on undo") {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<p>before " + trigger + " after</p>")
            let from = 8, to = from + trigger.count
            select(editor, from, to)
            let original = editor.doc, selection = editor.state.selection
            let accepted = wiki
                ? editor.acceptWikiLinkSuggestion(text: "Page", from: from, to: to)
                : editor.acceptMentionSuggestion(id: "jane", from: from, to: to)
            try expect(accepted)
            try expectEqual(editor.doc.firstChild?.child(0).text, "before ")
            try expectEqual(editor.doc.firstChild?.child(1).type.name, wiki ? "wikiLink" : "mention")
            try expectEqual(editor.doc.firstChild?.child(2).text, " after")
            try assertHistoryRoundTrip(editor, original: original, selection: selection, edited: editor.doc)
        }
        test("boundary coverage: \(name) explicit target survives a caret move to another paragraph") {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<p>" + trigger + "</p><p>untouched</p>")
            let before = editor.doc
            select(editor, editor.doc.content.size - 1, editor.doc.content.size - 1)
            let selection = editor.state.selection
            let accepted = wiki
                ? editor.acceptWikiLinkSuggestion(text: "Page", from: 1, to: 1 + trigger.count)
                : editor.acceptMentionSuggestion(id: "jane", from: 1, to: 1 + trigger.count)
            try expect(accepted)
            try expectEqual(editor.doc.child(0).firstChild?.type.name, wiki ? "wikiLink" : "mention")
            try expectEqual(editor.doc.child(1), before.child(1))
            try assertHistoryRoundTrip(editor, original: before, selection: selection, edited: editor.doc)
        }
        test("boundary coverage: rejected \(name) replacement has no notifications or history") {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<pre><code>" + trigger + "</code></pre>")
            let original = editor.state, revision = editor.docRevision
            let events = BoundaryEvents()
            editor.onChange = { _ in events.count += 1 }
            editor.onTransaction = { _ in events.count += 1 }
            let accepted = wiki
                ? editor.acceptWikiLinkSuggestion(text: "Page", from: 1, to: 1 + trigger.count)
                : editor.acceptMentionSuggestion(id: "jane", from: 1, to: 1 + trigger.count)
            try expect(!accepted)
            try expect(editor.state === original)
            try expectEqual(editor.docRevision, revision)
            try expectEqual(events.count, 0)
            try expectEqual(EditorHistory.undoDepth(editor.state), 0)
        }
    }

    for (name, position) in [("start", 1), ("middle", 3), ("end", 5)] {
        test("boundary coverage: table insertion at paragraph \(name) restores text and caret on undo") {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<p>abcd</p>")
            select(editor, position, position)
            let original = editor.doc, selection = editor.state.selection
            try expect(editor.insertTable(rows: 2, cols: 2))
            try expectEqual(count(editor.doc, "table"), 1)
            try expectEqual(count(editor.doc, "tableHeader"), 2)
            try expectEqual(count(editor.doc, "tableCell"), 2)
            try expectEqual(editor.doc.textContent, "abcd")
            try assertHistoryRoundTrip(editor, original: original, selection: selection, edited: editor.doc)
        }
    }
    test("boundary coverage: deleting a selected table restores its content and node selection on undo") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<p>keep</p><table><tr><th>A</th><td>B</td></tr></table>")
        let pos = editor.doc.child(0).nodeSize
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, pos)))
        let original = editor.doc, selection = editor.state.selection
        try expect(editor.run(deleteTable))
        try expectEqual(editor.doc.textContent, "keep")
        try expectEqual(count(editor.doc, "table"), 0)
        try assertHistoryRoundTrip(editor, original: original, selection: selection, edited: editor.doc)
    }
    for wrapper in ["details", "figure"] {
        test("boundary coverage: unwrapping selected \(wrapper) preserves rich content through history") {
            let editor = try Editor(extensions: fullKit() + figureExtensions())
            let html = wrapper == "details"
                ? "<details open><summary><strong>Title</strong></summary><div data-type=\"detailsContent\"><p>Body</p></div></details>"
                : "<figure><p>Body</p><figcaption><strong>Title</strong></figcaption></figure>"
            try editor.setContent(html: html)
            editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 0)))
            let original = editor.doc, selection = editor.state.selection
            try expectEqual(original.firstChild?.type.name, wrapper)
            try expect(editor.run(wrapper == "details" ? "unsetDetails" : "unsetFigure"))
            try expectEqual(count(editor.doc, wrapper), 0)
            try expectEqual(editor.doc.textContent, original.textContent)
            let titleIndex = wrapper == "details" ? 0 : 1
            try expect(editor.doc.child(titleIndex).firstChild!.marks.contains { $0.type.name == "bold" })
            try assertHistoryRoundTrip(editor, original: original, selection: selection, edited: editor.doc)
        }
    }
    for nodeSelection in [false, true] {
        test("boundary coverage: task sorting restores \(nodeSelection ? "node" : "text") selection on undo") {
            let editor = try Editor(extensions: fullKit(taskListOptions: TaskListOptions(sortCompletedToBottom: true)))
            try editor.setContent(html: "<ul data-type=\"taskList\"><li data-type=\"taskItem\"><p>First</p></li><li data-type=\"taskItem\"><p>Second</p></li></ul>")
            if nodeSelection {
                editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 1)))
            } else {
                select(editor, 4, 6)
            }
            let original = editor.doc, selection = editor.state.selection
            try expect(editor.run("toggleTaskChecked"))
            try expectEqual(editor.doc.firstChild?.child(0).textContent, "Second")
            try expectEqual(editor.doc.firstChild?.child(1).textContent, "First")
            if nodeSelection {
                try expectEqual((editor.state.selection as? NodeSelection)?.node.textContent, "First")
            } else {
                try expectEqual(editor.state.selection.resolvedFrom.parent.textContent, "First")
                try expectEqual(editor.state.selection.resolvedFrom.parentOffset, 1)
                try expectEqual(editor.state.selection.resolvedTo.parentOffset, 3)
            }
            try assertHistoryRoundTrip(editor, original: original, selection: selection, edited: editor.doc)
        }
    }
}
