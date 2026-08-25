import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import TestHarness

// Ported from prosemirror-state/test/test-state.ts. Skipped (no local
// equivalent): the EditorState toJSON/fromJSON round-trip cases — this port has
// no state-level JSON serialization (documents serialize via DocumentJSON) —
// and the `testProp`-bound-to-plugin case (props here are plain closures, not
// this-bound methods).

private let countKey = PluginKey<Int>("messageCount")
private func countPlugin() -> Plugin {
    Plugin(key: countKey.key, stateField: PluginStateField(
        initialize: { _, _ in 0 },
        apply: { _, value, _, _ in (value as! Int) + 1 }))
}

private func transactionPlugin() -> Plugin {
    Plugin(
        appendTransaction: { trs, _, state in
            guard let last = trs.last, last.getMeta("append") != nil else { return nil }
            return try! state.tr.insertText("A")
        },
        filterTransaction: { tr, _ in tr.getMeta("filtered") == nil })
}

func registerPMStateTests() {
    test("PM state: creates a default doc") {
        let state = EditorState.create(EditorStateConfig(schema: basicSchema))
        try expectEqual(state.doc, doc(p()).node)
    }

    test("PM state: creates a default selection") {
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: doc(p("foo")).node))
        try expectEqual(state.selection.from, 1)
        try expectEqual(state.selection.to, 1)
    }

    test("PM state: applies transform transactions") {
        let state = EditorState.create(EditorStateConfig(schema: basicSchema))
        let newState = state.apply(try! state.tr.insertText("hi"))
        try expectEqual(state.doc, doc(p()).node)
        try expectEqual(newState.doc, doc(p("hi")).node)
        try expectEqual(newState.selection.from, 3)
    }

    test("PM state: supports plugin fields") {
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, plugins: [countPlugin()]))
        let newState = state.apply(state.tr).apply(state.tr)
        try expectEqual(countKey.getState(state), 0)
        try expectEqual(countKey.getState(newState), 2)
    }

    test("PM state: supports specifying storedMarks") {
        let state = EditorState.create(EditorStateConfig(
            schema: basicSchema, doc: doc(p("ok")).node, storedMarks: [basicSchema.mark("em")]))
        try expectEqual(state.storedMarks?.count, 1)
    }

    test("PM state: supports reconfiguration") {
        let plugin = countPlugin()
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, plugins: [plugin]))
        try expectEqual(countKey.getState(state), 0)
        let without = state.reconfigure(plugins: [])
        try expectNil(countKey.getState(without))
        try expectEqual(without.plugins.count, 0)
        try expectEqual(without.doc, doc(p()).node)
        let reAdd = without.reconfigure(plugins: [plugin])
        try expectEqual(countKey.getState(reAdd), 0)
        try expectEqual(reAdd.plugins.count, 1)
    }

    test("PM state: allows plugins to filter transactions") {
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, plugins: [transactionPlugin()]))
        var applied = state.applyTransaction(try! state.tr.insertText("X"))
        try expectEqual(applied.state.doc, doc(p("X")).node)
        try expectEqual(applied.transactions.count, 1)
        applied = state.applyTransaction(try! state.tr.insertText("Y").setMeta("filtered", true))
        try expectEqual(applied.state.doc, state.doc)
        try expectEqual(applied.transactions.count, 0)
    }

    test("PM state: allows plugins to append transactions") {
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, plugins: [transactionPlugin()]))
        let applied = state.applyTransaction(try! state.tr.insertText("X").setMeta("append", true))
        try expectEqual(applied.state.doc, doc(p("XA")).node)
        try expectEqual(applied.transactions.count, 2)
    }

    test("PM state: stores a reference to a root transaction for appended transactions") {
        let appender = Plugin(appendTransaction: { _, _, newState in try! newState.tr.insertText("Y") })
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, plugins: [appender]))
        let (_, transactions) = state.applyTransaction(try! state.tr.insertText("X"))
        try expectEqual(transactions.count, 2)
        try expect(transactions[1].getMeta("appendedTransaction") as? Transaction === transactions[0])
    }

    // A plugin that runs after one which appends still has to be shown the
    // transaction the round started from. Handing it only the appended one made
    // an `appendTransaction` that asks "did the document change?" answer no.
    test("PM state: a later plugin sees the root transaction an earlier one responded to") {
        final class Seen: @unchecked Sendable { var rounds: [[Bool]] = [] }
        let seen = Seen()
        let appender = Plugin(appendTransaction: { trs, _, newState in
            // Once, and with no document change of its own.
            guard !trs.contains(where: { $0.getMeta("appended") != nil }) else { return nil }
            return newState.tr.setMeta("appended", true)
        })
        let watcher = Plugin(appendTransaction: { trs, _, _ in
            seen.rounds.append(trs.map(\.docChanged))
            return nil
        })
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, plugins: [appender, watcher]))
        _ = state.applyTransaction(try! state.tr.insertText("X"))
        try expectEqual(seen.rounds.first ?? [], [true, false])
    }

    // The state a plugin is handed as `oldState` has to be the one its slice of
    // transactions starts from — for a plugin that already saw them all, that is
    // the state after them, not the state the round began in.
    test("PM state: an earlier plugin's oldState keeps up with what it has seen") {
        final class Seen: @unchecked Sendable { var olds: [String] = []; var news: [String] = [] }
        let seen = Seen()
        let watcher = Plugin(appendTransaction: { _, oldState, newState in
            seen.olds.append(oldState.doc.textContent)
            seen.news.append(newState.doc.textContent)
            return nil
        })
        let appender = Plugin(appendTransaction: { trs, _, newState in
            guard !trs.contains(where: { $0.getMeta("appended") != nil }) else { return nil }
            return try! newState.tr.insertText("Y").setMeta("appended", true)
        })
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: doc(p()).node,
                                                        plugins: [watcher, appender]))
        _ = state.applyTransaction(try! state.tr.insertText("X"))
        // Round one: the watcher runs before the appender, so it sees only "X".
        try expectEqual(seen.olds.first, "")
        try expectEqual(seen.news.first, "X")
        // Round two: it is asked again about the appended transaction alone, so
        // the state that transaction started from is the one holding "X".
        try expectEqual(seen.olds.count, 2)
        try expectEqual(seen.olds[1], "X")
        try expectEqual(seen.news[1], "XY")
    }

    test("PM plugin: generates new keys") {
        let p1 = Plugin(), p2 = Plugin()
        try expect(p1.key != p2.key)
        let k1 = PluginKey<Int>("foo"), k2 = PluginKey<Int>("foo")
        try expect(k1.key != k2.key)
    }

    test("PM plugin: can be found by key") {
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, plugins: [countPlugin()]))
        try expectEqual(countKey.getState(state), 0)
    }
}
