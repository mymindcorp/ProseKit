import Foundation
import DocumentModel
import EditorSerialization
import EditorStateKit
import SchemaKit
import TestHarness

// `imageBlock` — the second image node, always a block of its own.
//
// It is the same node as `image` in every way but the name, which is exactly
// what makes it worth testing: everything downstream recognizes an image by
// name, so a second name is only "the same node" for as long as every one of
// those places asks `isImage` instead of comparing against `"image"`. One
// missed site and an `imageBlock` renders as nothing, exports as nothing, or
// never has its bytes fetched — silently, because a document that holds one
// still loads fine.

/// An editor with both image nodes registered.
private func bothImagesEditor() throws -> Editor { try Editor(extensions: fullKit()) }

/// A one-node document holding an `imageBlock`.
private func imageBlockDoc(_ schema: Schema, _ attrs: Attrs) throws -> Node {
    try schema.node("doc", [:], content: Fragment.from([try schema.node("imageBlock", attrs)]))
}

/// `expectNotNil` returns nothing, so this is the unwrapping form these need.
private func unwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    try expectNotNil(value, file: file, line: line)
    return value!
}

/// Every node name in the document, in order.
private func names(_ doc: Node) -> [String] {
    var out: [String] = []
    doc.descendants { node, _, _, _ in out.append(node.type.name); return true }
    return out
}

func registerImageBlockTests() {
    // MARK: The schema

    test("imageBlock: the full kit registers both image nodes") {
        let editor = try bothImagesEditor()
        try expectNotNil(editor.schema.nodes["image"])
        let block = try unwrap(editor.schema.nodes["imageBlock"])
        try expect(!block.spec.inline, "imageBlock is never inline")
        try expectEqual(block.spec.group, "block")
        try expect(block.spec.atom, "an image has no editable content")
    }

    test("imageBlock: it carries exactly the attributes image does") {
        let editor = try bothImagesEditor()
        let image = try unwrap(editor.schema.nodes["image"])
        let block = try unwrap(editor.schema.nodes["imageBlock"])
        try expectEqual(Set(block.attrs.keys), Set(image.attrs.keys))
    }

    test("imageBlock: both nodes answer isImage, and nothing else does") {
        let editor = try bothImagesEditor()
        for name in ["image", "imageBlock"] {
            try expect(try unwrap(editor.schema.nodes[name]).isImage, "\(name) is an image")
        }
        for name in ["paragraph", "figure", "horizontalRule", "table"] {
            guard let type = editor.schema.nodes[name] else { continue }
            try expect(!type.isImage, "\(name) is not an image")
        }
    }

    test("imageBlock: a schema with only the block variant still resolves an image type") {
        let editor = try Editor(extensions: starterKit() + [imageBlockExtension()])
        try expect(editor.schema.nodes["image"] == nil, "only the block variant is registered")
        try expectEqual(editor.schema.imageNodeType?.name, "imageBlock")
    }

    test("imageBlock: with both registered, the plain image node wins the fallback") {
        let editor = try bothImagesEditor()
        try expectEqual(editor.schema.imageNodeType?.name, "image")
    }

    // MARK: Insertion

    test("imageBlock: insertImageBlock places one at the selection") {
        let editor = try bothImagesEditor()
        try expect(editor.insertImageBlock(src: "/a.png", alt: "a cat", width: 300),
                   "the insert should run")
        let inserted = try unwrap(editor.doc.child(0).type.name == "imageBlock"
            ? editor.doc.child(0) : nil)
        try expectEqual(inserted.attrs["src"], .string("/a.png"))
        try expectEqual(inserted.attrs["alt"], .string("a cat"))
        try expectEqual(inserted.attrs["width"], .int(300))
    }

    test("imageBlock: insertImageBlock declines when the node isn't registered") {
        let editor = try Editor(extensions: starterKit() + [ImageExtension()])
        try expect(!editor.insertImageBlock(src: "/a.png"), "nothing to insert")
    }

    // MARK: The commands that address one

    test("imageBlock: resizing addresses a selected imageBlock") {
        let editor = try bothImagesEditor()
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("before")])),
            try s.node("imageBlock", ["src": .string("/a.png")]),
        ])))
        // paragraph("before") is 8 wide, so the image sits at 8.
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 8)))
        try expect(editor.setImageSize(width: 320, height: 240), "should address the imageBlock")
        try expectEqual(editor.doc.nodeAt(8)?.attrs["width"], .int(320))
        try expectEqual(editor.doc.nodeAt(8)?.attrs["height"], .int(240))
    }

    test("imageBlock: the model round-trips onto one") {
        let editor = try bothImagesEditor()
        editor.setContent(try imageBlockDoc(editor.schema, ["src": .string("thumb.jpg")]))
        let model = ImageModel(path: "originals/raw.dng", width: 4000, height: 3000)
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 0)))
        try expect(editor.setImageModel(model), "should address the imageBlock")
        try expectEqual(editor.doc.child(0).imageModel, model)
    }

    // MARK: Serialization

    test("imageBlock: it survives a ProseMirror JSON round-trip as itself") {
        let editor = try bothImagesEditor()
        let source = try imageBlockDoc(editor.schema, [
            "src": .string("a.png"), "alt": .string("a cat"), "width": .int(120),
        ])
        editor.setContent(source)
        let back = try DocumentJSON.decode(editor.schema, try DocumentJSON.string(source))
        try expectEqual(names(back), ["imageBlock"])
        try expectEqual(back.child(0).attrs["src"], .string("a.png"))
        try expectEqual(back.child(0).attrs["width"], .int(120))
    }

    test("imageBlock: it exports to HTML as an img, like image does") {
        let editor = try bothImagesEditor()
        editor.setContent(try imageBlockDoc(editor.schema, [
            "src": .string("a.png"), "alt": .string("a cat"),
        ]))
        let html = editor.getHTML()
        try expect(html.contains("<img src=\"a.png\""), html)
        try expect(html.contains("alt=\"a cat\""), html)
    }

    test("imageBlock: HTML names the node, so the block variant comes back as itself") {
        let editor = try bothImagesEditor()
        editor.setContent(try imageBlockDoc(editor.schema, ["src": .string("a.png")]))
        let html = editor.getHTML()
        let back = try HTMLParser.parse(html, schema: editor.schema)
        try expect(names(back).contains("imageBlock"), "\(names(back)) — got \(html)")
    }

    test("imageBlock: a plain img still parses to the plain image node") {
        let editor = try bothImagesEditor()
        let back = try HTMLParser.parse("<p><img src=\"a.png\"></p>", schema: editor.schema)
        try expect(names(back).contains("image"), "\(names(back))")
        try expect(!names(back).contains("imageBlock"), "\(names(back))")
    }

    test("imageBlock: an img names a node the schema lacks, and falls back") {
        let editor = try Editor(extensions: starterKit() + [ImageExtension()])
        let back = try HTMLParser.parse("<p><img src=\"a.png\" data-node=\"imageBlock\"></p>",
                                        schema: editor.schema)
        try expect(names(back).contains("image"), "\(names(back))")
    }

    test("imageBlock: it exports to Markdown as an image, like image does") {
        let editor = try bothImagesEditor()
        editor.setContent(try imageBlockDoc(editor.schema, [
            "src": .string("a.png"), "alt": .string("a cat"),
        ]))
        let md = editor.getMarkdown()
        try expectEqual(md.trimmingCharacters(in: .whitespacesAndNewlines), "![a cat](a.png)")
    }

    test("imageBlock: Markdown import fills a schema that only has the block variant") {
        let editor = try Editor(extensions: starterKit() + [imageBlockExtension()])
        let doc = try MarkdownParser.parse("![a cat](a.png)", schema: editor.schema)
        try expect(names(doc).contains("imageBlock"), "\(names(doc))")
    }
}
