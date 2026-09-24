import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCollab
import TestHarness

// Assertions that pin behaviour the convergence tests pass through without
// checking: the version of a state with no collab plugin, the no-op
// transaction for an echo of only our own steps, and which side of a
// backward-mapped selection lands where.

private func paragraphDoc(_ text: String) -> Node {
    try! schema.node("doc", [:], content: Fragment.from([
        try! schema.node("paragraph", [:], content: text.isEmpty ? .empty : Fragment.from([schema.text(text)])),
    ]))
}

func registerCollabMutationKillTests() {
    test("collab kills: a state without the collab plugin is at version 0 and has nothing to send") {
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: paragraphDoc("ab")))
        try expectEqual(getVersion(state), 0)
        try expectNil(sendableSteps(state))
    }

    test("collab kills: an echo of only our own leading steps confirms them without touching the document") {
        var state = EditorState.create(EditorStateConfig(
            schema: schema, doc: paragraphDoc(""), plugins: [collab(clientID: 7)]))
        var tr = state.tr
        try tr.insertText("a", 1)
        state = state.apply(tr)
        tr = state.tr
        try tr.insertText("b", 2)
        state = state.apply(tr)
        let sent = sendableSteps(state)!
        try expectEqual(sent.steps.count, 2)

        // The authority confirms just the first of our two steps.
        let echo = receiveTransaction(state, [sent.steps[0]], [7])
        // Upstream returns a bare transaction here: no steps (nothing is
        // undone and redone), and none of the rebase bookkeeping metadata.
        try expectEqual(echo.steps.count, 0)
        try expect(!echo.docChanged)
        try expectNil(echo.getMeta("rebased"))
        try expectNil(echo.getMeta("addToHistory"))
        state = state.apply(echo)
        try expectEqual(state.doc.textContent, "ab")
        try expectEqual(getVersion(state), 1)
        let rest = sendableSteps(state)!
        try expectEqual(rest.version, 1)
        try expectEqual(rest.steps.count, 1)
    }

    test("collab kills: mapSelectionBackward keeps both sides of a caret before remote text") {
        let doc = paragraphDoc("ab")
        let state = EditorState.create(EditorStateConfig(
            schema: schema, doc: doc, selection: TextSelection.create(doc, 2),
            plugins: [collab(clientID: 1)]))
        let remote = state.tr
        try remote.insertText("X", 2)
        let tr = receiveTransaction(state, remote.steps, [2], mapSelectionBackward: true)
        try expectEqual(tr.doc.textContent, "aXb")
        try expectEqual(tr.selection.anchor, 2)
        try expectEqual(tr.selection.head, 2)
        try expect(tr.selection.empty)
    }

    test("collab kills: mapSelectionBackward maps a range's anchor with backward bias too") {
        let doc = paragraphDoc("abcd")
        // Anchor at 2, head at 4; remote text lands exactly at the anchor.
        let state = EditorState.create(EditorStateConfig(
            schema: schema, doc: doc, selection: TextSelection.create(doc, 2, 4),
            plugins: [collab(clientID: 1)]))
        let remote = state.tr
        try remote.insertText("XY", 2)
        let tr = receiveTransaction(state, remote.steps, [2], mapSelectionBackward: true)
        try expectEqual(tr.selection.anchor, 2)
        try expectEqual(tr.selection.head, 6)
        // Without the option the anchor maps forward, past the inserted text.
        let plain = receiveTransaction(state, remote.steps, [2])
        try expectEqual(plain.selection.anchor, 4)
        try expectEqual(plain.selection.head, 6)
    }
}
