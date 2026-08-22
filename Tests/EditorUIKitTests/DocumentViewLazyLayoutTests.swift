#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// The read-only `DocumentView` virtualizes *layout*, not just drawing.
///
/// It used to typeset the whole document before the first frame — the visible
/// window governed painting only. On a 2000-paragraph document that was 150 ms
/// and ~10 MB spent before anything appeared, all of it to draw one viewport.
@MainActor
final class DocumentViewLazyLayoutTests: XCTestCase {
    private func schema() -> Schema { try! Editor(extensions: fullKit()).schema }

    /// Comfortably past `DocumentLayout.lazyThreshold`, so laziness is in play.
    private func tallDoc(_ s: Schema, _ n: Int = 400) -> Node {
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 8).joined(separator: " ")
        let paras = (0 ..< n).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        return try! s.node("doc", [:], content: Fragment.from(paras))
    }

    private func view(_ doc: Node, height: CGFloat = 800) -> DocumentView {
        let v = DocumentView(document: doc)
        v.frame = CGRect(x: 0, y: 0, width: 362, height: height)
        v.layoutIfNeeded()
        return v
    }

    /// Draw a slice into a bitmap and count the pixels that got ink. This is the
    /// test that matters: an estimated block carries no lines, so a layout that
    /// forgot to realize the painted band renders *blank* rather than wrong.
    private func inkPixels(of v: DocumentView) -> Int {
        let w = Int(v.bounds.width), h = Int(v.bounds.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = unsafe CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        v.draw(v.bounds)
        UIGraphicsPopContext()
        var n = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 16 { n += 1 }
        return n
    }

    func testFirstLayoutTypesetsOnlyNearTheViewport() {
        let doc = tallDoc(schema())
        let v = view(doc)
        let laidOut = v.ensureLayout()!.blocks.count
        XCTAssertGreaterThan(laidOut, 0, "the visible viewport must be typeset")
        // A few viewports' worth of paragraphs, not four hundred.
        XCTAssertLessThan(laidOut, 60, "first layout typeset \(laidOut) of \(doc.childCount) blocks")
    }

    func testAScrolledSliceIsNeverPaintedBlank() {
        let doc = tallDoc(schema())
        let v = view(doc)
        let top = inkPixels(of: v)
        XCTAssertGreaterThan(top, 100, "the first viewport must draw")

        // Jump far past anything the cold build or the prefetch realized. Only
        // the paint-path backstop can make this frame correct.
        v.contentOffsetY = v.documentHeight * 0.8
        XCTAssertGreaterThan(inkPixels(of: v), 100, "a deep slice painted blank")
    }

    /// `render(into:height:offsetY:)` takes its own band — a bitmap or PDF page
    /// need not be this view's viewport — so it must realize that band, not the
    /// one `bounds` happens to describe.
    func testRenderRealizesTheBandItWasAskedFor() {
        let doc = tallDoc(schema())
        let v = view(doc)
        let deep = v.documentHeight * 0.75
        let w = 362, h = 400
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = unsafe CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        v.render(into: ctx, height: CGFloat(h), offsetY: deep)
        UIGraphicsPopContext()
        var ink = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 16 { ink += 1 }
        XCTAssertGreaterThan(ink, 100, "an off-viewport render band painted blank")
    }

    /// `sizeThatFits` is a promise, and a host that sizes from it never feeds
    /// `contentOffsetY` — so no later scroll would correct an estimate.
    func testSizeThatFitsIsExactNotEstimated() {
        let doc = tallDoc(schema())
        let exact = DocumentLayout(doc: doc, width: 362, theme: DocumentTheme()).height
        let v = view(doc)
        let fitted = v.sizeThatFits(CGSize(width: 362, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertEqual(fitted, exact, accuracy: 0.5,
                       "sizeThatFits handed back an estimate")
    }

    /// Realizing changes the height. A virtualized host sizes its scroll content
    /// from this handler, so the corrections have to arrive.
    func testHeightCorrectionsAreReported() {
        let doc = tallDoc(schema())
        let v = view(doc)
        var reported: [CGFloat] = []
        v.onDocumentHeightChange = { reported.append($0) }
        let estimated = v.documentHeight
        v.contentOffsetY = v.documentHeight * 0.5
        XCTAssertFalse(reported.isEmpty, "scrolling realized blocks but reported no height change")
        XCTAssertNotEqual(reported.last!, estimated,
                          "the estimate was never corrected")
    }

    /// A short document is under the threshold and must behave exactly as before
    /// — laid out whole, exact height from the first read.
    func testShortDocumentIsStillEagerAndExact() {
        let doc = tallDoc(schema(), 20)
        let v = view(doc)
        XCTAssertFalse(v.ensureLayout()!.hasEstimatedContent)
        let exact = DocumentLayout(doc: doc, width: 362, theme: DocumentTheme()).height
        XCTAssertEqual(v.documentHeight, exact, accuracy: 0.5)
    }
}
#endif
