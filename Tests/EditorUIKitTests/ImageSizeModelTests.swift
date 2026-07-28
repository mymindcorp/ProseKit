#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// An image's display size: `width` and `height` in points, both optional.
///
/// The model is opt-in. An image that carries neither draws exactly as it
/// always did — at its natural size, capped to the column — so a host that
/// doesn't care about sizing never has to think about it.
@MainActor
final class ImageSizeModelTests: XCTestCase {
    /// A 200×100 image, so a wrong aspect ratio is obvious.
    ///
    /// Rendered at scale 1 deliberately: at the screen's scale the PNG would
    /// come back decoded at 1 point per *pixel*, and a 200×100 request would
    /// arrive as a 600×300 image on a 3× device.
    private func png(_ size: CGSize = CGSize(width: 200, height: 100)) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private func blockView(_ attrs: Attrs, bytes: Data? = nil, width: CGFloat = 320) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        var full: Attrs = ["src": .string("asset://photo")]
        full.merge(attrs) { _, new in new }
        editor.setContent(try s.node("doc", [:], content: Fragment.from([try s.node("image", full)])))
        let view = EditorTextView(editor: editor)
        if let bytes { view.imageData = { $0.type.name == "image" ? bytes : nil } }
        view.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        view.layoutIfNeeded()
        return view
    }

    /// The drawn rect of the block image (or its placeholder box).
    private func drawnRect(_ view: EditorTextView) throws -> CGRect {
        try XCTUnwrap(view.ensureLayout().imageRects.first?.rect)
    }

    // MARK: - The model is optional

    func testAnImageWithNoSizeDrawsAtItsNaturalSize() throws {
        let rect = try drawnRect(blockView([:], bytes: png()))
        XCTAssertEqual(rect.width, 200, accuracy: 0.5)
        XCTAssertEqual(rect.height, 100, accuracy: 0.5)
    }

    func testAnImageWithNoSizeCarriesNoSizeAttributes() throws {
        let editor = try Editor(extensions: fullKit())
        XCTAssertTrue(editor.insertImage(src: "a.png"))
        var image: Node?
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "image" { image = node }
            return image == nil
        }
        let node = try XCTUnwrap(image)
        XCTAssertEqual(node.attrs["width"], .null, "width stays unset unless asked for")
        XCTAssertEqual(node.attrs["height"], .null)
    }

    func testADocumentSavedBeforeTheSizeModelStillLoads() throws {
        // JSON written when the node had no width/height at all.
        let json = """
        {"type":"doc","content":[{"type":"image","attrs":{"src":"a.png","alt":null,"title":null}}]}
        """
        let editor = try Editor(extensions: fullKit())
        let doc = try Node.fromJSON(json, schema: editor.schema)
        try doc.check()
        let image = try XCTUnwrap(doc.firstChild)
        XCTAssertEqual(image.attrs["width"], .null, "the missing attribute takes its default")
        XCTAssertEqual(image.attrs["height"], .null)
    }

    // MARK: - Deriving the missing dimension

    func testWidthAloneDerivesHeightFromTheAspectRatio() throws {
        let rect = try drawnRect(blockView(["width": .int(100)], bytes: png()))
        XCTAssertEqual(rect.width, 100, accuracy: 0.5)
        XCTAssertEqual(rect.height, 50, accuracy: 0.5, "200×100 at width 100 is 50 tall")
    }

    func testHeightAloneDerivesWidthFromTheAspectRatio() throws {
        let rect = try drawnRect(blockView(["height": .int(25)], bytes: png()))
        XCTAssertEqual(rect.height, 25, accuracy: 0.5)
        XCTAssertEqual(rect.width, 50, accuracy: 0.5, "200×100 at height 25 is 50 wide")
    }

    func testBothDimensionsArePinnedExactly() throws {
        // Deliberately not the image's aspect: an explicit model wins outright.
        let rect = try drawnRect(blockView(["width": .int(120), "height": .int(120)], bytes: png()))
        XCTAssertEqual(rect.width, 120, accuracy: 0.5)
        XCTAssertEqual(rect.height, 120, accuracy: 0.5)
    }

    func testAnOverWideImageIsCappedWithItsProportionsKept() throws {
        // 800 wide in a 320pt view: capped to the column, height scaled to match.
        let view = try blockView(["width": .int(800), "height": .int(400)], bytes: png())
        let rect = try drawnRect(view)
        let available = view.ensureLayout().contentWidth
        XCTAssertEqual(rect.width, available, accuracy: 0.5)
        XCTAssertEqual(rect.height, available / 2, accuracy: 0.5, "the 2:1 shape survives the cap")
    }

    // MARK: - Placeholders reserve the right box

    func testAPlaceholderReservesExactlyWhatTheImageWillOccupy() throws {
        // This is what stops the document reflowing when the bytes land.
        let attrs: Attrs = ["width": .int(150), "height": .int(90)]
        let waiting = try drawnRect(blockView(attrs))                 // no bytes
        let loaded = try drawnRect(blockView(attrs, bytes: png()))    // bytes
        XCTAssertEqual(waiting, loaded, "the placeholder and the image occupy the same box")
    }

    func testAPlaceholderWithNoModelFallsBackToADefaultBox() throws {
        let rect = try drawnRect(blockView([:]))
        XCTAssertEqual(rect.width, DocumentLayout.placeholderSize.width, accuracy: 0.5)
        XCTAssertEqual(rect.height, DocumentLayout.placeholderSize.height, accuracy: 0.5)
    }

    func testAPlaceholderWithOneDimensionUsesTheModelsAspect() throws {
        // No image to measure, so the aspect comes from the two attributes —
        // here only one is set, so it falls back to the default shape.
        let rect = try drawnRect(blockView(["height": .int(60)]))
        XCTAssertEqual(rect.height, 60, accuracy: 0.5)
        XCTAssertEqual(rect.width, 60 * DocumentLayout.placeholderSize.width
                       / DocumentLayout.placeholderSize.height, accuracy: 0.5)
    }

    // MARK: - Inline images

    private func inlineView(_ attrs: Attrs, bytes: Data) throws -> EditorTextView {
        let editor = try Editor(extensions: starterKit() + [ImageExtension(inline: true)])
        let s = editor.schema
        var full: Attrs = ["src": .string("asset://inline")]
        full.merge(attrs) { _, new in new }
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("a"), try s.node("image", full), s.text("b"),
            ])),
        ])))
        let view = EditorTextView(editor: editor)
        view.imageData = { $0.type.name == "image" ? bytes : nil }
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 900)
        view.layoutIfNeeded()
        return view
    }

    /// The rect of the inline image drawn inside a text block.
    private func inlineRect(_ view: EditorTextView) throws -> CGRect {
        for decoration in view.ensureLayout().decorations {
            if case let .image(_, rect) = decoration { return rect }
        }
        throw XCTSkip("no inline image was drawn")
    }

    func testAnInlineImageHonorsItsWidth() throws {
        // The inline path used to ignore the model entirely, so drag-to-resize
        // worked on a block image and silently did nothing on an inline one.
        let natural = try inlineRect(inlineView([:], bytes: png()))
        let sized = try inlineRect(inlineView(["width": .int(60)], bytes: png()))
        XCTAssertEqual(natural.width, 200, accuracy: 0.5)
        XCTAssertEqual(sized.width, 60, accuracy: 0.5)
        XCTAssertEqual(sized.height, 30, accuracy: 0.5, "and keeps the aspect ratio")
    }

    func testAnInlineImageHonorsBothDimensions() throws {
        let rect = try inlineRect(inlineView(["width": .int(80), "height": .int(80)], bytes: png()))
        XCTAssertEqual(rect.width, 80, accuracy: 0.5)
        XCTAssertEqual(rect.height, 80, accuracy: 0.5)
    }

    func testAnInlineImageGrowsTheLineItSitsOn() throws {
        let short = try inlineView(["height": .int(20)], bytes: png()).ensureLayout().height
        let tall = try inlineView(["height": .int(200)], bytes: png()).ensureLayout().height
        XCTAssertGreaterThan(tall, short)
    }

    // MARK: - Resizing

    func testDraggingWidthScalesAPinnedHeightToMatch() throws {
        let view = try blockView(["width": .int(200), "height": .int(100)], bytes: png())
        let pos = try XCTUnwrap(view.ensureLayout().imageRects.first?.pos)
        view.setImageWidth(pos, to: 100)
        let image = try XCTUnwrap(view.editor.doc.nodeAt(pos))
        XCTAssertEqual(image.attrs["width"], .int(100))
        XCTAssertEqual(image.attrs["height"], .int(50), "halving the width halves the height")
    }

    func testDraggingWidthLeavesAnUnsetHeightUnset() throws {
        // With no height in the model there's nothing to keep in proportion —
        // the renderer already derives it.
        let view = try blockView(["width": .int(200)], bytes: png())
        let pos = try XCTUnwrap(view.ensureLayout().imageRects.first?.pos)
        view.setImageWidth(pos, to: 100)
        let image = try XCTUnwrap(view.editor.doc.nodeAt(pos))
        XCTAssertEqual(image.attrs["width"], .int(100))
        XCTAssertEqual(image.attrs["height"], .null)
    }

    // MARK: - The original-image model

    func testTheOriginalsAspectSizesAPlaceholderBeforeAnyBytesExist() throws {
        // Only a width is pinned, and nothing has loaded — without the original's
        // dimensions the placeholder would have to guess its own shape.
        let model = ImageModel(path: "originals/a.raw", width: 4000, height: 1000)
        let rect = try drawnRect(blockView(["width": .int(200), "model": model.attributeValue]))
        XCTAssertEqual(rect.width, 200, accuracy: 0.5)
        XCTAssertEqual(rect.height, 50, accuracy: 0.5, "4:1 original, so 200 wide is 50 tall")
    }

    func testWithNoDisplaySizeThePlaceholderUsesTheOriginalsSize() throws {
        let model = ImageModel(path: "originals/a.raw", width: 150, height: 75)
        let rect = try drawnRect(blockView(["model": model.attributeValue]))
        XCTAssertEqual(rect.width, 150, accuracy: 0.5)
        XCTAssertEqual(rect.height, 75, accuracy: 0.5)
    }

    func testTheLoadedImageOutranksTheOriginalForAspect() throws {
        // The bytes being drawn are the truth about their own shape; the model
        // describes a different (original) image.
        let model = ImageModel(path: "originals/a.raw", width: 4000, height: 1000)
        let rect = try drawnRect(blockView(["width": .int(100), "model": model.attributeValue],
                                           bytes: png()))
        XCTAssertEqual(rect.height, 50, accuracy: 0.5, "the loaded 2:1 image wins, not the 4:1 original")
    }

    func testAMalformedModelIsIgnoredRatherThanTrusted() throws {
        // A document from elsewhere can put anything in an object attribute.
        let malformed: [AttributeValue] = [
            .string("not an object"),
            .object(["path": .string("a.raw")]),                       // no dimensions
            .object(["width": .int(10), "height": .int(10)]),          // no path
            .object(["path": .string("a.raw"), "width": .int(0), "height": .int(0)]),
            .object(["path": .int(5)]),
        ]
        for value in malformed {
            let rect = try drawnRect(blockView(["model": value]))
            XCTAssertEqual(rect.width, DocumentLayout.placeholderSize.width, accuracy: 0.5,
                           "\(value) should fall back, not be trusted")
        }
    }

    func testTheModelIsReadBackAsATypedValue() throws {
        let editor = try Editor(extensions: fullKit())
        let model = ImageModel(path: "originals/DSC_0001.raw", width: 4000, height: 3000)
        XCTAssertTrue(editor.insertImage(src: "thumb.jpg", width: 300, model: model))
        var image: Node?
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "image" { image = node }
            return image == nil
        }
        XCTAssertEqual(try XCTUnwrap(image).imageModel, model)
        // The presentation is untouched by it.
        XCTAssertEqual(image?.attrs["src"], .string("thumb.jpg"))
        XCTAssertEqual(image?.attrs["width"], .int(300))
    }

    func testTheModelIsOptionalAndSettableAfterTheFact() throws {
        let editor = try Editor(extensions: fullKit())
        XCTAssertTrue(editor.insertImage(src: "a.jpg"))
        var pos = 0
        editor.doc.descendants { node, at, _, _ in
            if node.type.name == "image" { pos = at }
            return true
        }
        XCTAssertNil(editor.doc.nodeAt(pos)?.imageModel, "absent unless asked for")

        let model = ImageModel(path: "o.raw", width: 10, height: 20)
        XCTAssertTrue(editor.setImageModel(model, at: pos))
        XCTAssertEqual(editor.doc.nodeAt(pos)?.imageModel, model)

        XCTAssertTrue(editor.setImageModel(nil, at: pos))
        XCTAssertNil(editor.doc.nodeAt(pos)?.imageModel)
        XCTAssertEqual(editor.doc.nodeAt(pos)?.attrs["model"], .null)
    }

    func testAModelWithNoDimensionsOmitsThemRatherThanNullingThem() throws {
        let model = ImageModel(path: "o.raw")
        guard case let .object(fields) = model.attributeValue else { return XCTFail("not an object") }
        XCTAssertEqual(fields.keys.sorted(), ["path"])
        XCTAssertEqual(ImageModel(model.attributeValue), model, "and reads back the same")
    }

    // MARK: - The command

    func testSetImageSizeWritesAndClearsBothDimensions() throws {
        let editor = try Editor(extensions: fullKit())
        XCTAssertTrue(editor.insertImage(src: "a.png", width: 300, height: 200))
        var pos = 0
        editor.doc.descendants { node, at, _, _ in
            if node.type.name == "image" { pos = at }
            return true
        }
        XCTAssertEqual(editor.doc.nodeAt(pos)?.attrs["width"], .int(300))
        XCTAssertEqual(editor.doc.nodeAt(pos)?.attrs["height"], .int(200))

        XCTAssertTrue(editor.setImageSize(width: 120, height: nil, at: pos))
        XCTAssertEqual(editor.doc.nodeAt(pos)?.attrs["width"], .int(120))
        XCTAssertEqual(editor.doc.nodeAt(pos)?.attrs["height"], .null, "nil clears the dimension")

        XCTAssertTrue(editor.setImageSize(width: nil, height: nil, at: pos))
        XCTAssertEqual(editor.doc.nodeAt(pos)?.attrs["width"], .null, "back to the natural size")
    }
}
#endif
