import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

/// The `[[` and `/` triggers locate themselves by searching the text before the
/// cursor, then turn a character offset into that string into a document
/// position. That arithmetic only holds while every inline leaf counts as one
/// character — `textBetween` otherwise expands a leaf to its `leafText`, and a
/// wiki-link renders as its whole label.
///
/// A paragraph that already held one link put `from` past the cursor, and
/// resolving it trapped. `MentionExtension` and the input rules always passed
/// the one-character override; these two didn't.
/// A paragraph opening with a wiki-link atom whose label is much longer than
/// the one position it occupies, then `tail`.
private func paragraphAfterALink(_ editor: Editor, _ tail: String) throws {
    let s = editor.schema
    editor.setContent(try s.node("doc", [:], content: Fragment.from([
        try s.node("paragraph", [:], content: Fragment.from([
            try s.node("wikiLink", ["target": .string("Soccer Training Session")], content: Fragment.empty),
            s.text(tail),
        ])),
    ])))
}

/// Type at the end of the document's only paragraph.
private func typeAtEnd(_ editor: Editor, _ text: String) throws {
    let end = editor.doc.content.size - 1
    editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, end, end)))
    let tr = editor.state.tr
    try tr.insertText(text, end)
    editor.dispatch(tr)
}

func registerSuggestionOffsetTests() {
    test("wiki suggestion: an earlier atom doesn't shift the trigger's position") {
        let editor = try Editor(extensions: fullKit())
        try paragraphAfterALink(editor, " see ")
        try typeAtEnd(editor, "[[Ar")
        try expectNotNil(editor.wikiLinkSuggestion)
        let suggestion = editor.wikiLinkSuggestion!
        try expectEqual(suggestion.query, "Ar")
        try expectEqual(suggestion.to, editor.state.selection.from)
        try expect(suggestion.from < suggestion.to, "from landed past the cursor")
        // The range really is the trigger — the whole point of the arithmetic.
        try expectEqual(editor.doc.textBetween(suggestion.from, suggestion.to,
                                               blockSeparator: nil, leafText: "\u{fffc}"), "[[Ar")
    }

    test("wiki suggestion: accepting after an atom replaces the trigger, not the text around it") {
        let editor = try Editor(extensions: fullKit())
        try paragraphAfterALink(editor, " see ")
        try typeAtEnd(editor, "[[Ar")
        try expect(editor.acceptWikiLinkSuggestion(target: "Architecture"))
        var links: [String] = []
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "wikiLink" { links.append(node.attrs["target"]?.stringValue ?? "") }
            return true
        }
        try expectEqual(links, ["Soccer Training Session", "Architecture"])
        try expectEqual(editor.doc.textBetween(0, editor.doc.content.size,
                                               blockSeparator: nil, leafText: "\u{fffc}"),
                        "\u{fffc} see \u{fffc}")
    }

    test("slash menu: an earlier atom doesn't shift the trigger's position") {
        let editor = try Editor(extensions: starterKit() + [SlashMenuExtension(atLineStart: false)]
            + [WikiLinkExtension()])
        try paragraphAfterALink(editor, " see ")
        try typeAtEnd(editor, "/head")
        try expectNotNil(editor.slashMenu)
        let menu = editor.slashMenu!
        try expectEqual(menu.query, "head")
        try expect(menu.from < menu.to, "from landed past the cursor")
        try expectEqual(editor.doc.textBetween(menu.from, menu.to,
                                               blockSeparator: nil, leafText: "\u{fffc}"), "/head")
    }

    test("wiki suggestion: an atom between the brackets and the cursor still resolves") {
        // Not typeable, but reachable by dropping or pasting a link into a query
        // — and it has to stay a position, not a trap.
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("[["),
                try s.node("wikiLink", ["target": .string("A Very Long Page Name")], content: Fragment.empty),
                s.text("x"),
            ])),
        ])))
        try typeAtEnd(editor, "y")
        try expectNotNil(editor.wikiLinkSuggestion)
        let suggestion = editor.wikiLinkSuggestion!
        try expectEqual(suggestion.from, 1)
        try expectEqual(suggestion.to, editor.state.selection.from)
        try expectEqual(editor.doc.textBetween(suggestion.from, suggestion.to,
                                               blockSeparator: nil, leafText: "\u{fffc}"), "[[\u{fffc}xy")
    }
}
