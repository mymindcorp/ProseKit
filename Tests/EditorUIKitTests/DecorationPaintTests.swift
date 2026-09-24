#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// `DocumentLayout.draw(in:clipY:)` painting each kind of decoration: every
/// test gives the decoration a color nothing else on the page uses, paints the
/// layout onto white, and reads the pixel in the middle of where the layout
/// says the decoration is.
@MainActor
final class DecorationPaintTests: XCTestCase {
    private lazy var schema: Schema = try! Editor(extensions: fullKit()).schema

    private func paragraph(_ text: String, marks: [Mark] = []) -> Node {
        try! schema.node("paragraph", [:], content: Fragment.from([schema.text(text, marks)]))
    }
    private func doc(_ children: [Node]) -> Node {
        try! schema.node("doc", [:], content: Fragment.from(children))
    }

    /// The layout painted at 1x onto a white page.
    private func paint(_ layout: DocumentLayout, clipY: ClosedRange<CGFloat>? = nil) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: layout.width, height: max(layout.height, 1))
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            layout.draw(in: ctx.cgContext, clipY: clipY)
        }.cgImage!
    }

    /// The RGB of one pixel, 0…255.
    private func pixel(_ image: CGImage, _ point: CGPoint) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = unsafe CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Shift the image so the wanted pixel lands on the 1×1 canvas (CG is y-up).
        ctx.draw(image, in: CGRect(x: -floor(point.x), y: floor(point.y) - CGFloat(image.height) + 1,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return bytes.prefix(3).map(Int.init)
    }

    private func assertColor(_ rgb: [Int], _ expected: [Int], _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(rgb, expected) where abs(a - b) > 8 {
            XCTFail("\(message): got \(rgb), expected \(expected)", file: file, line: line)
            return
        }
    }

    private func fills(_ layout: DocumentLayout) -> [CGRect] {
        layout.decorations.compactMap { if case let .fill(rect, _) = $0 { return rect } else { return nil } }
    }

    // MARK: - Flat fills

    func testTheQuoteBarIsPaintedInItsColor() throws {
        var theme = DocumentTheme()
        theme.quote.barColor = .red
        theme.quote.barWidth = 6
        let quote = try schema.node("blockquote", [:], content: Fragment.from([paragraph("quoted")]))
        let layout = DocumentLayout(doc: doc([quote]), width: 320, theme: theme)
        let bar = try XCTUnwrap(fills(layout).first)
        let image = paint(layout)
        assertColor(pixel(image, CGPoint(x: bar.midX, y: bar.midY)), [255, 0, 0], "the bar")
        // Clipped to a band that misses it, the bar is skipped.
        let clipped = paint(layout, clipY: (layout.height + 100) ... (layout.height + 200))
        assertColor(pixel(clipped, CGPoint(x: bar.midX, y: bar.midY)), [255, 255, 255], "no bar outside the clip")
    }

    func testAHorizontalRuleIsPaintedInItsColor() throws {
        var theme = DocumentTheme()
        theme.horizontalRule.color = .green
        theme.horizontalRule.thickness = 6
        let layout = DocumentLayout(doc: doc([paragraph("a"), try schema.node("horizontalRule"), paragraph("b")]),
                                    width: 320, theme: theme)
        let rule = try XCTUnwrap(fills(layout).first)
        assertColor(pixel(paint(layout), CGPoint(x: rule.midX, y: rule.midY)), [0, 255, 0], "the rule")
    }

    // MARK: - Rounded fills and strokes

    func testACodeBlockBackgroundIsPaintedBehindTheCode() throws {
        var theme = DocumentTheme()
        theme.code.block.background = .blue
        theme.code.block.padding = EmInsets(1.0)
        let code = try schema.node("codeBlock", [:], content: Fragment.from([schema.text("x")]))
        let layout = DocumentLayout(doc: doc([code]), width: 320, theme: theme)
        let box = try XCTUnwrap(layout.decorations.compactMap { item -> CGRect? in
            if case let .roundedFill(rect, _, _) = item { return rect } else { return nil }
        }.first)
        // Well inside the padding and clear of the rounded corners and the text.
        assertColor(pixel(paint(layout), CGPoint(x: box.maxX - 20, y: box.midY)), [0, 0, 255], "the background")
    }

    func testARoundedImagePlaceholderStrokesItsBox() throws {
        var theme = DocumentTheme()
        theme.image.cornerRadius = 8
        theme.hairlineColor = .magenta
        let image = try schema.node("image", ["src": .string("asset://missing"), "width": .int(200)])
        let layout = DocumentLayout(doc: doc([image]), width: 320, theme: theme)
        let box = try XCTUnwrap(layout.decorations.compactMap { item -> CGRect? in
            if case let .roundedStroke(rect, _, _, _) = item { return rect } else { return nil }
        }.first)
        let painted = paint(layout)
        // The 1pt stroke is inset half its width: the box's top edge, mid-way along.
        let edge = pixel(painted, CGPoint(x: box.midX, y: box.minY))
        XCTAssertGreaterThan(edge[0], 128, "magenta has red…")
        XCTAssertLessThan(edge[1], 200, "…and much less green than white: \(edge)")
        assertColor(pixel(painted, CGPoint(x: box.midX, y: box.midY + 20)), [255, 255, 255], "the inside is empty")
    }

    // MARK: - Math

    func testAFormulaDrawsThroughItsRendering() throws {
        let renderer: MathRenderer = { _, _, _, _ in
            MathRendering(size: CGSize(width: 40, height: 20), ascent: 15) { ctx, origin in
                ctx.setFillColor(UIColor.orange.cgColor)
                ctx.fill(CGRect(origin: origin, size: CGSize(width: 40, height: 20)))
            }
        }
        let layout = DocumentLayout(doc: doc([try schema.node("blockMath", ["latex": .string("x")])]),
                                    width: 320, theme: DocumentTheme(), mathRenderer: renderer)
        let rect = try XCTUnwrap(layout.mathTargets.first).rect
        assertColor(pixel(paint(layout), CGPoint(x: rect.midX, y: rect.midY)), [255, 128, 0], "the formula")
    }

    // MARK: - Inline code

    func testAnInlineCodeRunGetsItsPill() throws {
        var theme = DocumentTheme()
        theme.code.inline.background = .cyan
        let layout = DocumentLayout(doc: doc([paragraph("code", marks: [schema.mark("code")])]),
                                    width: 320, theme: theme)
        let run = try XCTUnwrap(layout.codeBackgrounds.first)
        let rect = try XCTUnwrap(layout.selectionRects(from: run.from, to: run.to).first)
        // The pill extends past the run by its padding; sample in that margin,
        // left of the first glyph, where no text is drawn.
        let padX = theme.points(theme.code.inline.paddingX)
        let sample = CGPoint(x: rect.minX - padX / 2, y: rect.midY)
        let painted = pixel(paint(layout), sample)
        XCTAssertLessThan(painted[0], 200, "cyan has little red: \(painted)")
        XCTAssertGreaterThan(painted[2], 200, "and full blue: \(painted)")

        theme.code.inline.background = nil
        let bare = DocumentLayout(doc: doc([paragraph("code", marks: [schema.mark("code")])]),
                                  width: 320, theme: theme)
        assertColor(pixel(paint(bare), sample), [255, 255, 255], "no pill when the theme turns it off")
    }
}
#endif
