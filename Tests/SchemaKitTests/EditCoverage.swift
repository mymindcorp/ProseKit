import DocumentModel
import DocumentTransform
import EditorCommands
import EditorHistory
import EditorInputRules
import EditorStateKit
import SchemaKit
import TestHarness

private final class EditCoverageLog: @unchecked Sendable {
    var transactions: [String] = []
    var times: [Double] = []
    var changes = 0
    var selections = 0
}

private final class EditCoverageExtension: Extension {
    let name = "editCoverage"
    let appendedTime: Double
    init(appendedTime: Double = 0) { self.appendedTime = appendedTime }
    func plugins(_ ctx: ExtensionContext) -> [Plugin] {
        let time = appendedTime
        return [Plugin(key: name,
            appendTransaction: { transactions, _, state in
                guard transactions.contains(where: { ($0.getMeta("coverageAppend") as? Bool) == true }) else { return nil }
                guard let tr = try? state.tr.insertText("!", state.doc.content.size - 1) else { return nil }
                tr.time = time
                return tr
            },
            filterTransaction: { tr, _ in (tr.getMeta("coverageReject") as? Bool) != true })]
    }
}

func registerEditCoverageTests() {
    test("edit coverage: appended transactions inherit unset times but keep explicit timestamps") {
        for appendedTime in [0.0, 10_020.0] {
            let editor = try Editor(extensions: starterKit() + [EditCoverageExtension(appendedTime: appendedTime)])
            let log = EditCoverageLog()
            editor.onTransaction = { log.times.append($0.time) }
            let tr = try editor.state.tr.insertText("x", 1)
            tr.time = 10_000
            tr.setMeta("coverageAppend", true)
            editor.dispatch(tr)
            try expectEqual(log.times, [10_000, appendedTime == 0 ? 10_000 : appendedTime])
            try expectEqual(editor.doc.textContent, "x!")
            let next = try editor.state.tr.insertText("y", 3)
            next.time = 11_000
            editor.dispatch(next)
            try expectEqual(EditorHistory.undoDepth(editor.state), 2, "a later edit still starts a new history event")
            try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
            try expectEqual(editor.doc.textContent, "x!")
        }
    }

    test("edit coverage: adjacent chained commands see appended edits and undo as one event") {
        let editor = try Editor(extensions: starterKit() + [EditCoverageExtension()])
        let original = editor.doc
        let selection = editor.state.selection
        let revision = editor.docRevision
        let log = EditCoverageLog()
        editor.onTransaction = { log.transactions.append($0.doc.textContent) }
        editor.onChange = { _ in log.changes += 1 }
        editor.onSelectionUpdate = { _ in log.selections += 1 }
        try expect(editor.chain([
            { state, dispatch, _ in
                guard let tr = try? state.tr.insertText("one", 1) else { return false }
                tr.time = 10_000
                dispatch?(tr.setMeta("coverageAppend", true)); return true
            },
            { state, dispatch, _ in
                guard state.doc.textContent == "one!",
                      let tr = try? state.tr.insertText("?", state.doc.content.size - 2) else { return false }
                tr.time = 10_001
                dispatch?(tr); return true
            }
        ]))
        try expectEqual(editor.doc.textContent, "one?!")
        try expectEqual(log.transactions, ["one", "one!", "one?!"])
        try expectEqual(log.changes, 1)
        try expectEqual(log.selections, 1)
        try expectEqual(editor.docRevision, revision + 1)
        try expectEqual(EditorHistory.undoDepth(editor.state), 1)
        try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
        try expectEqual(editor.doc, original)
        try expect(editor.state.selection.eq(selection))
        try expect(EditorHistory.redo(editor.state, { editor.dispatch($0) }))
        try expectEqual(editor.doc.textContent, "one?!")
    }

    test("edit coverage: rejected chains discard appended edits and preserve input-rule undo") {
        for filtered in [false, true] {
            let editor = try Editor(extensions: fullKit() + [EditCoverageExtension()])
            try type(editor, "#")
            try expect(textInput(editor, at: 2, " "))
            try expect(undoInputRule(editor.state, nil))
            let original = editor.state
            let revision = editor.docRevision
            let depth = EditorHistory.undoDepth(original)
            let log = EditCoverageLog()
            editor.onTransaction = { log.transactions.append($0.doc.textContent) }
            editor.onChange = { _ in log.changes += 1 }
            editor.onSelectionUpdate = { _ in log.selections += 1 }
            try expect(!editor.chain([
                { state, dispatch, _ in
                    guard let tr = try? state.tr.insertText("x", 1) else { return false }
                    dispatch?(tr.setMeta("coverageAppend", true)); return true
                },
                { state, dispatch, _ in
                    guard filtered else { return false }
                    dispatch?(state.tr.setMeta("coverageReject", true)); return true
                }
            ]))
            try expect(editor.state === original)
            try expectEqual(editor.docRevision, revision)
            try expectEqual(EditorHistory.undoDepth(editor.state), depth)
            try expectEqual(log.transactions, [])
            try expectEqual(log.changes, 0)
            try expectEqual(log.selections, 0)
            try expect(undoInputRule(editor.state, { editor.dispatch($0) }))
            try expectEqual(editor.doc.firstChild?.type.name, "paragraph")
            try expectEqual(editor.doc.textContent, "# ")
        }
    }

    // Exercise all input-event splits, rather than only the final delimiter:
    // keyboard composition, paste, and selected-text replacement deliver different
    // portions of the shortcut to the same public input handler.
    for (delimiter, mark) in [("**", "bold"), ("__", "bold"), ("*", "italic"), ("_", "italic"),
                              ("~~", "strike"), ("==", "highlight"), ("`", "code")] {
        test("edit coverage: \(delimiter) shortcuts preserve text across event splits and undo") {
            for inner in ["hello", "e\u{0301}🙂", "漢字"] {
                let literal = delimiter + inner + delimiter
                let characters = Array(literal)
                for split in 0..<characters.count {
                    for replacing in [false, true] {
                        let editor = try Editor(extensions: fullKit())
                        let s = editor.schema
                        let prefix = String(characters[..<split])
                        let incoming = String(characters[split...])
                        let discarded = replacing ? "OLD" : ""
                        let doc = try s.node("doc", content: Fragment.from(
                            try s.node("paragraph", content: Fragment.from(s.text(prefix + discarded + " tail")))))
                        editor.setContent(doc)
                        let from = prefix.count + 1, to = from + discarded.count
                        select(editor, from, to)
                        var handled = false
                        for plugin in editor.state.plugins {
                            if plugin.props?.handleTextInput?(from, to, incoming, editor.state, { editor.dispatch($0) }) == true {
                                handled = true
                                break
                            }
                        }
                        let context = "\(literal.debugDescription), split \(split), replacing=\(replacing)"
                        try expect(handled, context)
                        let expected = try s.node("doc", content: Fragment.from(
                            try s.node("paragraph", content: Fragment.from([
                                s.text(inner, [s.marks[mark]!.create()]), s.text(" tail")
                            ]))))
                        try expectEqual(editor.doc, expected, context)
                        try expectEqual(editor.state.selection.from, inner.count + 1, context)
                        try expect(editor.state.selection.empty, context)
                        try expect(undoInputRule(editor.state, { editor.dispatch($0) }), context)
                        let restored = try s.node("doc", content: Fragment.from(
                            try s.node("paragraph", content: Fragment.from(s.text(literal + " tail")))))
                        try expectEqual(editor.doc, restored, context)
                        try expect(!undoInputRule(editor.state, nil), context)
                        try editor.doc.check()
                    }
                }
            }
        }
    }
}
