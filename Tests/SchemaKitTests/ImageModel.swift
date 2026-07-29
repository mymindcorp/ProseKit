import Foundation
import DocumentModel
import EditorSerialization
import SchemaKit
import TestHarness

// Round-tripping an image's attributes through the schema the editor actually
// builds — `ImageExtension`, not a hand-written stand-in.
//
// The serialization suite has its own schema declared by hand, which has to be
// kept in step with SchemaKit by eye. When it drifts, those tests keep passing
// while real documents lose data: that is precisely how the highlight mark's
// colour went missing for as long as it did. These tests use `fullKit()`, so
// there is nothing to keep in step.

/// An editor with the real image extension, and its schema.
private func imageEditor() throws -> Editor { try Editor(extensions: fullKit()) }

/// The first image node in a document.
private func firstImage(_ doc: Node) -> Node? {
    var found: Node?
    doc.descendants { node, _, _, _ in
        if found == nil, node.type.name == "image" { found = node }
        return found == nil
    }
    return found
}

/// Build a one-image document against `schema`.
private func imageDoc(_ schema: Schema, _ attrs: Attrs) throws -> Node {
    try schema.node("doc", [:], content: Fragment.from([try schema.node("image", attrs)]))
}

func registerImageModelTests() {
    test("image model: a defined model round-trips through HTML") {
        let editor = try imageEditor()
        let model = ImageModel(path: "originals/DSC_0001.raw", width: 4000, height: 3000)
        let source = try imageDoc(editor.schema, [
            "src": .string("renditions/thumb.jpg"),
            "width": .int(300), "height": .int(225),
            "model": model.attributeValue,
        ])
        editor.setContent(source)

        let html = editor.getHTML()
        let restored = try HTMLParser.parse(html, schema: editor.schema)
        try expectEqual(restored, source, "the document changed shape: \(html)")

        // And the model reads back as the value that was put in — not merely as
        // an object that happens to compare equal.
        let image = firstImage(restored)
        try expectEqual(image?.imageModel, model)
        try expectEqual(image?.imageModel?.path, "originals/DSC_0001.raw")
        try expectEqual(image?.imageModel?.width, 4000)
        try expectEqual(image?.imageModel?.height, 3000)
        // The presentation is carried alongside it, not confused with it.
        try expectEqual(image?.attrs["src"], .string("renditions/thumb.jpg"))
        try expectEqual(image?.attrs["width"], .int(300))
    }

    test("image model: a defined model round-trips through JSON") {
        let editor = try imageEditor()
        let model = ImageModel(path: "originals/a.raw", width: 1200, height: 900)
        let source = try imageDoc(editor.schema, ["src": .string("a.jpg"), "model": model.attributeValue])

        let json = try DocumentJSON.string(source)
        try expect(json.contains("\"model\""), json)
        let restored = try DocumentJSON.decode(editor.schema, json)
        try expectEqual(restored, source)
        try expectEqual(firstImage(restored)?.imageModel, model)
    }

    test("image model: a model with only a path round-trips") {
        // The dimensions are optional. An absent one must stay absent rather
        // than coming back as a null field, which wouldn't compare equal.
        let editor = try imageEditor()
        let model = ImageModel(path: "originals/only-a-path.raw")
        let source = try imageDoc(editor.schema, ["src": .string("a.jpg"), "model": model.attributeValue])
        for restored in [try HTMLParser.parse(editor.getHTMLAfterSetting(source), schema: editor.schema),
                         try DocumentJSON.decode(editor.schema, try DocumentJSON.string(source))] {
            try expectEqual(restored, source)
            try expectEqual(firstImage(restored)?.imageModel, model)
            try expectNil(firstImage(restored)?.imageModel?.width)
        }
    }

    test("image model: an undefined model stays undefined") {
        // "If defined" cuts both ways — a plain image must not acquire one.
        let editor = try imageEditor()
        let source = try imageDoc(editor.schema, ["src": .string("a.jpg")])
        editor.setContent(source)
        let html = editor.getHTML()
        try expect(!html.contains("data-model"), "an image with no model gained one: \(html)")
        let restored = try HTMLParser.parse(html, schema: editor.schema)
        try expectEqual(restored, source)
        try expectNil(firstImage(restored)?.imageModel)
        try expectEqual(firstImage(restored)?.attrs["model"], .null)
    }

    test("image model: it survives a second trip through the serializer") {
        // Once is not enough — a value that degrades slightly each pass would
        // still pass a single round-trip.
        let editor = try imageEditor()
        let model = ImageModel(path: "originals/a.raw", width: 10, height: 20)
        let source = try imageDoc(editor.schema, ["src": .string("a.jpg"), "model": model.attributeValue])
        var current = source
        for pass in 1...3 {
            editor.setContent(current)
            current = try HTMLParser.parse(editor.getHTML(), schema: editor.schema)
            try expectEqual(current, source, "pass \(pass) changed the document")
        }
    }

    test("image model: a path needing escaping round-trips intact") {
        // Paths come from a host's asset store and can hold anything.
        let editor = try imageEditor()
        for path in ["a & b.raw", "quote\".raw", "<tag>.raw", "space and 'apostrophe'.raw",
                     "unicode-é-🌍.raw", "a?b=1&c=2"] {
            let model = ImageModel(path: path, width: 1, height: 1)
            let source = try imageDoc(editor.schema, ["src": .string("a.jpg"), "model": model.attributeValue])
            editor.setContent(source)
            let restored = try HTMLParser.parse(editor.getHTML(), schema: editor.schema)
            try expectEqual(firstImage(restored)?.imageModel?.path, path, "\(path) didn't survive")
        }
    }

    test("image model: the real schema declares every attribute the serializer writes") {
        // The guard against the drift these tests exist to catch: if the image
        // node gains an attribute, this fails until the serializer carries it.
        let editor = try imageEditor()
        let type = try expectUnwrap(editor.schema.nodes["image"])
        let declared = Set(type.attrs.keys)
        try expectEqual(declared, ["src", "alt", "title", "width", "height", "model"],
                        "the image node's attributes changed — teach the serializer about them")

        // Every one of them, set at once, has to survive.
        let source = try imageDoc(editor.schema, [
            "src": .string("a.jpg"), "alt": .string("alt text"), "title": .string("a title"),
            "width": .int(320), "height": .int(240),
            "model": ImageModel(path: "o.raw", width: 4000, height: 3000).attributeValue,
        ])
        editor.setContent(source)
        try expectEqual(try HTMLParser.parse(editor.getHTML(), schema: editor.schema), source)
    }
}

/// `expectNotNil` returns nothing, so this is the unwrapping form the tests need.
private func expectUnwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    try expectNotNil(value, file: file, line: line)
    return value!
}

private extension Editor {
    /// Set the document and hand back its HTML, for the loops above.
    func getHTMLAfterSetting(_ doc: Node) -> String {
        setContent(doc)
        return getHTML()
    }
}

func registerMarkdownImageTests() {
    test("markdown: a block image survives serialization") {
        // Images are block-level in the default schema, and `serializeBlock`
        // had no case for them — so they fell through to serializing an atom's
        // (empty) content and every image vanished from the output.
        let editor = try imageEditor()
        editor.setContent(try imageDoc(editor.schema, [
            "src": .string("photo.jpg"), "alt": .string("a photo"),
        ]))
        try expectEqual(editor.getMarkdown(), "![a photo](photo.jpg)")
    }

    test("markdown: a block image survives a round-trip") {
        let editor = try imageEditor()
        let source = try imageDoc(editor.schema, ["src": .string("photo.jpg"), "alt": .string("pic")])
        editor.setContent(source)
        let restored = try MarkdownParser.parse(editor.getMarkdown(), schema: editor.schema)
        try restored.check()
        try expectEqual(firstImage(restored)?.attrs["src"], .string("photo.jpg"))
        try expectEqual(firstImage(restored)?.attrs["alt"], .string("pic"))
    }

    test("markdown: images among other blocks keep their place") {
        let editor = try imageEditor()
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("before")])),
            try s.node("image", ["src": .string("a.jpg"), "alt": .string("one")]),
            try s.node("image", ["src": .string("b.jpg"), "alt": .string("two")]),
            try s.node("paragraph", [:], content: Fragment.from([s.text("after")])),
        ])))
        let markdown = editor.getMarkdown()
        try expectEqual(markdown, "before\n\n![one](a.jpg)\n\n![two](b.jpg)\n\nafter")
        let restored = try MarkdownParser.parse(markdown, schema: s)
        try restored.check()
        try expectEqual(restored.childCount, 4)
    }

    test("markdown: parsing an image yields a valid document") {
        // `![alt](src)` reads as inline content, but an image is block-level in
        // the default schema — so the paragraph built around it was invalid,
        // and nothing checked before handing it back.
        let editor = try imageEditor()
        for markdown in ["![pic](a.jpg)", "text ![pic](a.jpg) more", "- ![pic](a.jpg)",
                         "> ![pic](a.jpg)", "# ![pic](a.jpg)"] {
            let doc = try MarkdownParser.parse(markdown, schema: editor.schema)
            try doc.check()
            try expect(doc.childCount > 0, markdown)
        }
    }

    test("markdown: an image among text is lifted out rather than invalidating it") {
        let editor = try imageEditor()
        let doc = try MarkdownParser.parse("before ![pic](a.jpg) after", schema: editor.schema)
        try doc.check()
        try expect(doc.textContent.contains("before"), doc.textContent)
        try expect(doc.textContent.contains("after"))
        var names: [String] = []
        doc.descendants { node, _, _, _ in
            if !node.isText { names.append(node.type.name) }
            return true
        }
        try expect(names.contains("image"), "the image survives: \(names)")
    }

    test("markdown: an inline-image schema keeps the image in its paragraph") {
        // The same Markdown, in a schema where images are inline, must stay one
        // paragraph rather than being split apart.
        let editor = try Editor(extensions: starterKit() + [ImageExtension(inline: true)])
        let doc = try MarkdownParser.parse("before ![pic](a.jpg) after", schema: editor.schema)
        try doc.check()
        try expectEqual(doc.childCount, 1)
        try expectEqual(doc.child(0).type.name, "paragraph")
        try expectEqual(doc.child(0).childCount, 3, "text, image, text")
    }
}

func registerMarkdownImageEdgeTests() {
    test("markdown: several images in one line keep their order") {
        let editor = try imageEditor()
        let doc = try MarkdownParser.parse("![one](a.jpg) middle ![two](b.jpg)", schema: editor.schema)
        try doc.check()
        var sources: [String] = []
        doc.descendants { node, _, _, _ in
            if node.type.name == "image" { sources.append(node.attrs["src"]?.stringValue ?? "") }
            return true
        }
        try expectEqual(sources, ["a.jpg", "b.jpg"])
        try expect(doc.textContent.contains("middle"), doc.textContent)
    }

    test("markdown: a leading or trailing image leaves no empty paragraph") {
        let editor = try imageEditor()
        for markdown in ["![pic](a.jpg) after", "before ![pic](a.jpg)", "![pic](a.jpg)"] {
            let doc = try MarkdownParser.parse(markdown, schema: editor.schema)
            try doc.check()
            for i in 0..<doc.childCount {
                let child = doc.child(i)
                try expect(child.type.name != "paragraph" || child.content.size > 0,
                           "\(markdown) produced an empty paragraph")
            }
        }
    }

    test("markdown: an image inside a blockquote stays valid") {
        let editor = try imageEditor()
        let doc = try MarkdownParser.parse("> before ![pic](a.jpg) after", schema: editor.schema)
        try doc.check()
        try expect(doc.textContent.contains("before"), doc.textContent)
    }

    test("markdown: an image inside a details summary stays valid") {
        // A summary holds inline content only, so a block-level image there is
        // the same problem one more level down.
        let editor = try imageEditor()
        let doc = try MarkdownParser.parse(
            "<details>\n<summary>![pic](a.jpg)</summary>\n\nbody\n\n</details>", schema: editor.schema)
        try doc.check()
        try expect(doc.textContent.contains("body"), doc.textContent)
    }

    test("markdown: images settle after one round-trip and stay put") {
        // The first pass carries the source's own spacing — splitting
        // `before ![pic](a.jpg) after` leaves "before " and " after" with the
        // spaces that separated them from the image, and serializing writes
        // them out. Re-parsing trims. So the *second* pass onwards is the fixed
        // point; what matters is that it never drifts again.
        let editor = try imageEditor()
        for markdown in ["![pic](a.jpg)", "before ![pic](a.jpg) after"] {
            editor.setContent(try MarkdownParser.parse(markdown, schema: editor.schema))
            editor.setContent(try MarkdownParser.parse(editor.getMarkdown(), schema: editor.schema))
            let settled = editor.getMarkdown()
            for pass in 1...3 {
                editor.setContent(try MarkdownParser.parse(editor.getMarkdown(), schema: editor.schema))
                try expectEqual(editor.getMarkdown(), settled, "\(markdown) drifted on pass \(pass)")
            }
            try expect(settled.contains("![pic](a.jpg)"), "the image is still there: \(settled)")
        }
    }

    test("markdown: an image in a list item survives, but leaves the list") {
        // A block-level image can't sit in a list item until a paragraph has
        // opened it, so the item becomes [paragraph, image] — and Markdown's
        // list syntax here can't express a multi-block item, so serializing
        // puts the image after the list instead of inside it.
        //
        // The image is kept and the document stays valid; only its nesting is
        // lost. Writing multi-block list items would be a separate change.
        let editor = try imageEditor()
        let doc = try MarkdownParser.parse("- ![pic](a.jpg)", schema: editor.schema)
        try doc.check()
        editor.setContent(doc)
        let again = try MarkdownParser.parse(editor.getMarkdown(), schema: editor.schema)
        try again.check()
        var sources: [String] = []
        again.descendants { node, _, _, _ in
            if node.type.name == "image" { sources.append(node.attrs["src"]?.stringValue ?? "") }
            return true
        }
        try expectEqual(sources, ["a.jpg"], "the image itself is never lost")
    }

    test("markdown: a document with no images is untouched by the splitting") {
        // The splitter runs on every paragraph, so ordinary prose must come
        // through with exactly the structure it had.
        let editor = try imageEditor()
        let markdown = "# Title\n\nSome **bold** text.\n\n- one\n- two\n\n> quoted"
        let doc = try MarkdownParser.parse(markdown, schema: editor.schema)
        try doc.check()
        var names: [String] = []
        doc.descendants { node, _, _, _ in
            if !node.isText { names.append(node.type.name) }
            return true
        }
        try expectEqual(names, ["heading", "paragraph", "bulletList", "listItem", "paragraph",
                                "listItem", "paragraph", "blockquote", "paragraph"])
    }

    test("html: lifting a block image out of a paragraph still works") {
        // The splitter is now shared with the Markdown parser; HTML's behaviour
        // must be exactly what it was.
        let editor = try imageEditor()
        let doc = try HTMLParser.parse("<p>before <img src=\"a.jpg\"> after</p>", schema: editor.schema)
        try doc.check()
        var names: [String] = []
        doc.descendants { node, _, _, _ in
            if !node.isText { names.append(node.type.name) }
            return true
        }
        try expectEqual(names, ["paragraph", "image", "paragraph"])
        // Each side keeps the space that separated it from the image, so the
        // concatenated text has both — the paragraphs are "before " and " after".
        try expectEqual(doc.textContent, "before  after")
    }
}

func registerImageModelMarkdownTests() {
    test("image model: Markdown carries only what its image syntax can express") {
        // `![alt](src)` has no slot for a size or an original, so the model is
        // expected to be lost here — pinned so the limit is a stated property
        // rather than a surprise. Uses an inline-image schema because that is
        // where Markdown's image syntax applies at all.
        let editor = try Editor(extensions: starterKit() + [ImageExtension(inline: true)])
        let s = editor.schema
        let model = ImageModel(path: "originals/a.raw", width: 4000, height: 3000)
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                try s.node("image", ["src": .string("thumb.jpg"), "alt": .string("a photo"),
                                     "width": .int(300), "model": model.attributeValue]),
            ])),
        ])))
        let markdown = editor.getMarkdown()
        try expectEqual(markdown, "![a photo](thumb.jpg)")

        let restored = try MarkdownParser.parse(markdown, schema: s)
        // What the syntax can express survives…
        try expectEqual(firstImage(restored)?.attrs["src"], .string("thumb.jpg"))
        try expectEqual(firstImage(restored)?.attrs["alt"], .string("a photo"))
        // …and what it cannot, does not. Use HTML or JSON to keep these.
        try expectNil(firstImage(restored)?.imageModel)
        try expectEqual(firstImage(restored)?.attrs["width"], .null)
    }
}
