import DocumentModel
import EditorHistory
import EditorCommands
import EditorStateKit
import SchemaKit
import TestHarness

// Leftover coverage: where the link, highlight and color marks can be applied,
// the autolink input rule's limits (embedded atoms, formatting boundaries, code
// blocks), the link and highlight commands, and a GapCursor selection restored
// through undo.

private func fullEditor() throws -> Editor { try Editor(extensions: fullKit()) }

func registerPolishCoverageTests() {
    for markName in ["link", "highlight", "textColor", "backgroundColor"] {
        for context in ["codeBlock", "codeMark", "paragraph"] {
            test("format availability: \(markName) in \(context)") {
                let editor = try fullEditor()
                let schema = editor.schema
                let text = schema.text("keep", context == "codeMark" ? [schema.marks["code"]!.create()] : [])
                let block = try schema.node(context == "codeBlock" ? "codeBlock" : "paragraph", content: .from(text))
                editor.setContent(try schema.node("doc", content: .from(block)))
                select(editor, 1, 5)
                let original = editor.state
                let type = schema.marks[markName]!
                let command: Command
                switch markName {
                case "link": command = setLink(type, href: "https://example.com")
                case "highlight": command = setHighlight(type, color: "green")
                default: command = setColor(type, "red")
                }
                let allowed = context == "paragraph"
                try expectEqual(editor.can(command), allowed)
                var dispatched = false
                try expectEqual(command(editor.state, { editor.dispatch($0); dispatched = true }, nil), allowed)
                try expectEqual(dispatched, allowed)
                if allowed {
                    try expect(editor.isActive(mark: markName))
                    try expectEqual(editor.doc.textContent, "keep")
                } else {
                    try expect(editor.state === original, "Rejected formatting must not publish a no-op")
                }
            }
        }
    }
    for atom in ["hardBreak", "mention", "inlineMath", "wikiLink"] {
        test("autolink safety: embedded \(atom) cannot become part of a URL") {
            let editor = try fullEditor()
            let s = editor.schema
            let attrs: Attrs = atom == "mention" ? ["id": .string("person")]
                : atom == "inlineMath" ? ["latex": .string("x")]
                : atom == "wikiLink" ? ["text": .string("Page")] : [:]
            let embedded = try s.node(atom, attrs)
            editor.setContent(try s.node("doc", content: .from(s.node("paragraph", content: .from([
                s.text("https://example.com/"), embedded, s.text("tail")
            ])))))
            let end = editor.doc.content.size - 1
            select(editor, end, end)
            let original = editor.state, revision = editor.docRevision
            try expect(!textInput(editor, at: end, " "))
            try expect(editor.state === original)
            try expectEqual(editor.docRevision, revision)
            editor.dispatch(try editor.state.tr.insertText(" ", end))
            try expectEqual(editor.doc.firstChild?.child(1), embedded)
            try expectEqual(editor.doc.firstChild?.lastChild?.text, "tail ")
            try editor.doc.check()
        }
    }

    test("autolink safety: a URL across formatting boundaries still links") {
        let editor = try fullEditor()
        try editor.setContent(html: "<p>https://<strong>example</strong>.com</p>")
        let original = editor.doc
        let end = editor.doc.content.size - 1
        try expect(textInput(editor, at: end, " "))
        let paragraph = editor.doc.firstChild!
        for index in 0..<3 {
            try expectEqual(paragraph.child(index).marks.first { $0.type.name == "link" }?.attrs["href"], .string("https://example.com"))
        }
        try expect(paragraph.child(1).marks.contains { $0.type.name == "bold" })
        try expectEqual(paragraph.lastChild?.text, " ")
        try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
        try expectEqual(editor.doc, original)
        try editor.doc.check()
    }
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
        // Two tables, with a valid gap before, between and after them. The
        // search from 0 finds the first of those, before table A.
        editor.setContent(try s.node("doc", [:], content: Fragment.from([table("A"), table("B")])))

        let foundGap = GapCursor.findGapCursorFrom(editor.doc.resolve(0), 1)
        try expectNotNil(foundGap)
        editor.dispatch(editor.state.tr.setSelection(GapCursor(foundGap!)))
        try expect(editor.state.selection is GapCursor)
        let gapPos = editor.state.selection.head

        // A position-targeted edit (independent of the selection) so the
        // GapCursor is what history records as the selection-before.
        editor.dispatch(EditorHistory.closeHistory(editor.state.tr))
        let cellTextPos = 3 // inside the first cell, just before its paragraph
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

    test("setHighlight applies a named color; toggleHighlight uses the default") {
        let editor = try fullEditor()
        try type(editor, "hello world")
        let hl = editor.schema.marks["highlight"]!
        select(editor, 1, 6)
        try expect(editor.run(setHighlight(hl, color: "green")))
        var color: String? = "unset"
        editor.doc.nodesBetween(1, 6, { node, _, _, _ in
            if let m = node.marks.first(where: { $0.type === hl }) { color = m.attrs["color"]?.stringValue }
            return true
        })
        try expectEqual(color, "green")
        // Plain toggleHighlight elsewhere leaves color nil (theme default).
        select(editor, 7, 12)
        try expect(editor.run("toggleHighlight"))
        var defColor: String? = "unset"
        editor.doc.nodesBetween(7, 12, { node, _, _, _ in
            if let m = node.marks.first(where: { $0.type === hl }) { defColor = m.attrs["color"]?.stringValue }
            return true
        })
        try expectNil(defColor)
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
