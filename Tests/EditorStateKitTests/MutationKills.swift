import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import TestHarness

// Tests written to kill mutants that survived the rest of this suite: each pins
// a branch of the selection, transaction or state code whose behaviour could be
// changed without anything failing. Expected results follow upstream
// prosemirror-state and prosemirror-gapcursor.

// An isolating wrapper (like a table cell) and an atom block with content
// (like a figure whose caption is edited elsewhere).
private let mkSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "(paragraph | iso | figure)+")),
    ("paragraph", NodeSpec(content: "text*")),
    ("iso", NodeSpec(content: "(paragraph | rule)+", isolating: true)),
    ("rule", NodeSpec()),
    ("figure", NodeSpec(content: "text*", atom: true)),
    ("text", NodeSpec()),
], marks: [("em", MarkSpec())], topNode: "doc")
private func n(_ type: String, _ children: Node...) -> Node {
    try! mkSchema.node(type, [:], content: Fragment.from(children))
}
private func t(_ type: String, _ s: String) -> Node {
    try! mkSchema.node(type, [:], content: Fragment.from(s.isEmpty ? [] : [mkSchema.text(s)]))
}

private let inlineDocSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "text*")),
    ("text", NodeSpec()),
], topNode: "doc")

private func state(_ d: Node, _ sel: Selection? = nil, plugins: [Plugin] = [], schema: Schema = basicSchema) -> EditorState {
    EditorState.create(EditorStateConfig(schema: schema, doc: d, selection: sel, plugins: plugins))
}

func registerStateMutationKillTests() {
    func m(_ name: String, _ body: @escaping @Sendable () throws -> Void) { test("mutation state: \(name)") { try body() } }

    // MARK: Selections

    m("TextSelection.map moves an anchor that lands between blocks onto the head") {
        // Upstream: `new TextSelection($anchor.parent.inlineContent ? $anchor : $head, $head)`.
        let d = doc(p("ab"), p("cd")).node
        let s = state(d, TextSelection.create(d, 2, 6))
        let tr = s.tr
        _ = try tr.delete(0, 4)
        let sel = tr.selection
        try expect(sel is TextSelection)
        try expectEqual(sel.head, 2)
        try expectEqual(sel.anchor, 2)
    }

    m("TextSelection.eq compares the anchor as well as the head") {
        let d = doc(p("abcd")).node
        try expect(!TextSelection.create(d, 1, 3).eq(TextSelection.create(d, 2, 3)))
        try expect(TextSelection.create(d, 1, 3).eq(TextSelection.create(d, 1, 3)))
    }

    m("GapCursor.eq compares positions") {
        let d = doc(hr(), hr(), hr()).node
        try expect(!GapCursor(d.resolve(1)).eq(GapCursor(d.resolve(2))))
        try expect(GapCursor(d.resolve(1)).eq(GapCursor(d.resolve(1))))
    }

    m("searching backwards selects the whole of an atom block with content") {
        let fig = t("figure", "caption")
        let d = n("doc", t("paragraph", "a"), fig)
        let sel = Selection.atEnd(d)
        try expect(sel is NodeSelection, "expected a node selection, got \(type(of: sel))")
        try expectEqual(sel.from, 3)
        try expectEqual(sel.to, 3 + fig.nodeSize)
    }

    // MARK: Gap cursor

    m("a gap cursor is valid between two isolating blocks") {
        let d = n("doc", n("iso", t("paragraph", "a")), n("iso", t("paragraph", "b")))
        try expect(GapCursor.valid(d.resolve(5)))
    }

    m("a gap cursor is valid at the start of an isolating block") {
        // At index 0 of an isolating parent the search stops: what comes
        // before the parent doesn't matter.
        let d = n("doc", t("paragraph", "a"), n("iso", n("rule"), t("paragraph", "b")))
        try expect(GapCursor.valid(d.resolve(4)))
    }

    m("a gap bookmark stays after content inserted at its position") {
        let d = doc(hr(), hr()).node
        let s = state(d, GapCursor(d.resolve(1)))
        let tr = s.tr
        _ = try tr.insert(1, basicSchema.node("paragraph"))
        let mapped = GapCursor(d.resolve(1)).getBookmark().map(tr.mapping)
        try expectEqual((mapped as? GapBookmark)?.pos, 3)
    }

    m("the gap cursor arrow keys ignore a text cursor directly in the document") {
        let d = try! inlineDocSchema.node("doc", [:], content: Fragment.from([inlineDocSchema.text("ab")]))
        let s = state(d, TextSelection.create(d, 2), plugins: [gapCursor()], schema: inlineDocSchema)
        let handle = s.plugins[0].props!.handleKeyDown!
        try expect(!handle("ArrowRight", s, nil))
        let s0 = state(d, TextSelection.create(d, 0), plugins: [gapCursor()], schema: inlineDocSchema)
        try expect(!handle("ArrowLeft", s0, nil))
    }

    // MARK: Stored marks

    m("stored marks are dropped when the new selection is a range") {
        let d = doc(p("abc")).node
        let s = state(d, TextSelection.create(d, 1, 3))
        let em = basicSchema.marks["em"]!.create()
        let next = s.apply(s.tr.setStoredMarks([em]))
        try expectNil(next.storedMarks)
        let cursor = state(d, TextSelection.create(d, 2))
        try expectEqual(cursor.apply(cursor.tr.setStoredMarks([em])).storedMarks?.count, 1)
    }

    m("a step clears the transaction's stored marks") {
        let d = doc(p("abc")).node
        let s = state(d, TextSelection.create(d, 2))
        let tr = s.tr.setStoredMarks([basicSchema.marks["em"]!.create()])
        try expect(tr.storedMarksSet)
        _ = try tr.insert(1, basicSchema.text("x"))
        try expectNil(tr.storedMarks)
        try expect(!tr.storedMarksSet)
        try expectNil(s.apply(tr).storedMarks)
    }

    m("ensureMarks leaves stored marks alone when they match the cursor") {
        let d = doc(p(em("abc"))).node
        let s = state(d, TextSelection.create(d, 2))
        let tr = s.tr.ensureMarks([basicSchema.marks["em"]!.create()])
        try expect(!tr.storedMarksSet)
        try expectNil(tr.storedMarks)
        let tr2 = s.tr.ensureMarks([])
        try expect(tr2.storedMarksSet)
        try expectEqual(tr2.storedMarks?.count, 0)
    }

    m("deleting marked text keeps its marks for the next input") {
        let d = doc(p("a", em("bcd"), "e")).node
        let s = state(d, TextSelection.create(d, 2, 5))
        let next = s.apply(s.tr.deleteSelection())
        try expectEqual(next.doc, doc(p("ae")).node)
        try expectEqual(next.storedMarks?.map(\.type.name), ["em"])
    }

    // MARK: appendTransaction / filterTransaction

    m("appended transactions inherit the root transaction's time") {
        let appender = Plugin(appendTransaction: { trs, _, state in
            trs[0].getMeta("append") != nil && trs.count == 1 ? try! state.tr.insertText("A", 1) : nil
        })
        let s = state(doc(p("x")).node, plugins: [appender])
        let root = try! s.tr.insertText("y", 2).setMeta("append", true)
        root.time = 1234
        let result = s.applyTransaction(root)
        try expectEqual(result.transactions.count, 2)
        try expectEqual(result.transactions[1].time, 1234)
    }

    m("other plugins' filters apply to appended transactions") {
        let appender = Plugin(appendTransaction: { trs, _, state in
            trs[0].getMeta("append") != nil && trs.count == 1
                ? try! state.tr.insertText("A", 1).setMeta("appended", true) : nil
        })
        let filter = Plugin(filterTransaction: { tr, _ in tr.getMeta("appended") == nil })
        let s = state(doc(p("x")).node, plugins: [appender, filter])
        let result = s.applyTransaction(try! s.tr.insertText("y", 2).setMeta("append", true))
        try expectEqual(result.transactions.count, 1)
        try expectEqual(result.state.doc, doc(p("xy")).node)
    }

    m("a plugin's own filter doesn't apply to the transaction it appends") {
        // Upstream passes the appending plugin's index as `ignore`.
        let plugin = Plugin(
            appendTransaction: { trs, _, state in
                trs[0].getMeta("append") != nil && trs.count == 1
                    ? try! state.tr.insertText("A", 1).setMeta("appended", true) : nil
            },
            filterTransaction: { tr, _ in tr.getMeta("appended") == nil })
        let s = state(doc(p("x")).node, plugins: [plugin])
        let result = s.applyTransaction(try! s.tr.insertText("y", 2).setMeta("append", true))
        try expectEqual(result.transactions.count, 2)
        try expectEqual(result.state.doc, doc(p("Axy")).node)
    }

    m("a plugin asked again is only shown the transactions it hasn't seen") {
        // Upstream calls appendTransaction with `n ? trs.slice(n) : trs`. The
        // watcher only acts on a batch of two, which it never receives.
        let watcher = Plugin(appendTransaction: { trs, _, state in
            trs.count == 2 ? try! state.tr.insertText("W", 1) : nil
        })
        let appender = Plugin(appendTransaction: { trs, _, state in
            trs[0].getMeta("append") != nil ? try! state.tr.insertText("A", 1) : nil
        })
        let s = state(doc(p("x")).node, plugins: [watcher, appender])
        let result = s.applyTransaction(try! s.tr.insertText("y", 2).setMeta("append", true))
        try expectEqual(result.state.doc, doc(p("Axy")).node)
        try expectEqual(result.transactions.count, 2)
    }
}
