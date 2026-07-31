#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class FigureRenderTests: XCTestCase {
    private func editor(caption: String, body: String = "body") throws -> Editor {
        let editor = try Editor(extensions: fullKit() + figureExtensions())
        let s = editor.schema
        let figure = try s.node("figure", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text(body)])),
            try s.node("figcaption", [:], content: Fragment.from([s.text(caption)])),
        ]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([figure])))
        return editor
    }

    private func view(_ editor: Editor, theme: TextTheme = TextTheme()) -> EditorTextView {
        let v = EditorTextView(editor: editor, theme: theme)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        v.backgroundColor = .white
        v.layoutIfNeeded()
        return v
    }

    private func block(_ layout: DocumentLayout, _ text: String) -> TextBlock? {
        layout.blocks.first { $0.attributed.string == text }
    }

    /// The caption used to render nothing at all: `figcaption` fell to the
    /// layout's default branch, which walks a node's children as blocks — and a
    /// caption's children are inline.
    func testCaptionIsLaidOutAtAll() throws {
        let layout = view(try editor(caption: "A cat")).ensureLayout()
        XCTAssertNotNil(block(layout, "A cat"), "caption produced no block")
    }

    func testCaptionSitsBelowTheBodyAndIsCentred() throws {
        let layout = view(try editor(caption: "A cat")).ensureLayout()
        guard let caption = block(layout, "A cat"), let body = block(layout, "body") else {
            return XCTFail("missing blocks")
        }
        XCTAssertGreaterThan(caption.frame.minY, body.frame.minY, "caption should sit below the body")
        // Body text starts at the content's leading edge; a centred caption is
        // pushed in from it. (Origins are in view coordinates, so both include
        // the page inset.)
        let bodyX = try XCTUnwrap(body.lines.first).baselineOrigin.x
        let captionX = try XCTUnwrap(caption.lines.first).baselineOrigin.x
        XCTAssertGreaterThan(captionX, bodyX + 1, "caption was not centred")
    }

    func testCaptionAlignmentIsThemeable() throws {
        var theme = TextTheme()
        theme.captionAlignment = .natural
        let layout = view(try editor(caption: "A cat"), theme: theme).ensureLayout()
        let caption = try XCTUnwrap(block(layout, "A cat"))
        let body = try XCTUnwrap(block(layout, "body"))
        XCTAssertEqual(try XCTUnwrap(caption.lines.first).baselineOrigin.x,
                       try XCTUnwrap(body.lines.first).baselineOrigin.x, accuracy: 0.5,
                       "with natural alignment the caption starts where body text does")
    }

    func testCaptionFontIsSmallerThanBody() throws {
        var theme = TextTheme()
        theme.dynamicType = false
        let e = try editor(caption: "A cat")
        let node = try e.schema.nodes["figcaption"]!.create(
            [:], content: Fragment.from([e.schema.text("A cat")]))
        XCTAssertLessThan(theme.blockFont(node).pointSize, theme.bodyFont.pointSize)
    }

    func testCaptionColourReachesTheScreen() throws {
        var theme = TextTheme()
        theme.captionColor = .systemRed
        let v = view(try editor(caption: "A cat"), theme: theme)
        let image = UIGraphicsImageRenderer(bounds: v.bounds).image { _ in
            v.layer.render(in: UIGraphicsGetCurrentContext()!)
        }
        XCTAssertTrue(hasPixel(image) { r, g, b in r > 150 && g < 100 && b < 100 },
                      "caption colour not drawn")
    }

    func testCaptionTucksUnderItsFigure() throws {
        let theme = TextTheme()
        let e = try editor(caption: "A cat")
        let node = try e.schema.nodes["figcaption"]!.create(
            [:], content: Fragment.from([e.schema.text("A cat")]))
        XCTAssertLessThan(theme.spacingBefore(node, isFirst: false), theme.paragraphSpacing,
                          "caption should tuck under its figure, not float a paragraph away")
        XCTAssertEqual(theme.spacingBefore(node, isFirst: true), 0)
    }

    func testCaptionIsEditableLikeAnyTextblock() throws {
        let e = try editor(caption: "A cat")
        let v = view(e)
        let caption = try XCTUnwrap(block(v.ensureLayout(), "A cat"))
        let tr = e.state.tr
        tr.setSelection(TextSelection.create(tr.doc, caption.contentEnd))
        e.dispatch(tr)
        v.insertText("!")
        XCTAssertTrue(e.doc.textContent.contains("A cat!"), "got: \(e.doc.textContent)")
    }

    func testFigureWithoutACaptionStillLaysOutItsBody() throws {
        let e = try Editor(extensions: fullKit() + figureExtensions())
        let s = e.schema
        let figure = try s.node("figure", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("body")])),
        ]))
        e.setContent(try s.node("doc", [:], content: Fragment.from([figure])))
        XCTAssertNotNil(block(view(e).ensureLayout(), "body"))
    }

    private func hasPixel(_ image: UIImage, _ predicate: (UInt8, UInt8, UInt8) -> Bool) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: data.count, by: 4)
        where predicate(data[i], data[i + 1], data[i + 2]) { return true }
        return false
    }
}
#endif
