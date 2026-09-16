import Foundation
import DocumentModel
import EditorStateKit
import EditorInputRules
import TestHarness

// Direct unit tests for the input-rules engine and its built-in rules. The
// builder rules (textblockTypeInputRule / wrappingInputRule) are exercised in
// main.swift; these cover the pieces that lacked coverage: smart typography
// (em dash / ellipsis), markInputRule, the code-block gate, and the typed-text
// restore path of undoInputRule.

/// A mutable flag usable inside a @Sendable input-rule handler.
private final class Flag: @unchecked Sendable { var value = false }

/// Feed `text` through the input-rules plugin as if typed at `anchor`, returning
/// the resulting state (nil when no rule fired).
private func fireRule(_ rules: [InputRule], _ doc: Node, anchor: Int, typing text: String) -> EditorState? {
    let plugin = inputRules(rules)
    let state = B.state(doc, anchor: anchor, plugins: [plugin])
    var out: EditorState?
    if let handler = plugin.props?.handleTextInput {
        _ = handler(anchor, anchor, text, state) { out = state.apply($0) }
    }
    return out
}

func registerPMInputRulesTests() {
    test("PM input rule: mark rules preserve Unicode whitespace before the shortcut") {
        let rule = markInputRule("(?:^|\\s)(\\*\\*([^*]+)\\*\\*)$", B.bold)
        for space in ["\u{00a0}", "\u{2003}", "\r"] {
            let out = fireRule([rule], B.doc(B.p(space + "**b*")), anchor: 6, typing: "*")
            try expectNotNil(out)
            try expectEqual(out!.doc, B.doc(B.p(B.t(space), B.strong("b"))))
        }
    }

    test("PM input rule: textblock shortcuts decline to change a textblock root") {
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "text*")),
            ("heading", NodeSpec(content: "text*")),
            ("text", NodeSpec())
        ])
        let plugin = inputRules([textblockTypeInputRule("^# $", schema.nodes["heading"]!)])
        let doc = try schema.node("doc", content: Fragment.from(schema.text("#")))
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: TextSelection.create(doc, 1), plugins: [plugin]))
        try expectEqual(plugin.props?.handleTextInput?(1, 1, " ", state, nil), false)
    }

    test("PM input rule: mark capture uses its regex position when text repeats in the prefix") {
        let rule = markInputRule("(?:^|\\s)(\\*\\*([^*]+)\\*\\*)$", B.bold)
        let out = fireRule([rule], B.doc(B.p(" ** *")), anchor: 6, typing: "*")
        try expectNotNil(out)
        try expectEqual(out!.doc, B.doc(B.p(B.t(" "), B.strong(" "))))
        var undone: EditorState?
        try expect(undoInputRule(out!) { undone = out!.apply($0) })
        try expectEqual(undone?.doc.textContent, " ** **")
    }

    test("PM input rule: mark rules handle input combining with the preceding character") {
        let rule = markInputRule("\\*\\*([^*]+)\\*\\*$", B.bold)
        let out = fireRule([rule], B.doc(B.p("**e")), anchor: 4, typing: "\u{0301}**")
        try expectNotNil(out)
        try expectEqual(out!.doc, B.doc(B.p(B.strong("e\u{0301}"))))
        var undone: EditorState?
        try expect(undoInputRule(out!) { undone = out!.apply($0) })
        try expectEqual(undone?.doc.textContent, "**e\u{0301}**")
    }

    test("PM input rule: regex matches cannot split a grapheme cluster") {
        let rule = InputRule("\u{0301}x$") { state, _, start, end in
            try? state.tr.insertText("!", start, end)
        }
        let out = fireRule([rule], B.doc(B.p("e\u{0301}")), anchor: 2, typing: "x")
        try expect(out == nil)
    }

    test("PM input rule: mark rules leave literal text in blocks that disallow the mark") {
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "paragraph+")),
            ("paragraph", NodeSpec(content: "text*", marks: "")),
            ("text", NodeSpec())
        ], marks: [("bold", MarkSpec())])
        let plugin = inputRules([markInputRule("\\*\\*([^*]+)\\*\\*$", schema.marks["bold"]!)])
        let paragraph = try schema.node("paragraph", content: Fragment.from(schema.text("**bold*")))
        let doc = try schema.node("doc", content: Fragment.from(paragraph))
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: TextSelection.create(doc, 8), plugins: [plugin]))
        let handled = plugin.props?.handleTextInput?(8, 8, "*", state, nil)
        try expectEqual(handled, false)
    }

    test("PM input rule: mark rules replace selected text and retain inner marks") {
        let plugin = inputRules([markInputRule("\\*\\*([^*]+)\\*\\*$", B.bold)])
        let italic = B.schema.marks["italic"]!
        let state = B.state(B.doc(B.p(B.t("**"), B.schema.text("bo", [italic.create()]), B.t("XYZ"))), anchor: 5, head: 8, plugins: [plugin])
        var out: EditorState?
        _ = plugin.props?.handleTextInput?(5, 8, "ld**", state) { out = state.apply($0) }
        try expectNotNil(out)
        try expectEqual(out!.doc.textContent, "bold")
        try expectEqual(out!.doc.firstChild?.firstChild?.text, "bo")
        try expect(B.bold.isInSet(out!.doc.firstChild!.firstChild!.marks) != nil)
        try expect(italic.isInSet(out!.doc.firstChild!.firstChild!.marks) != nil)
        var undone: EditorState?
        try expect(undoInputRule(out!) { undone = out!.apply($0) })
        try expectEqual(undone?.doc.textContent, "**bold**")
    }

    test("PM input rule: mark rules preserve multi-character input and undo") {
        let rule = markInputRule("\\*\\*([^*]+)\\*\\*$", B.bold)
        for (before, anchor, typed) in [("", 1, "**bold**"), ("**bo", 5, "ld**")] {
            let out = fireRule([rule], B.doc(B.p(before)), anchor: anchor, typing: typed)
            try expectNotNil(out)
            try expectEqual(out!.doc, B.doc(B.p(B.strong("bold"))))
            var undone: EditorState?
            try expect(undoInputRule(out!) { undone = out!.apply($0) })
            try expectEqual(undone?.doc, B.doc(B.p("**bold**")))
        }
    }

    test("PM input rule: reusing a plugin isolates undo between editor states") {
        let plugin = inputRules([emDashRule])
        let original = B.state(B.doc(B.p("a-")), anchor: 3, plugins: [plugin])
        let sibling = B.state(B.doc(B.p("other")), anchor: 2, plugins: [plugin])
        var changed: EditorState?
        _ = plugin.props?.handleTextInput?(3, 3, "-", original) { changed = original.apply($0) }
        try expectNotNil(changed)
        try expect(undoInputRule(changed!, nil))
        try expect(!undoInputRule(original, nil))
        try expect(!undoInputRule(sibling, nil))
        let fresh = B.state(B.doc(B.p("fresh")), anchor: 1, plugins: [plugin])
        try expect(!undoInputRule(fresh, nil))
    }

    test("PM input rule: '--' becomes an em dash") {
        let out = fireRule([emDashRule], B.doc(B.p("a-")), anchor: 3, typing: "-")
        try expectNotNil(out)
        try expectEqual(out!.doc, B.doc(B.p("a\u{2014}")))
    }

    test("PM input rule: '...' becomes an ellipsis") {
        let out = fireRule([ellipsisRule], B.doc(B.p("..")), anchor: 3, typing: ".")
        try expectNotNil(out)
        try expectEqual(out!.doc, B.doc(B.p("\u{2026}")))
    }

    test("PM input rule: '**text**' applies the bold mark and strips the markers") {
        let rule = markInputRule("\\*\\*([^*]+)\\*\\*$", B.bold)
        let out = fireRule([rule], B.doc(B.p("**bold*")), anchor: 8, typing: "*")
        try expectNotNil(out)
        try expectEqual(out!.doc, B.doc(B.p(B.strong("bold"))))
    }

    test("PM input rule: does not fire inside a code block") {
        let out = fireRule([emDashRule], B.doc(B.codeBlock("a-")), anchor: 3, typing: "-")
        try expect(out == nil)
    }

    test("PM input rule: undoInputRule restores the typed characters") {
        let plugin = inputRules([emDashRule])
        let state = B.state(B.doc(B.p("a-")), anchor: 3, plugins: [plugin])
        var afterRule: EditorState?
        if let handler = plugin.props?.handleTextInput {
            _ = handler(3, 3, "-", state) { afterRule = state.apply($0) }
        }
        try expectNotNil(afterRule)
        try expectEqual(afterRule!.doc, B.doc(B.p("a\u{2014}")))

        var undone: EditorState?
        _ = undoInputRule(afterRule!) { undone = afterRule!.apply($0) }
        try expectNotNil(undone)
        try expectEqual(undone!.doc, B.doc(B.p("a--")))
    }

    test("PM input rule: first matching rule wins, others are skipped") {
        // A catch-all that would fire on any "-" must not run once emDash matches.
        let ranFallback = Flag()
        let fallback = InputRule("-$") { state, _, _, _ in
            ranFallback.value = true
            return state.tr
        }
        let out = fireRule([emDashRule, fallback], B.doc(B.p("a-")), anchor: 3, typing: "-")
        try expectNotNil(out)
        try expectEqual(out!.doc, B.doc(B.p("a\u{2014}")))
        try expect(!ranFallback.value)
    }

    // Upstream 1.5.0: when the inserted text is longer than the regex match,
    // the rule must be skipped (the old math produced an inverted range).
    test("PM input rule: skips a rule whose match is shorter than the inserted text") {
        let out = fireRule([emDashRule], B.doc(B.p("a")), anchor: 2, typing: "x--")
        try expect(out == nil)
    }

    test("PM input rule: multi-character input can complete a match") {
        let out = fireRule([emDashRule], B.doc(B.p("a")), anchor: 2, typing: "--")
        try expectNotNil(out)
        try expectEqual(out!.doc, B.doc(B.p("a\u{2014}")))
    }

    // Upstream 1.5.0: rules with inCodeMark: false don't fire at a cursor
    // carrying a code mark. emDash/ellipsis/smart quotes all opt out.
    test("PM input rule: inCodeMark=false rule does not fire inside a code mark") {
        let out = fireRule([emDashRule], B.doc(B.p(B.code("a-"))), anchor: 3, typing: "-")
        try expect(out == nil)
    }

    test("PM input rule: rules fire inside code marks by default") {
        let rule = InputRule("--$") { state, _, start, end in
            let t = state.tr
            _ = try? t.insertText("\u{2014}", start, end)
            return t
        }
        let out = fireRule([rule], B.doc(B.p(B.code("a-"))), anchor: 3, typing: "-")
        try expectNotNil(out)
    }

    // Upstream 1.5.1: the code-mark check covers the whole matched range, not
    // just the cursor — here the cursor sits after plain text but the match
    // reaches back into code-marked text.
    test("PM input rule: inCodeMark=false rule does not fire when the match spans a code mark") {
        let rule = InputRule("-xy$", inCodeMark: false) { state, _, start, end in
            let t = state.tr
            _ = try? t.insertText("!", start, end)
            return t
        }
        let out = fireRule([rule], B.doc(B.p(B.code("-"), B.t("x"))), anchor: 3, typing: "y")
        try expect(out == nil)
    }

    // Upstream 1.4.0 semantics: inCode: true lets a rule apply inside a code
    // block (the default remains skipping them).
    test("PM input rule: inCode rule fires inside a code block") {
        let rule = InputRule("--$", inCode: true) { state, _, start, end in
            let t = state.tr
            _ = try? t.insertText("\u{2014}", start, end)
            return t
        }
        let out = fireRule([rule], B.doc(B.codeBlock("a-")), anchor: 3, typing: "-")
        try expectNotNil(out)
    }

    // Upstream parity: moving the selection (without changing the doc) makes
    // the last input rule no longer undoable.
    test("PM input rule: a selection change clears the undoable rule") {
        let plugin = inputRules([emDashRule])
        let state = B.state(B.doc(B.p("a-")), anchor: 3, plugins: [plugin])
        var afterRule: EditorState?
        if let handler = plugin.props?.handleTextInput {
            _ = handler(3, 3, "-", state) { afterRule = state.apply($0) }
        }
        try expectNotNil(afterRule)

        let moved = afterRule!.apply(afterRule!.tr.setSelection(TextSelection.create(afterRule!.doc, 1)))
        let undid = undoInputRule(moved) { _ in }
        try expect(!undid)
        // Advancing one state must not mutate its earlier snapshot.
        var restored: EditorState?
        try expect(undoInputRule(afterRule!) { restored = afterRule!.apply($0) })
        try expectEqual(restored?.doc, B.doc(B.p("a--")))
    }
}
