import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorHistory
import EditorInputRules
import TestHarness

// The command paths the ported suites don't reach.
//
// The join and select-node commands take a `CommandHost` so a view can say
// whether the caret is *visually* at the start or end of its block — a wrapped
// line ends before the block does. Every ported test runs without a host, so
// the branch that trusts the host's answer over the parent offset was never
// exercised. The rest are single behaviours (exiting a code block, retyping a
// heading's level, history compression merging keystrokes, an input rule undone
// after an empty input) with no upstream test.

/// A host with a fixed answer about the caret's visual position.
private final class FixedHost: CommandHost {
    let answer: Bool?
    init(_ answer: Bool?) { self.answer = answer }
    func endOfTextblock(_ dir: String, _ state: EditorState) -> Bool? { answer }
}

private func selFor(_ d: TaggedNode) -> Selection {
    if let a = d.tags["a"] {
        let r = d.node.resolve(a)
        if r.parent.inlineContent { return TextSelection.create(d.node, a, d.tags["b"]) }
        return NodeSelection.create(d.node, a)
    }
    return Selection.atStart(d.node)
}

private func mkState(_ d: TaggedNode, plugins: [Plugin] = []) -> EditorState {
    EditorState.create(EditorStateConfig(schema: basicSchema, doc: d.node, selection: selFor(d), plugins: plugins))
}

/// Run a command with a host; the document (and, when tagged, the selection)
/// must come out as `result`. A nil result means the command must not apply.
private func run(_ d: TaggedNode, _ command: Command, host: (any CommandHost)?, _ result: TaggedNode?) throws {
    var state = mkState(d)
    let applied = command(state, { tr in state = state.apply(tr) }, host)
    try expectEqual(applied, result != nil, "applied")
    try expectEqual(state.doc, (result ?? d).node)
    if let result, result.tags["a"] != nil {
        try expect(state.selection.eq(selFor(result)), "selection mismatch: \(state.selection.from)..\(state.selection.to)")
    }
}

private func bq(_ name: String) -> NodeType { basicSchema.nodes[name]! }

func registerHostAndEdgeCommandTests() {
    // MARK: The host's word on where the caret is

    test("joinBackward: a host that says the caret isn't at the block start wins over the offset") {
        try run(doc(p("hi"), p("<a>there")), joinBackward, host: FixedHost(false), nil)
    }
    test("joinBackward: a host that says the caret is at the block start wins over the offset") {
        try run(doc(p("hi"), p("th<a>ere")), joinBackward, host: FixedHost(true), doc(p("hithere")))
    }
    test("joinBackward: a host with no opinion leaves it to the offset") {
        try run(doc(p("hi"), p("th<a>ere")), joinBackward, host: FixedHost(nil), nil)
        try run(doc(p("hi"), p("<a>there")), joinBackward, host: FixedHost(nil), doc(p("hithere")))
    }
    test("joinForward: the host's answer decides whether the caret is at the block end") {
        try run(doc(p("hi<a>"), p("there")), joinForward, host: FixedHost(false), nil)
        try run(doc(p("h<a>i"), p("there")), joinForward, host: FixedHost(true), doc(p("hithere")))
    }
    test("selectNodeBackward: the host's answer decides whether the caret is at the block start") {
        try run(doc(hr(), p("<a>hi")), selectNodeBackward, host: FixedHost(false), nil)
        try run(doc(hr(), p("h<a>i")), selectNodeBackward, host: FixedHost(true), doc("<a>", hr(), p("hi")))
    }
    test("selectNodeForward: the host's answer decides whether the caret is at the block end") {
        try run(doc(p("hi<a>"), hr()), selectNodeForward, host: FixedHost(false), nil)
        try run(doc(p("h<a>i"), hr()), selectNodeForward, host: FixedHost(true), doc(p("hi"), "<a>", hr()))
    }

    // MARK: Joins the ported cases skip

    test("joinForward: an empty textblock before a selectable leaf is removed") {
        try run(doc(p("<a>"), hr()), joinForward, host: nil, doc(hr()))
    }
    test("joinForward: from an empty textblock, the wrapped block after it is lifted out first") {
        try run(doc(p("<a>"), blockquote(p("x"))), joinForward, host: nil, doc(p("<a>"), p("x")))
    }
    test("joinForward: text followed by a wrapped textblock pulls it in") {
        try run(doc(p("a<a>"), blockquote(p("b"))), joinForward, host: nil, doc(p("a"), p("b")))
    }
    test("joinBackward: an empty textblock after a wrapper moves into it") {
        try run(doc(blockquote(p("x")), p("<a>")), joinBackward, host: nil, doc(blockquote(p("x"), p("<a>"))))
    }

    // MARK: exitCode

    test("exitCode: at the end of a code block, creates a paragraph after it and moves there") {
        try run(doc(pre("code<a>")), exitCode, host: nil, doc(pre("code"), p("<a>")))
    }
    test("exitCode: does nothing mid-code or outside code") {
        try run(doc(pre("co<a>de")), exitCode, host: nil, nil)
        try run(doc(p("text<a>")), exitCode, host: nil, nil)
    }

    // MARK: setBlockType

    test("setBlockType: the same type with different attributes still applies") {
        try run(doc(h1("<a>a")), setBlockType(bq("heading"), ["level": .int(2)]), host: nil, doc(h2("a")))
    }

    // MARK: History compression

    test("history compress: adjacent keystrokes merge into one item and still undo as one event") {
        var s = EditorState.create(EditorStateConfig(schema: basicSchema, doc: doc(p()).node, plugins: [history()]))
        for ch in "hello" { s = s.apply(try s.tr.insertText(String(ch))) }
        try expectEqual(s.doc, doc(p("hello")).node)
        try expectEqual(undoDepth(s), 1, "one event")
        _compressHistory(s)
        try expectEqual(undoDepth(s), 1)
        _ = undo(s) { s = s.apply($0) }
        try expectEqual(s.doc, doc(p()).node)
        _ = redo(s) { s = s.apply($0) }
        try expectEqual(s.doc, doc(p("hello")).node)
    }

    // MARK: undoInputRule

    test("undoInputRule: a rule fired by an empty input is undone by removing what it made") {
        let dash = InputRule("--$") { state, _, start, end in
            let tr = state.tr
            _ = try? tr.replaceWith(start, end, state.schema.text("\u{2014}"))
            return tr
        }
        let plugin = inputRules([dash])
        var s = mkState(doc(p("--<a>")), plugins: [plugin])
        let fired = plugin.props!.handleTextInput!(3, 3, "", s) { s = s.apply($0) }
        try expect(fired, "the rule should fire on the text already there")
        try expectEqual(s.doc, doc(p("\u{2014}")).node)
        try expect(undoInputRule(s) { s = s.apply($0) })
        try expectEqual(s.doc, doc(p("--")).node)
    }
}
