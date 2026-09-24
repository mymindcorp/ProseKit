import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorHistory
import TestHarness

// Tests written to kill mutants that survived the rest of this suite: each pins
// a branch of the history or command code whose behaviour could be changed
// without anything failing. Expected results follow upstream
// prosemirror-history / prosemirror-commands.

// MARK: - Helpers

private func histState(_ d: TaggedNode? = nil, _ options: HistoryOptions = HistoryOptions(),
                       plugins extra: [Plugin] = []) -> EditorState {
    EditorState.create(EditorStateConfig(schema: basicSchema, doc: d?.node, plugins: [history(options)] + extra))
}
private func typed(_ state: EditorState, _ text: String, at time: Double? = nil) -> EditorState {
    let tr = try! state.tr.insertText(text)
    if let time { tr.time = time }
    return state.apply(tr)
}
private func run(_ state: EditorState, _ cmd: (EditorState, ((Transaction) -> Void)?) -> Bool) -> EditorState {
    var s = state
    _ = cmd(s, { tr in s = s.apply(tr) })
    return s
}
private func text(_ s: String) -> Slice {
    Slice(content: Fragment.from([basicSchema.text(s)]), openStart: 0, openEnd: 0)
}

/// Run a command; returns whether it applied and the resulting state.
private func exec(_ command: Command, _ state: EditorState) -> (applied: Bool, state: EditorState) {
    var out = state
    let did = command(state, { tr in out = state.apply(tr) }, nil)
    return (did, out)
}
private func cursorState(_ schema: Schema, _ doc: Node, _ anchor: Int, _ head: Int? = nil) -> EditorState {
    EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: TextSelection.create(doc, anchor, head)))
}

/// A tiny builder for the ad-hoc schemas below.
private struct Build {
    let schema: Schema
    func n(_ type: String, _ children: Node...) -> Node {
        try! schema.node(type, [:], content: Fragment.from(children))
    }
    func t(_ type: String, _ s: String) -> Node {
        try! schema.node(type, [:], content: Fragment.from(s.isEmpty ? [] : [schema.text(s)]))
    }
}

// An isolating node next to an ordinary wrapper.
private let isoB = Build(schema: try! Schema(nodes: [
    ("doc", NodeSpec(content: "(paragraph | iso | quote)+")),
    ("paragraph", NodeSpec(content: "text*")),
    ("iso", NodeSpec(content: "paragraph+", isolating: true)),
    ("quote", NodeSpec(content: "paragraph+")),
    ("text", NodeSpec()),
], topNode: "doc"))

// A block leaf before single-textblock wrappers that nothing can lift out of.
private let embedB = Build(schema: try! Schema(nodes: [
    ("doc", NodeSpec(content: "(box | embed)+")),
    ("box", NodeSpec(content: "para")),
    ("para", NodeSpec(content: "text*")),
    ("embed", NodeSpec()),
    ("text", NodeSpec()),
], topNode: "doc"))

// `one` holds exactly one para, `many` holds several; neither can join the other.
private let oneManyB = Build(schema: try! Schema(nodes: [
    ("doc", NodeSpec(content: "(one | many)+")),
    ("one", NodeSpec(content: "para")),
    ("many", NodeSpec(content: "para+")),
    ("para", NodeSpec(content: "text*")),
    ("text", NodeSpec()),
], topNode: "doc"))

// `pair` holds one para or three — never two.
private let pairB = Build(schema: try! Schema(nodes: [
    ("doc", NodeSpec(content: "(pair | para)+")),
    ("pair", NodeSpec(content: "para (para para)?")),
    ("para", NodeSpec(content: "text*")),
    ("text", NodeSpec()),
], topNode: "doc"))

// A wrapper that may be empty.
private let boxB = Build(schema: try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("para", NodeSpec(content: "text*", group: "block")),
    ("rule", NodeSpec(group: "block")),
    ("box", NodeSpec(content: "block*", group: "block")),
    ("text", NodeSpec()),
], topNode: "doc"))

// An inline node with content (a footnote), inside two kinds of textblock.
private let fnB = Build(schema: try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("para", NodeSpec(content: "inline*", group: "block")),
    ("heading", NodeSpec(content: "inline*", group: "block")),
    ("fn", NodeSpec(content: "text*", group: "inline", inline: true)),
    ("text", NodeSpec(group: "inline")),
], topNode: "doc"))

// A document whose top node holds text directly.
private let inlineDocSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "text*")),
    ("text", NodeSpec()),
], marks: [("em", MarkSpec())], topNode: "doc")

// A textblock whose inline content a paragraph can't hold.
private let mathB = Build(schema: try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("para", NodeSpec(content: "text*", group: "block")),
    ("mb", NodeSpec(content: "atomx*", group: "block")),
    ("atomx", NodeSpec(inline: true)),
    ("text", NodeSpec()),
], topNode: "doc"))

func registerMutationKillTests() {
    func h(_ name: String, _ body: @escaping @Sendable () throws -> Void) { test("mutation history: \(name)") { try body() } }
    func c(_ name: String, _ body: @escaping @Sendable () throws -> Void) { test("mutation cmd: \(name)") { try body() } }

    // MARK: History

    h("an edit exactly newGroupDelay after the last one still joins its group") {
        // Upstream starts a new group only when prevTime < time - newGroupDelay.
        var s = histState(nil, HistoryOptions(newGroupDelay: 1000))
        s = typed(s, "a", at: 1000)
        s = typed(s, "b", at: 2000)
        try expectEqual(undoDepth(s), 1)
        s = typed(s, "c", at: 3001)
        try expectEqual(undoDepth(s), 2)
    }

    h("an undo closes the group, so the next adjacent edit starts a new event") {
        // The tail of upstream's "starts a new event when newGroupDelay elapses".
        var s = histState(nil, HistoryOptions(newGroupDelay: 1000))
        s = typed(s, "a", at: 1000)
        s = typed(s, "b", at: 1600)
        s = typed(s, "c", at: 2700)
        try expectEqual(undoDepth(s), 2)
        s = run(s, undo)
        try expectEqual(s.doc, doc(p("ab")).node)
        s = typed(s, "d", at: 2800)
        try expectEqual(undoDepth(s), 2)
        s = run(s, undo)
        try expectEqual(s.doc, doc(p("ab")).node)
    }

    h("a new change clears the redo branch") {
        var s = histState()
        s = typed(s, "a")
        s = s.apply(closeHistory(s.tr))
        s = typed(s, "b")
        s = run(s, undo)
        try expectEqual(redoDepth(s), 1)
        s = typed(s, "c")
        try expectEqual(redoDepth(s), 0)
        try expect(!redo(s, nil), "redo must be unavailable after a new change")
        try expectEqual(s.doc, doc(p("ac")).node)
    }

    h("a transaction appended to one that opted out of history is not undoable either") {
        let appender = Plugin(appendTransaction: { trs, _, state in
            guard let add = trs[0].getMeta("add") as? String else { return nil }
            return try! state.tr.insert(1, basicSchema.text(add))
        })
        var s = histState(doc(p("x")), plugins: [appender])
        s = s.apply(try! s.tr.insert(2, basicSchema.text("I")).setMeta("add", "A").setMeta("addToHistory", false))
        try expectEqual(s.doc, doc(p("AxI")).node)
        try expectEqual(undoDepth(s), 0)
        try expect(!undo(s, nil))
    }

    h("remote changes leave nothing on an empty history") {
        // Upstream's addMaps returns the branch untouched when it has no events.
        var s = histState(doc(p("x")))
        for _ in 0..<3 {
            s = s.apply(try! s.tr.insertText("r", 1).setMeta("addToHistory", false))
        }
        try expectEqual(_undoItemCount(s), 0)
        s = typed(s, "a")
        try expectEqual(_undoItemCount(s), 1)
    }

    h("rebasing two unconfirmed events keeps older events at the right place") {
        // Collab rebase: two local unconfirmed events (A, then B, both typed in
        // front of the older "base" event) are undone, a remote insert lands at
        // the end, and both are reapplied. The branch must record only the
        // remote map as map-only air — not the reapplied local maps too, which
        // nothing ever unmaps — or "base" undoes two positions to the right.
        var s = histState()
        s = typed(s, "base")
        s = s.apply(closeHistory(s.tr))
        let l1 = ReplaceStep(1, 1, text("A"))
        let t1 = s.tr; _ = t1.maybeStep(l1); s = s.apply(t1)
        s = s.apply(closeHistory(s.tr))
        let l2 = ReplaceStep(2, 2, text("B"))
        let t2 = s.tr; _ = t2.maybeStep(l2); s = s.apply(t2)
        try expectEqual(s.doc, doc(p("ABbase")).node)
        try expectEqual(undoDepth(s), 3)

        // The rebase transaction the collab module builds: local steps undone
        // newest first, the remote step, then the local steps remapped, each
        // mirrored to its inverse.
        let docs = [t1.docs[0], t2.docs[0]]
        let locals: [ReplaceStep] = [l1, l2]
        let tr = s.tr
        for i in stride(from: 1, through: 0, by: -1) { _ = tr.maybeStep(locals[i].invert(docs[i])) }
        _ = tr.maybeStep(ReplaceStep(5, 5, text("R ")))
        for i in 0..<2 {
            let mapped = locals[i].map(tr.mapping.slice(2 - i))!
            _ = tr.maybeStep(mapped)
            tr.mapping.setMirror(2 - i - 1, tr.steps.count - 1)
        }
        tr.setMeta("addToHistory", false)
        tr.setMeta("rebased", 2)
        s = s.apply(tr)
        try expectEqual(s.doc, doc(p("ABbaseR ")).node)
        try expectEqual(undoDepth(s), 3)

        s = run(s, undo); try expectEqual(s.doc, doc(p("AbaseR ")).node)
        s = run(s, undo); try expectEqual(s.doc, doc(p("baseR ")).node)
        s = run(s, undo); try expectEqual(s.doc, doc(p("R ")).node)
        s = run(s, redo); try expectEqual(s.doc, doc(p("baseR ")).node)
    }

    h("one transaction with several steps is one event") {
        let s0 = histState(doc(p("x")))
        let tr = s0.tr
        _ = try tr.insert(1, basicSchema.text("a"))
        _ = try tr.insert(3, basicSchema.text("b"))
        _ = try tr.insert(1, basicSchema.text("c"))
        var s = s0.apply(tr)
        try expectEqual(s.doc, doc(p("caxb")).node)
        try expectEqual(undoDepth(s), 1)
        s = run(s, undo)
        try expectEqual(s.doc, doc(p("x")).node)
        try expectEqual(undoDepth(s), 0)
        try expectEqual(redoDepth(s), 1)
    }

    // MARK: joinBackward / deleteBarrier

    c("joinBackward doesn't reach past an isolating ancestor") {
        // The cut search stops at the isolating node, and an isolating node
        // can't be lifted out of, so there is nothing to do.
        let d = isoB.n("doc", isoB.t("paragraph", "a"), isoB.n("iso", isoB.t("paragraph", ""), isoB.t("paragraph", "x")))
        let r = exec(joinBackward, cursorState(isoB.schema, d, 5))
        try expect(!r.applied, "joinBackward must not delete across an isolating boundary")
        try expectEqual(r.state.doc, d)
    }

    c("joinBackward lifts a block out from after an isolating node") {
        let d = isoB.n("doc", isoB.n("iso", isoB.t("paragraph", "a")), isoB.n("quote", isoB.t("paragraph", "b")))
        let r = exec(joinBackward, cursorState(isoB.schema, d, 7))
        try expect(r.applied)
        try expectEqual(r.state.doc, isoB.n("doc", isoB.n("iso", isoB.t("paragraph", "a")), isoB.t("paragraph", "b")))
    }

    c("joinBackward doesn't delete a leaf that isn't directly before the cursor's block") {
        let d = embedB.n("doc", embedB.n("embed"), embedB.n("box", embedB.t("para", "x")))
        let r = exec(joinBackward, cursorState(embedB.schema, d, 3))
        try expect(!r.applied)
        try expectEqual(r.state.doc, d)
    }

    c("joinBackward deletes an empty textblock and puts the cursor at the end of the one before") {
        // `many` holds two paragraphs, so it can't be merged into `one` whole;
        // the empty paragraph is deleted instead and the cursor goes back.
        let d = oneManyB.n("doc", oneManyB.n("one", oneManyB.t("para", "a")),
                           oneManyB.n("many", oneManyB.t("para", ""), oneManyB.t("para", "x")))
        let r = exec(joinBackward, cursorState(oneManyB.schema, d, 7))
        try expect(r.applied)
        try expectEqual(r.state.doc, oneManyB.n("doc", oneManyB.n("one", oneManyB.t("para", "a")),
                                                oneManyB.n("many", oneManyB.t("para", "x"))))
        try expectEqual(r.state.selection.head, 3)
        try expect(r.state.selection.empty)
    }

    c("joinBackward merges textblocks rather than wrapping into an unfinished parent") {
        // Moving the paragraph into `pair` would leave it with two paragraphs,
        // which `pair` doesn't allow, so the textblocks are merged instead.
        let d = pairB.n("doc", pairB.n("pair", pairB.t("para", "a")), pairB.t("para", "b"))
        let r = exec(joinBackward, cursorState(pairB.schema, d, 6))
        try expect(r.applied)
        try expectEqual(r.state.doc, pairB.n("doc", pairB.n("pair", pairB.t("para", "ab"))))
    }

    // MARK: splitBlock

    c("splitBlock does nothing for a node selected at the start of its parent") {
        let d = boxB.n("doc", boxB.n("box", boxB.n("rule"), boxB.t("para", "x")))
        let state = EditorState.create(EditorStateConfig(schema: boxB.schema, doc: d, selection: NodeSelection.create(d, 1)))
        try expect(state.selection is NodeSelection)
        let r = exec(splitBlock, state)
        try expect(!r.applied)
        try expectEqual(r.state.doc, d)
    }

    c("splitBlock at the end of an inline node at the end of a heading makes a paragraph") {
        let d = fnB.n("doc", fnB.n("heading", fnB.t("fn", "x")))
        let r = exec(splitBlock, cursorState(fnB.schema, d, 3))
        try expect(r.applied)
        try expectEqual(r.state.doc, fnB.n("doc", fnB.n("heading", fnB.t("fn", "x")), fnB.n("para", fnB.t("fn", ""))))
    }

    c("splitBlock in an empty heading keeps the heading and adds a paragraph") {
        let d = doc(h1(""), p("x")).node
        let r = exec(splitBlock, cursorState(basicSchema, d, 1))
        try expect(r.applied)
        try expectEqual(r.state.doc, doc(h1(""), p(""), p("x")).node)
        try expectEqual(r.state.selection.head, 3)
    }

    c("splitBlockKeepMarks doesn't carry marks when the selection ends at a block start") {
        // Upstream only keeps marks when `$to.parentOffset` is non-zero.
        let d = doc(p(strong("ab")), p("cd")).node
        let r = exec(splitBlockKeepMarks, cursorState(basicSchema, d, 3, 5))
        try expect(r.applied)
        try expectEqual(r.state.doc, doc(p(strong("ab")), p("cd")).node)
        try expectNil(r.state.storedMarks)
    }

    // MARK: marks / block types

    c("toggleMark applies in a document whose top node holds text") {
        let d = try! inlineDocSchema.node("doc", [:], content: Fragment.from([inlineDocSchema.text("abc")]))
        let em = inlineDocSchema.marks["em"]!
        let r = exec(toggleMark(em), cursorState(inlineDocSchema, d, 0, 2))
        try expect(r.applied)
        try expect(r.state.doc.rangeHasMark(0, 2, em))
        try expect(!r.state.doc.rangeHasMark(2, 3, em))
    }

    c("setBlockType doesn't apply when the block already has that type") {
        let d = doc(p("x"), h2("y")).node
        let para = basicSchema.nodes["paragraph"]!
        try expect(!exec(setBlockType(para), cursorState(basicSchema, d, 1)).applied)
        let heading = basicSchema.nodes["heading"]!
        try expect(!exec(setBlockType(heading, ["level": .int(2)]), cursorState(basicSchema, d, 5)).applied)
        let r = exec(setBlockType(heading, ["level": .int(3)]), cursorState(basicSchema, d, 5))
        try expect(r.applied)
        try expectEqual(r.state.doc, doc(p("x"), h3("y")).node)
    }

    // MARK: joinTextblockBackward

    c("joinTextblockBackward refuses textblocks whose content can't merge") {
        let d = mathB.n("doc", mathB.t("para", "hi"), mathB.n("mb", mathB.n("atomx")))
        let r = exec(joinTextblockBackward, cursorState(mathB.schema, d, 5))
        try expect(!r.applied)
        try expectEqual(r.state.doc, d)
    }

    // MARK: createParagraphNear

    c("createParagraphNear refuses a selection with one end in inline content") {
        let d = doc(p("ab"), hr()).node
        let r = exec(createParagraphNear, cursorState(basicSchema, d, 1, 4))
        try expect(!r.applied)
        try expectEqual(r.state.doc, d)
    }
}
