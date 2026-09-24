import Foundation
import DocumentModel
import EditorStateKit
import EditorInputRules
import TestHarness

// Input-rule behaviour the existing cases pass over without pinning: the exact
// width of the look-behind window, matches that end before the cursor, a code
// mark that only the cursor sits in, the builders' join/refusal decisions, and
// the marks the typed text gets back when an input rule is undone.

/// Feed `text` through the plugin as if typed at `anchor`. Returns whether a
/// rule handled it and the resulting state (nil when nothing was dispatched).
private func typeThrough(_ rules: [InputRule], _ doc: Node, anchor: Int,
                         _ text: String) -> (handled: Bool, state: EditorState?) {
    let plugin = inputRules(rules)
    let state = B.state(doc, anchor: anchor, plugins: [plugin])
    var out: EditorState?
    let handled = plugin.props?.handleTextInput?(anchor, anchor, text, state) { out = state.apply($0) } ?? false
    return (handled, out)
}

private let replaceWithOK = InputRule("^x[y]*z$") { state, _, start, end in
    try? state.tr.insertText("ok", start, end)
}

private func ol(_ content: Node...) -> Node { B.node("orderedList", [:], content) }

func registerInputRulesMutationKillTests() {
    test("input rules kills: the look-behind window holds exactly 500 characters of the textblock") {
        // 500 characters before the cursor: the window reaches the "x".
        let full = typeThrough([replaceWithOK], B.doc(B.p("x" + String(repeating: "y", count: 499))), anchor: 501, "z")
        try expect(full.handled)
        try expectEqual(full.state?.doc, B.doc(B.p("ok")))
        // One more character and the "x" falls out of the window.
        let over = typeThrough([replaceWithOK], B.doc(B.p("x" + String(repeating: "y", count: 500))), anchor: 502, "z")
        try expect(!over.handled)
        try expectNil(over.state)
    }

    test("input rules kills: a match that ends before the cursor does not fire") {
        let unanchored = InputRule("ab") { state, _, start, end in
            try? state.tr.insertText("!", start, end)
        }
        // "ab" matches earlier in "abx" but not at the cursor.
        let miss = typeThrough([unanchored], B.doc(B.p("ab")), anchor: 3, "x")
        try expect(!miss.handled)
        try expectNil(miss.state)
        // Control: the same rule fires when the typed text completes the match.
        let hit = typeThrough([unanchored], B.doc(B.p("a")), anchor: 2, "b")
        try expect(hit.handled)
        try expectEqual(hit.state?.doc, B.doc(B.p("!")))
    }

    test("input rules kills: inCodeMark false skips a rule typed at the end of code-marked text") {
        let rule = InputRule("x$", inCodeMark: false) { state, _, start, end in
            try? state.tr.insertText("!", start, end)
        }
        // The match is only the typed "x"; the code mark is on the text before
        // the cursor, which the typed character would inherit.
        let inCode = typeThrough([rule], B.doc(B.p(B.code("code"))), anchor: 5, "x")
        try expect(!inCode.handled)
        try expectNil(inCode.state)
        let plain = typeThrough([rule], B.doc(B.p("plain")), anchor: 6, "x")
        try expect(plain.handled)
    }

    test("input rules kills: wrappingInputRule joins into a preceding list of the same type by default") {
        let rule = wrappingInputRule("^\\s*([-+*])\\s$", B.type("bulletList"))
        let out = typeThrough([rule], B.doc(B.ul(B.li(B.p("a"))), B.p("-")), anchor: 9, " ")
        try expect(out.handled)
        try expectEqual(out.state?.doc, B.doc(B.ul(B.li(B.p("a")), B.li(B.p("")))))
    }

    test("input rules kills: wrappingInputRule does not join into a preceding list of another type") {
        let rule = wrappingInputRule("^\\s*([-+*])\\s$", B.type("bulletList"))
        let out = typeThrough([rule], B.doc(ol(B.li(B.p("a"))), B.p("-")), anchor: 9, " ")
        try expect(out.handled)
        try expectEqual(out.state?.doc, B.doc(ol(B.li(B.p("a"))), B.ul(B.li(B.p("")))))
    }

    test("input rules kills: textblockTypeInputRule declines where the parent cannot hold the new type") {
        // A list item must start with a paragraph, so "# " there stays text.
        let rule = textblockTypeInputRule("^# $", B.type("heading"))
        let out = typeThrough([rule], B.doc(B.ul(B.li(B.p("#")))), anchor: 4, " ")
        try expect(!out.handled)
        try expectNil(out.state)
        // Control: at the top level the same rule converts the paragraph.
        let top = typeThrough([rule], B.doc(B.p("#")), anchor: 2, " ")
        try expect(top.handled)
        try expectEqual(top.state?.doc, B.doc(B.h(1)))
    }

    test("input rules kills: undoInputRule restores the typed text with the marks at the typed position") {
        let out = typeThrough([emDashRule], B.doc(B.p(B.strong("a-"))), anchor: 3, "-")
        try expect(out.handled)
        let applied = out.state!
        try expectEqual(applied.doc, B.doc(B.p(B.strong("a\u{2014}"))))
        var undone: EditorState?
        try expect(undoInputRule(applied) { undone = applied.apply($0) })
        // Upstream: the typed "-" is re-inserted with `$from.marks()`, so it
        // stays bold like the text around it.
        try expectEqual(undone?.doc, B.doc(B.p(B.strong("a--"))))
    }
}
