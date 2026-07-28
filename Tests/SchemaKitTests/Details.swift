import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
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
