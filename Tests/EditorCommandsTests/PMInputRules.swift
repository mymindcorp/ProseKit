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
}
