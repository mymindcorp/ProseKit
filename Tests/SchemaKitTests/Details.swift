import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorHistory
import SchemaKit
import TestHarness

// Registered into the shared `collector` from main.swift.

/// Type text at the cursor (the shared `type` helper always inserts at 1, which
/// isn't a text position once the doc starts with a `details`).
private func typeHere(_ editor: Editor, _ text: String) throws {
    let tr = editor.state.tr
    try tr.insertText(text)
    editor.dispatch(tr)
}

/// The position + node of the first `details` in the document, if any.
private func firstDetails(_ editor: Editor) -> (pos: Int, node: Node)? {
    var found: (Int, Node)?
    editor.doc.descendants { node, pos, _, _ in
        if found == nil, node.type.name == "details" { found = (pos, node) }
        return found == nil
    }
    return found
}

func registerDetailsTests() {
    test("details: unwrapping never drops a summary that cannot become a paragraph") {
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("body", NodeSpec(content: "text*", group: "block")),
            ("paragraph", NodeSpec(content: "text*", group: "block", attrs: ["required": AttributeSpec()])),
            ("text", NodeSpec()),
            ("details", DetailsExtension().nodeSpec),
            ("detailsSummary", NodeSpec(content: "text*")),
            ("detailsContent", DetailsContentExtension().nodeSpec)
        ])
        let body = try schema.node("body", content: Fragment.from(schema.text("body")))
        let summary = try schema.node("detailsSummary", content: Fragment.from(schema.text("keep summary")))
        let content = try schema.node("detailsContent", content: Fragment.from(body))
        let details = try schema.node("details", content: Fragment.from([summary, content]))
        let doc = try schema.node("doc", content: Fragment.from(details))
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: TextSelection.create(doc, 2)))
        let command = unsetDetails(schema.nodes["details"]!, schema.nodes["paragraph"]!)
        var dispatched = false
        try expect(!command(state, { _ in dispatched = true }, nil))
        try expect(!dispatched)
        try expect(!command(state, nil, nil))
    }

    test("details: wrapping declines when the parent forbids details") {
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "paragraph+")),
            ("paragraph", NodeSpec(content: "text*", group: "block")),
            ("text", NodeSpec()),
            ("details", DetailsExtension().nodeSpec),
            ("detailsSummary", NodeSpec(content: "text*")),
            ("detailsContent", DetailsContentExtension().nodeSpec)
        ])
        let doc = try schema.node("doc", content: Fragment.from(schema.node("paragraph")))
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc))
        let command = setDetails(schema.nodes["details"]!, schema.nodes["detailsSummary"]!, schema.nodes["detailsContent"]!)
        try expect(!command(state, nil, nil))
        var dispatched = false
        try expect(!command(state, { _ in dispatched = true }, nil))
        try expect(!dispatched)
    }

    test("node-selected details: toggle unwraps the selected section") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<details open><summary>title</summary><p>body</p></details>")
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 0)))
        try expect(editor.run("toggleDetails"))
        try expect(firstDetails(editor) == nil)
        try expectEqual(editor.doc.child(0).textContent, "title")
        try expectEqual(editor.doc.child(1).textContent, "body")
        try editor.doc.check()
    }

    test("node-selected details: disclosure toggles the selected section") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<details open><summary>title</summary><p>body</p></details>")
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 0)))
        try expect(editor.run("toggleDetailsOpen"))
        try expectEqual(firstDetails(editor)?.node.attrs["open"], .bool(false))
    }

    test("details: closing a section moves a selection endpoint out of hidden content") {
        for backwards in [false, true] {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<p>before</p><details open><summary>title</summary><p>body</p></details>")
            let d = firstDetails(editor)!
            let bodyStart = d.pos + d.node.child(0).nodeSize + 3
            select(editor, backwards ? bodyStart + 2 : 1, backwards ? 1 : bodyStart + 2)
            guard let tr = setDetailsOpen(editor.state, pos: d.pos, open: false) else {
                try expect(false); return
            }
            editor.dispatch(tr)
            try expect(editor.state.selection.empty)
            try expectEqual(editor.state.selection.resolvedHead.parent.type.name, "detailsSummary")
        }
    }

    test("details: unwrapping keeps the caret at the start of the summary") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<details open><summary>title</summary><p>body</p></details>")
        select(editor, 2, 2)
        try expect(key(editor, "Backspace"))
        try expectEqual(editor.state.selection.resolvedHead.parent.textContent, "title")
        try expectEqual(editor.state.selection.resolvedHead.parentOffset, 0)
    }

    test("details: unwrapping preserves a backwards body selection") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<details open><summary>title</summary><p>body</p></details>")
        let bodyStart = firstDetails(editor)!.node.child(0).nodeSize + 3
        select(editor, bodyStart + 3, bodyStart + 1)
        try expect(editor.run("unsetDetails"))
        let sel = editor.state.selection
        try expectEqual(sel.resolvedAnchor.parent.textContent, "body")
        try expectEqual(sel.resolvedAnchor.parentOffset, 3)
        try expectEqual(sel.resolvedHead.parentOffset, 1)
    }

    test("details: unwrapping an empty summary keeps the caret in its body") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<details open><summary></summary><p>body</p></details>")
        select(editor, 7, 7)
        try expect(editor.run("unsetDetails"))
        try expectEqual(editor.state.selection.head, 3)
        try expectEqual(editor.state.selection.resolvedHead.parentOffset, 2)
    }

    test("details: schema has details + summary + content") {
        let editor = try Editor(extensions: fullKit())
        let details = editor.schema.nodes["details"]
        try expectNotNil(details)
        try expectEqual(details?.defaultAttrs["open"], .bool(false))
        try expectNotNil(editor.schema.nodes["detailsSummary"])
        try expectNotNil(editor.schema.nodes["detailsContent"])
        try expect(details?.spec.isolating == true)
    }

    test("setDetails wraps the block, opens it, and puts the cursor in the summary") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        try expect(editor.run("setDetails"))
        try expect(editor.isActive(node: "details"))
        try expect(editor.isActive(node: "detailsSummary"), "the cursor lands in the summary")
        let details = firstDetails(editor)
        try expectEqual(details?.node.attrs["open"], .bool(true))
        try expectEqual(details?.node.childCount, 2)
        try expectEqual(details?.node.child(0).type.name, "detailsSummary")
        try expectEqual(details?.node.child(1).type.name, "detailsContent")
        try expectEqual(details?.node.child(1).textContent, "body")
    }

    test("setDetails is a no-op inside an existing details") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        try expect(editor.run("setDetails"))
        try expect(!editor.run("setDetails"))
    }

    test("unsetDetails lifts the content out and keeps the summary as a paragraph") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        _ = editor.run("setDetails")
        try typeHere(editor, "title") // typed into the summary, where the cursor is
        try expect(editor.run("unsetDetails"))
        try expect(!editor.isActive(node: "details"))
        try expectEqual(editor.doc.childCount, 2)
        try expectEqual(editor.doc.child(0).type.name, "paragraph")
        try expectEqual(editor.doc.child(0).textContent, "title")
        try expectEqual(editor.doc.child(1).textContent, "body")
    }

    test("unsetDetails with an empty summary drops the empty paragraph") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        _ = editor.run("setDetails")
        try expect(editor.run("unsetDetails"))
        try expectEqual(editor.doc.childCount, 1)
        try expectEqual(editor.doc.child(0).textContent, "body")
    }

    test("toggleDetails wraps then unwraps") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        try expect(editor.run("toggleDetails"))
        try expect(editor.isActive(node: "details"))
        try expect(editor.run("toggleDetails"))
        try expect(!editor.isActive(node: "details"))
        try expectEqual(editor.doc.textContent, "body")
    }

    test("Mod-Alt-d toggles a details through the keymap") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        try expect(key(editor, "Mod-Alt-d"))
        try expect(editor.isActive(node: "details"))
    }

    test("toggleDetailsOpen flips the open attribute") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        _ = editor.run("setDetails")
        try expectEqual(firstDetails(editor)?.node.attrs["open"], .bool(true))
        try expect(editor.run("toggleDetailsOpen"))
        try expectEqual(firstDetails(editor)?.node.attrs["open"], .bool(false))
        try expect(editor.run("toggleDetailsOpen"))
        try expectEqual(firstDetails(editor)?.node.attrs["open"], .bool(true))
    }

    test("setDetailsOpen sets the attribute at a position") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        _ = editor.run("setDetails")
        let pos = firstDetails(editor)!.pos
        let tr = setDetailsOpen(editor.state, pos: pos, open: false)
        try expectNotNil(tr)
        editor.dispatch(tr!)
        try expectEqual(firstDetails(editor)?.node.attrs["open"], .bool(false))
        // Not a details position (the summary inside it) → nil.
        try expect(setDetailsOpen(editor.state, pos: pos + 1, open: true) == nil)
    }

    test("Enter in the summary moves the cursor into the content and opens it") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        _ = editor.run("setDetails")
        try typeHere(editor, "title")
        _ = editor.run("toggleDetailsOpen") // close it first
        try expectEqual(firstDetails(editor)?.node.attrs["open"], .bool(false))
        try expect(key(editor, "Enter"))
        try expect(editor.isActive(node: "detailsContent"))
        try expect(!editor.isActive(node: "detailsSummary"))
        try expectEqual(firstDetails(editor)?.node.attrs["open"], .bool(true), "Enter opens the section")
        // The summary text is untouched — Enter never splits it.
        try expectEqual(firstDetails(editor)?.node.child(0).textContent, "title")
        // Typing now lands in the content's first block.
        try typeHere(editor, "x")
        try expectEqual(firstDetails(editor)?.node.child(1).textContent, "xbody")
    }

    for leafType in ["horizontalRule", "image", "blockMath"] {
        for hasTrailingParagraph in [false, true] {
            test("details Enter: selects first \(leafType), trailing paragraph \(hasTrailingParagraph)") {
                let editor = try Editor(extensions: fullKit())
                let schema = editor.schema
                let summary = try schema.node("detailsSummary", content: Fragment.from(schema.text("title")))
                let attrs: Attrs = leafType == "image" ? ["src": .string("test.png")]
                    : leafType == "blockMath" ? ["latex": .string("x")] : [:]
                let leaf = try schema.node(leafType, attrs)
                let paragraph = try schema.node("paragraph", content: Fragment.from(schema.text("tail")))
                let body = try schema.node("detailsContent", content: Fragment.from(
                    hasTrailingParagraph ? [leaf, paragraph] : [leaf]))
                let details = try schema.node("details", content: Fragment.from([summary, body]))
                let doc = try schema.node("doc", content: Fragment.from([details, paragraph]))
                editor.setContent(doc)
                select(editor, 3, 3)

                try expect(key(editor, "Enter"))
                try expectEqual(firstDetails(editor)?.node.attrs["open"], .bool(true))
                try expect(editor.state.selection is NodeSelection, "Enter selects the first body atom")
                try expectEqual(editor.state.selection.from, summary.nodeSize + 2)
                try expectEqual((editor.state.selection as? NodeSelection)?.node, leaf)
                try expectEqual(editor.doc.child(0).content, details.content)
                try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
                try expectEqual(editor.doc, doc)
                try expectEqual(editor.state.selection.from, 3)
            }
        }
    }

    test("Backspace at the start of the summary unwraps the details") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        _ = editor.run("setDetails")
        try typeHere(editor, "title")
        // Cursor to the start of the summary.
        let summaryStart = firstDetails(editor)!.pos + 2
        select(editor, summaryStart, summaryStart)
        try expect(key(editor, "Backspace"))
        try expect(!editor.isActive(node: "details"))
        try expectEqual(editor.doc.child(0).textContent, "title")
        try expectEqual(editor.doc.child(1).textContent, "body")
    }

    test("Backspace mid-summary does not unwrap") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        _ = editor.run("setDetails")
        try typeHere(editor, "title")
        try expect(!key(editor, "Backspace"), "the keymap leaves the deletion to the view")
        try expect(editor.isActive(node: "details"))
    }

    test("details is a valid block inside a blockquote and a list item") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        _ = editor.run("toggleBlockquote")
        try expect(editor.run("setDetails"))
        try expect(editor.isActive(node: "blockquote"))
        try expect(editor.isActive(node: "details"))
    }

    test("details: a gap cursor sits after a trailing section, never inside one") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        _ = editor.run("setDetails")
        let d = firstDetails(editor)!
        // After the section: a document ending in a details can still grow.
        try expect(GapCursor.valid(editor.doc.resolve(d.pos + d.node.nodeSize)))
        // Between the summary and the content: Tiptap's `allowGapCursor: false`.
        try expect(!GapCursor.valid(editor.doc.resolve(d.pos + 1 + d.node.child(0).nodeSize)))
    }

    test("details: the slash menu offers it") {
        let items = defaultSlashCommands().filter { $0.command == "toggleDetails" }
        try expectEqual(items.count, 1)
        try expect(items[0].matches("toggle"))
    }
}
