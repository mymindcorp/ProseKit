import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// The `Editor` dispatch notification contract: which of `onTransaction` /
// `onChange` / `onSelectionUpdate` fire, in what order, and how `chain` batches
// them.
//
// `onChange` is deliberately unconditional — it fires for selection-only
// transactions too, and `EditorTextView` depends on that to refresh selection
// geometry (it hangs `fireSelectionChange()` off `onChange`). Anything that
// narrowed it to document changes would break the caret silently, so it is
// pinned here. `onSelectionUpdate`'s own filtering lives in EditorContentAPI.

func registerEditorNotificationTests() {
    test("onChange fires for a selection-only transaction") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        let log = NotificationLog()
        editor.onChange = { _ in log.events.append("change") }
        select(editor, 1, 3)
        try expectEqual(log.events, ["change"], "a caret move must still notify")
    }

    test("onChange fires for a document change") {
        let editor = try Editor(extensions: starterKit())
        let log = NotificationLog()
        editor.onChange = { _ in log.events.append("change") }
        try type(editor, "hello")
        try expectEqual(log.events, ["change"])
    }

    test("onTransaction fires for both selection moves and edits, flagging docChanged") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        let log = NotificationLog()
        editor.onTransaction = { tr in log.events.append(tr.docChanged ? "doc" : "selection") }
        select(editor, 1, 3)
        try type(editor, "!")
        try expectEqual(log.events, ["selection", "doc"])
    }

    test("dispatch notifies onTransaction, then onChange, then onSelectionUpdate") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        let log = NotificationLog()
        editor.onTransaction = { _ in log.events.append("transaction") }
        editor.onChange = { _ in log.events.append("change") }
        editor.onSelectionUpdate = { _ in log.events.append("selection") }
        select(editor, 1, 3)
        try expectEqual(log.events, ["transaction", "change", "selection"])
    }

    test("dispatch skips onSelectionUpdate but still notifies the rest") {
        // An edit that leaves the selection where it was: the first two hooks
        // fire, the third does not.
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, 6)
        guard let bold = editor.schema.marks["bold"] else { try expect(false, "no bold mark"); return }
        let log = NotificationLog()
        editor.onTransaction = { _ in log.events.append("transaction") }
        editor.onChange = { _ in log.events.append("change") }
        editor.onSelectionUpdate = { _ in log.events.append("selection") }
        try expect(editor.run(toggleMark(bold)), "toggleMark should apply")
        try expectEqual(log.events, ["transaction", "change"])
    }

    // MARK: - chain

    test("chain notifies onTransaction per command but onChange once") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, 6)
        guard let bold = editor.schema.marks["bold"],
              let italic = editor.schema.marks["italic"] else {
            try expect(false, "starterKit should carry bold and italic"); return
        }
        let log = NotificationLog()
        editor.onTransaction = { _ in log.events.append("transaction") }
        editor.onChange = { _ in log.events.append("change") }
        try expect(editor.chain([toggleMark(bold), toggleMark(italic)]))
        try expectEqual(log.events, ["transaction", "transaction", "change"],
                        "one transaction per command, a single coalesced change")
    }

    test("chain notifies onSelectionUpdate once when the selection moved") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        let log = NotificationLog()
        editor.onSelectionUpdate = { _ in log.events.append("selection") }
        try expect(editor.chain([{ state, dispatch, _ in
            dispatch?(state.tr.setSelection(TextSelection.create(state.doc, 1, 3)))
            return true
        }]))
        try expectEqual(log.events, ["selection"])
    }

    test("chain notifies nothing when a command fails") {
        // `chain` is all-or-nothing: a failing command aborts before any state
        // is committed, so no hook should have seen the partial work.
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, 6)
        guard let bold = editor.schema.marks["bold"] else { try expect(false, "no bold mark"); return }
        let log = NotificationLog()
        editor.onTransaction = { _ in log.events.append("transaction") }
        editor.onChange = { _ in log.events.append("change") }
        let before = editor.getHTML()
        try expect(!editor.chain([toggleMark(bold), { _, _, _ in false }]), "chain should report failure")
        try expectEqual(log.events, [], "an aborted chain must not notify")
        try expectEqual(editor.getHTML(), before, "an aborted chain must not commit")
    }
}

private final class NotificationLog: @unchecked Sendable { var events: [String] = [] }
