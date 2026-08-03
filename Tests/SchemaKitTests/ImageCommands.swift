import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

// The commands that address an image already in the document — resizing it and
// recording what it was made from. `insertImage` and the model type were
// covered; these were not, along with the helper both of them use to work out
// which image the selection means.
//
// That helper is the substance here. An image can be addressed three ways —
// selected as a node, or with the caret immediately after or before it — and
// getting it wrong means a resize silently lands on the wrong image, or on
// nothing at all while reporting success.

/// An editor holding `<p>before</p><img><p>after</p>`, and the image's position.
private func editorWithImage() throws -> (editor: Editor, imagePos: Int) {
    let editor = try Editor(extensions: fullKit())
    let s = editor.schema
    let doc = try s.node("doc", [:], content: Fragment.from([
        try s.node("paragraph", [:], content: Fragment.from([s.text("before")])),
        try s.node("image", ["src": .string("/a.png")]),
        try s.node("paragraph", [:], content: Fragment.from([s.text("after")])),
    ]))
    editor.setContent(doc)
    // paragraph("before") is 8 wide, so the image sits at 8.
    return (editor, 8)
}

private func image(_ editor: Editor) -> Node? { editor.doc.nodeAt(8) }

func registerImageCommandTests() {
    // MARK: Addressing — which image the selection means

    test("image commands: a node selection addresses the image it covers") {
        let (editor, pos) = try editorWithImage()
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, pos)))
        try expect(editor.setImageSize(width: 320, height: 240), "should address the image")
        try expectEqual(image(editor)?.attrs["width"], .int(320))
    }

    test("image commands: a caret just before the image addresses it") {
        let (editor, pos) = try editorWithImage()
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, pos)))
        try expect(editor.setImageSize(width: 100, height: nil), "should address the image after")
        try expectEqual(image(editor)?.attrs["width"], .int(100))
    }

    test("image commands: a caret just after the image addresses it") {
        let (editor, pos) = try editorWithImage()
        let after = pos + (image(editor)?.nodeSize ?? 1)
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, after)))
        try expect(editor.setImageSize(width: 50, height: nil), "should address the image before")
        try expectEqual(image(editor)?.attrs["width"], .int(50))
    }

    test("image commands: a caret nowhere near an image addresses nothing") {
        let (editor, _) = try editorWithImage()
        // Inside the first paragraph's text.
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 3)))
        try expect(editor.setImageSize(width: 10, height: 10) == false,
                   "no image is addressed, so the command should not run")
        try expect(editor.setImageModel(ImageModel(path: "/o.png")) == false)
        try expectEqual(image(editor)?.attrs["width"], .null, "nothing should have changed")
    }

    test("image commands: an explicit position wins over the selection") {
        let (editor, pos) = try editorWithImage()
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 3)))
        try expect(editor.setImageSize(width: 640, height: 480, at: pos),
                   "an explicit position needs no selection")
        try expectEqual(image(editor)?.attrs["width"], .int(640))
    }

    test("image commands: a position that isn't an image is refused") {
        let (editor, _) = try editorWithImage()
        try expect(editor.setImageSize(width: 1, height: 1, at: 0) == false,
                   "position 0 is a paragraph")
        try expect(editor.setImageModel(ImageModel(path: "/o.png"), at: 0) == false)
    }

    // MARK: setImageSize

    test("setImageSize: sets both dimensions") {
        let (editor, pos) = try editorWithImage()
        try expect(editor.setImageSize(width: 300, height: 200, at: pos))
        try expectEqual(image(editor)?.attrs["width"], .int(300))
        try expectEqual(image(editor)?.attrs["height"], .int(200))
    }

    test("setImageSize: a nil dimension is cleared, not left behind") {
        // The renderer derives the missing one from the aspect ratio, so a
        // stale height would fight the width it was given.
        let (editor, pos) = try editorWithImage()
        try expect(editor.setImageSize(width: 300, height: 200, at: pos))
        try expect(editor.setImageSize(width: 400, height: nil, at: pos))
        try expectEqual(image(editor)?.attrs["width"], .int(400))
        try expectEqual(image(editor)?.attrs["height"], .null, "the old height should be gone")
    }

    test("setImageSize: clearing both returns the image to its natural size") {
        let (editor, pos) = try editorWithImage()
        try expect(editor.setImageSize(width: 300, height: 200, at: pos))
        try expect(editor.setImageSize(width: nil, height: nil, at: pos))
        try expectEqual(image(editor)?.attrs["width"], .null)
        try expectEqual(image(editor)?.attrs["height"], .null)
    }

    test("setImageSize: the rest of the image is untouched") {
        let (editor, pos) = try editorWithImage()
        try expect(editor.setImageModel(ImageModel(path: "/o.png", width: 1200), at: pos))
        try expect(editor.setImageSize(width: 300, height: 200, at: pos))
        try expectEqual(image(editor)?.attrs["src"], .string("/a.png"))
        try expectEqual(image(editor)?.imageModel?.path, "/o.png")
        try editor.doc.check()
    }

    // MARK: setImageModel

    test("setImageModel: records the original behind the image") {
        let (editor, pos) = try editorWithImage()
        try expect(editor.setImageModel(ImageModel(path: "/orig.png", width: 1200, height: 800),
                                        at: pos))
        let model = image(editor)?.imageModel
        try expectEqual(model?.path, "/orig.png")
        try expectEqual(model?.width, 1200)
        try expectEqual(model?.height, 800)
    }

    test("setImageModel: nil clears it") {
        let (editor, pos) = try editorWithImage()
        try expect(editor.setImageModel(ImageModel(path: "/orig.png"), at: pos))
        try expect(editor.setImageModel(nil, at: pos))
        try expectNil(image(editor)?.imageModel)
        try expectEqual(image(editor)?.attrs["model"], .null)
    }

    test("setImageModel: setting it again replaces the old one") {
        let (editor, pos) = try editorWithImage()
        try expect(editor.setImageModel(ImageModel(path: "/first.png", width: 10), at: pos))
        try expect(editor.setImageModel(ImageModel(path: "/second.png"), at: pos))
        try expectEqual(image(editor)?.imageModel?.path, "/second.png")
        try expect(image(editor)?.imageModel?.width == nil, "the old width should not survive")
    }

    // MARK: A schema without the node

    test("image commands: an editor with no image node refuses them all") {
        let editor = try Editor(extensions: starterKit())
        try expect(editor.schema.nodes["image"] == nil, "starterKit has no image node")
        try expect(editor.insertImage(src: "/a.png") == false)
        try expect(editor.setImageSize(width: 1, height: 1) == false)
        try expect(editor.setImageModel(ImageModel(path: "/o.png")) == false)
    }

    // MARK: Undo

    test("image commands: resizing is one undo step") {
        // Both dimensions go in one transaction, so one Mod-z takes back the
        // whole resize rather than leaving a half-applied size behind.
        let (editor, pos) = try editorWithImage()
        try expect(editor.setImageSize(width: 300, height: 200, at: pos))
        try expectEqual(image(editor)?.attrs["width"], .int(300))
        try expect(key(editor, "Mod-z"), "the resize should be undoable")
        try expectEqual(image(editor)?.attrs["width"], .null, "one undo should clear both")
        try expectEqual(image(editor)?.attrs["height"], .null)
        try expect(key(editor, "Mod-Shift-z"), "and redoable")
        try expectEqual(image(editor)?.attrs["width"], .int(300))
    }

    test("image commands: recording the original is one undo step") {
        let (editor, pos) = try editorWithImage()
        try expect(editor.setImageModel(ImageModel(path: "/orig.png"), at: pos))
        try expect(key(editor, "Mod-z"), "the change should be undoable")
        try expect(image(editor)?.imageModel == nil, "the model should be gone")
    }
}
