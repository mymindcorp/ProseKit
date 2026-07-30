import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// Registered into the shared `collector` from main.swift.

/// The position + node of the first `figure` in the document, if any.
private func firstFigure(_ editor: Editor) -> (pos: Int, node: Node)? {
    var found: (Int, Node)?
    editor.doc.descendants { node, pos, _, _ in
        if found == nil, node.type.name == "figure" { found = (pos, node) }
        return found == nil
    }
    return found
}

func registerFigureTests() {
    test("figure: not registered by default") {
        // Registering it changes the schema, which a host has to opt into — a
        // document with figures can't be opened by one whose schema lacks them.
        let plain = try Editor(extensions: fullKit())
        try expectNil(plain.schema.nodes["figure"])
        try expectNil(plain.schema.nodes["figcaption"])
    }

    test("figure: registered when the extension is added") {
        let editor = try Editor(extensions: fullKit() + figureExtensions())
        let figure = editor.schema.nodes["figure"]
        try expectNotNil(figure)
        try expectNotNil(editor.schema.nodes["figcaption"])
        try expect(figure?.spec.isolating == true)
    }

    test("figure: a caption can only be a figure's last child") {
        // `figcaption` is in no group, so `block+` can't match it — the caption
        // can't drift into a paragraph's place or repeat.
        let editor = try Editor(extensions: fullKit() + figureExtensions())
        let caption = editor.schema.nodes["figcaption"]
        try expectNotNil(caption)
        try expectEqual(caption?.spec.group, nil)
        // A caption isn't valid where a block is expected — not at the top
        // level, and not in a paragraph's place inside the figure.
        guard let doc = editor.schema.nodes["doc"], let figure = editor.schema.nodes["figure"],
              let paragraph = editor.schema.nodes["paragraph"] else {
            try expect(false, "schema missing nodes"); return
        }
        try expectNil(doc.contentMatch.matchType(caption!))
        try expectNotNil(figure.contentMatch.matchType(paragraph))
        // ...but it is valid after the figure's blocks.
        try expectNotNil(figure.contentMatch.matchType(paragraph)?.matchType(caption!))
    }

    test("setFigure wraps the block and puts the cursor in the caption") {
        let editor = try Editor(extensions: fullKit() + figureExtensions())
        try editor.setContent(html: "<p>body</p>")
        try expect(editor.run("setFigure"), "setFigure should apply")
        guard let (pos, figure) = firstFigure(editor) else {
            try expect(false, "no figure created"); return
        }
        try expectEqual(figure.child(0).type.name, "paragraph")
        try expectEqual(figure.child(0).textContent, "body")
        try expectEqual(figure.lastChild?.type.name, "figcaption")
        try expectEqual(figure.lastChild?.textContent, "")
        // The cursor sits in the empty caption, ready to be typed into.
        let resolved = editor.state.doc.resolve(editor.state.selection.from)
        try expectEqual(resolved.parent.type.name, "figcaption")
        _ = pos
    }

    test("typing after setFigure lands in the caption") {
        let editor = try Editor(extensions: fullKit() + figureExtensions())
        try editor.setContent(html: "<p>body</p>")
        _ = editor.run("setFigure")
        let tr = editor.state.tr
        try tr.insertText("A cat")
        editor.dispatch(tr)
        try expectEqual(firstFigure(editor)?.node.lastChild?.textContent, "A cat")
    }

    test("setFigure declines inside an existing figure") {
        let editor = try Editor(extensions: fullKit() + figureExtensions())
        try editor.setContent(html: "<p>body</p>")
        _ = editor.run("setFigure")
        try expect(!editor.run("setFigure"), "should not nest a figure in a figure")
    }

    test("unsetFigure lifts the blocks and keeps the caption as a paragraph") {
        let editor = try Editor(extensions: fullKit() + figureExtensions())
        try editor.setContent(html: "<figure><p>body</p><figcaption>A cat</figcaption></figure>")
        try expectNotNil(firstFigure(editor))
        try expect(editor.run("unsetFigure"), "unsetFigure should apply")
        try expectNil(firstFigure(editor))
        try expectEqual(editor.doc.childCount, 2)
        try expectEqual(editor.doc.child(0).textContent, "body")
        try expectEqual(editor.doc.child(1).textContent, "A cat")
    }

    test("unsetFigure drops an empty caption rather than leaving a blank line") {
        let editor = try Editor(extensions: fullKit() + figureExtensions())
        try editor.setContent(html: "<figure><p>body</p><figcaption></figcaption></figure>")
        _ = editor.run("unsetFigure")
        try expectEqual(editor.doc.childCount, 1)
        try expectEqual(editor.doc.child(0).textContent, "body")
    }

    test("toggleFigure wraps then unwraps") {
        let editor = try Editor(extensions: fullKit() + figureExtensions())
        try editor.setContent(html: "<p>body</p>")
        try expect(editor.run("toggleFigure"))
        try expectNotNil(firstFigure(editor))
        try expect(editor.run("toggleFigure"))
        try expectNil(firstFigure(editor))
        try expectEqual(editor.doc.child(0).textContent, "body")
    }

    test("figure: pasted figure markup keeps its caption") {
        let editor = try Editor(extensions: fullKit() + figureExtensions())
        try editor.setContent(html:
            "<figure><img src=\"a.png\" alt=\"cat\"><figcaption>A <em>cat</em></figcaption></figure>")
        guard let (_, figure) = firstFigure(editor) else {
            try expect(false, "figure not parsed"); return
        }
        try expectEqual(figure.lastChild?.type.name, "figcaption")
        try expectEqual(figure.lastChild?.textContent, "A cat")
    }

    test("figure: pasted figure markup degrades without the extension") {
        // The host that hasn't opted in keeps the image and the caption's words.
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html:
            "<figure><img src=\"a.png\" alt=\"cat\"><figcaption>A cat</figcaption></figure>")
        try expectNil(firstFigure(editor))
        try expect(editor.doc.textContent.contains("A cat"), "caption lost: \(editor.doc.textContent)")
        var hasImage = false
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "image" { hasImage = true }
            return !hasImage
        }
        try expect(hasImage, "image lost")
    }
}
