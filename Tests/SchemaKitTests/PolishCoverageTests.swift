import DocumentModel
import EditorHistory
import EditorStateKit
import SchemaKit
import TestHarness

// Leftover coverage: a GapCursor selection restored through undo, and the
// autolink input rule staying out of code blocks.

private func fullEditor() throws -> Editor { try Editor(extensions: fullKit()) }

func registerPolishCoverageTests() {
    test("gapcursor survives undo (bookmark round-trips through history)") {
        let editor = try fullEditor()
        let s = editor.schema
        func cell(_ t: String) -> Node {
            try! s.node("tableCell", [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(t)])),
            ]))
        }
        func table(_ t: String) -> Node {
            try! s.node("table", [:], content: Fragment.from([
                try! s.node("tableRow", [:], content: Fragment.from([cell(t)])),
            ]))
        }
        // Two tables → a valid gap between them.
        editor.setContent(try s.node("doc", [:], content: Fragment.from([table("A"), table("B")])))

        let foundGap = GapCursor.findGapCursorFrom(editor.doc.resolve(0), 1)
        try expectNotNil(foundGap)
        editor.dispatch(editor.state.tr.setSelection(GapCursor(foundGap!)))
        try expect(editor.state.selection is GapCursor)
        let gapPos = editor.state.selection.head

        // A position-targeted edit (independent of the selection) so the
        // GapCursor is what history records as the selection-before.
        editor.dispatch(EditorHistory.closeHistory(editor.state.tr))
        let cellTextPos = 3 // inside the first cell's paragraph
        let tr = editor.state.tr
        try tr.insertText("x", cellTextPos)
        editor.dispatch(tr)

        // Move the caret into the text so the current selection is NOT a gap
        // cursor — proving the restore comes from the recorded bookmark.
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, cellTextPos)))
        try expect(!(editor.state.selection is GapCursor), "caret is now in text, not a gap")

        // Undo: the GapCursor must come back, at the same gap.
        try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
        try expect(editor.state.selection is GapCursor, "undo restored a GapCursor")
        try expectEqual(editor.state.selection.head, gapPos)
    }

    test("autolink input rule does not fire inside a code block") {
        let editor = try fullEditor()
        let s = editor.schema
        let code = try s.node("codeBlock", [:], content: Fragment.from([s.text("https://example.com")]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([code])))

        // Type the trailing space that would trigger autolink in a paragraph.
        let endOfURL = editor.doc.content.size - 1 // before the closing token
        var handled = false
        for plugin in editor.state.plugins {
            if let h = plugin.props?.handleTextInput,
               h(endOfURL, endOfURL, " ", editor.state, { editor.dispatch($0) }) {
                handled = true; break
            }
        }
        try expect(!handled, "no input rule should claim the space inside a code block")
        // And no link mark exists anywhere in the document.
        let linkType = s.marks["link"]!
        var hasLink = false
        editor.doc.descendants { node, _, _, _ in
            if node.marks.contains(where: { $0.type === linkType }) { hasLink = true }
            return true
        }
        try expect(!hasLink, "code-block text must not be autolinked")
    }

    test("setLink adds a link over the selection; unsetLink removes it") {
        let editor = try fullEditor()
        try type(editor, "hello world")
        let linkType = editor.schema.marks["link"]!
        select(editor, 1, 6) // "hello"
        try expect(editor.run(setLink(linkType, href: "https://example.com")))
        try expect(editor.doc.rangeHasMark(1, 6, linkType))
        // The href is recorded.
        var href: String?
        editor.doc.nodesBetween(1, 6, { node, _, _, _ in
            if let m = node.marks.first(where: { $0.type === linkType }) { href = m.attrs["href"]?.stringValue }
            return true
        })
        try expectEqual(href, "https://example.com")
        // unsetLink clears it.
        try expect(editor.run(unsetLink(linkType)))
        try expect(!editor.doc.rangeHasMark(1, 6, linkType))
    }

    test("setLink replaces an existing link rather than nesting") {
        let editor = try fullEditor()
        try type(editor, "hello")
        let linkType = editor.schema.marks["link"]!
        select(editor, 1, 6)
        _ = editor.run(setLink(linkType, href: "https://old.com"))
        _ = editor.run(setLink(linkType, href: "https://new.com"))
        var hrefs: [String] = []
        editor.doc.nodesBetween(1, 6, { node, _, _, _ in
            for m in node.marks where m.type === linkType { hrefs.append(m.attrs["href"]?.stringValue ?? "") }
            return true
        })
        try expectEqual(Set(hrefs), ["https://new.com"])
    }

    test("setLink/unsetLink are no-ops with an empty selection") {
        let editor = try fullEditor()
        try type(editor, "hello")
        let linkType = editor.schema.marks["link"]!
        select(editor, 3, 3)
        try expect(!editor.run(setLink(linkType, href: "https://x.com")))
        try expect(!editor.run(unsetLink(linkType)))
    }

    test("autolink input rule still fires in a paragraph (control)") {
        let editor = try fullEditor()
        let s = editor.schema
        let para = try s.node("paragraph", [:], content: Fragment.from([s.text("see https://example.com")]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([para])))
        let end = editor.doc.content.size - 1
        var handled = false
        for plugin in editor.state.plugins {
            if let h = plugin.props?.handleTextInput,
               h(end, end, " ", editor.state, { editor.dispatch($0) }) {
                handled = true; break
            }
        }
        try expect(handled, "autolink should claim the space in a paragraph")
        let linkType = s.marks["link"]!
        var hasLink = false
        editor.doc.descendants { node, _, _, _ in
            if node.marks.contains(where: { $0.type === linkType }) { hasLink = true }
            return true
        }
        try expect(hasLink, "the URL should be linked")
    }
}
