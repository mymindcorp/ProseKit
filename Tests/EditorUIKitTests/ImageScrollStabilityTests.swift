#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// Scrolling an article whose blocks are photographs.
///
/// Under lazy layout an off-screen block is a guess until it is typeset, and the
/// guess is made from the block's *text*. A picture has none, so every image the
/// reader had not yet reached stood in at one line of body text and grew to its
/// real height the moment they scrolled near it. On a sixty-photograph article
/// the document nearly doubled in height while being read — 13,000 points to
/// 25,900 — in jumps of up to 469, most of a viewport each.
///
/// What that costs the reader: the scroll indicator shrinks and jumps for the
/// whole length of the article, a fling never lands where it was thrown, and
/// scrolling back up shoves the paragraph under their finger down the screen as
/// the images above it take up the room they always needed.
///
/// The fix is that an image's box is knowable without its bytes —
/// `imageDisplaySize` is what reserves the placeholder — so the estimate can
/// simply ask for it.
@MainActor
final class ImageScrollStabilityTests: XCTestCase {
    private let column: CGFloat = 362
    private let viewport: CGFloat = 800

    private func schema() -> Schema { try! Editor(extensions: fullKit()).schema }

    private func paragraph(_ s: Schema, _ i: Int) -> Node {
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 8).joined(separator: " ")
        return try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
    }

    /// An image node carrying its original dimensions, the way a host that has
    /// seen the file records them.
    private func image(_ s: Schema, _ i: Int, original: CGSize = CGSize(width: 1600, height: 1200)) -> Node {
        try! s.node("image", [
            "src": .string("asset://photo-\(i)"),
            "model": .object([
                "path": .string("photo-\(i)"),
                "width": .int(Int(original.width)),
                "height": .int(Int(original.height)),
            ]),
        ])
    }

    /// An article: a paragraph, then a photograph, repeated.
    private func article(_ s: Schema, images: Int = 60) -> Node {
        var children: [Node] = []
        for i in 0 ..< images {
            children.append(paragraph(s, i))
            children.append(image(s, i))
        }
        return try! s.node("doc", [:], content: Fragment.from(children))
    }

    /// The height with every block typeset — what the estimate is judged against.
    private func exactHeight(_ v: DocumentView) -> CGFloat {
        v.sizeThatFits(CGSize(width: column, height: .greatestFiniteMagnitude)).height
    }

    private func view(_ doc: Node) -> DocumentView {
        let v = DocumentView(document: doc)
        v.frame = CGRect(x: 0, y: 0, width: column, height: viewport)
        v.layoutIfNeeded()
        return v
    }

    /// Read the article a viewport at a time and report the worst single change
    /// in reported height, and the total drift from the first frame.
    private func scrollThrough(_ v: DocumentView) -> (drift: CGFloat, worstJump: CGFloat) {
        let first = v.documentHeight
        var previous = first
        var worstJump: CGFloat = 0
        var offset: CGFloat = 0
        while offset < v.documentHeight {
            v.contentOffsetY = offset
            let now = v.documentHeight
            worstJump = max(worstJump, abs(now - previous))
            previous = now
            offset += viewport
        }
        return (abs(v.documentHeight - first), worstJump)
    }

    // MARK: - The estimate knows how tall a picture is

    /// An article of nothing but photographs has no text to estimate, so its
    /// height is knowable exactly before a single block is typeset.
    func testAnArticleOfImagesIsItsFullHeightBeforeItIsTypeset() {
        let s = schema()
        let doc = try! s.node("doc", [:], content: Fragment.from((0 ..< 120).map { image(s, $0) }))
        let v = view(doc)
        XCTAssertTrue(v.ensureLayout()!.hasEstimatedContent,
                      "the document must be big enough for lazy layout to apply")
        let estimated = v.documentHeight
        let exact = exactHeight(v)
        XCTAssertEqual(estimated, exact, accuracy: 0.5,
                       "estimated \(estimated) but measured \(exact)")
    }

    /// The whole point: reading it through doesn't move the ground.
    func testReadingAnIllustratedArticleDoesNotResizeIt() {
        let v = view(article(schema()))
        let (drift, worstJump) = scrollThrough(v)
        // What's left is the ordinary text estimator's error on the prose, ~9pt
        // a paragraph — not a picture's worth. Before this, drift was 12,659 and
        // the worst jump 469.
        XCTAssertLessThan(worstJump, 60, "the document jumped \(worstJump)pt in one scroll step")
        XCTAssertLessThan(drift, v.documentHeight * 0.1,
                          "the document moved \(drift)pt over its full length")
    }

    /// Scrolling *back* is where the reader sees it: blocks above the viewport
    /// growing push what they are reading down the screen.
    func testScrollingBackUpThroughImagesDoesNotShiftTheText() {
        let v = view(article(schema()))
        _ = scrollThrough(v) // read to the end, then turn around
        var offset = v.documentHeight - viewport
        var previous = v.documentHeight
        var worstJump: CGFloat = 0
        while offset > 0 {
            v.contentOffsetY = offset
            worstJump = max(worstJump, abs(v.documentHeight - previous))
            previous = v.documentHeight
            offset -= viewport
        }
        XCTAssertLessThan(worstJump, 60, "scrolling back moved the document \(worstJump)pt")
    }

    /// A picture whose bytes have not arrived reserves the placeholder box, and
    /// that is the box the estimate has to agree with — otherwise realizing an
    /// image with nothing to draw yet is itself a jump.
    func testAnImageWithNoRecordedSizeEstimatesItsPlaceholder() {
        let s = schema()
        let bare = (0 ..< 120).map { i in try! s.node("image", ["src": .string("asset://p-\(i)")]) }
        let v = view(try! s.node("doc", [:], content: Fragment.from(bare)))
        XCTAssertEqual(v.documentHeight, exactHeight(v), accuracy: 0.5)
    }

    // MARK: - Pictures inside other blocks

    /// A figure is a picture with a caption. The caption is text and estimates
    /// as text; the illustration is not, and used to count as nothing.
    func testAFigureIsEstimatedIncludingItsIllustration() {
        let editor = try! Editor(extensions: fullKit() + figureExtensions())
        let s = editor.schema
        let figures = (0 ..< 80).map { i in
            try! s.node("figure", [:], content: Fragment.from([
                image(s, i),
                try! s.node("figcaption", [:], content: Fragment.from([s.text("Figure \(i)")])),
            ]))
        }
        let doc = try! s.node("doc", [:], content: Fragment.from(figures))
        let v = DocumentView(document: doc)
        v.frame = CGRect(x: 0, y: 0, width: column, height: viewport)
        v.layoutIfNeeded()
        let estimated = v.documentHeight
        let exact = exactHeight(v)
        XCTAssertEqual(estimated, exact, accuracy: exact * 0.05,
                       "estimated \(estimated) but measured \(exact)")
    }

    /// An inline image sits *in* a line of prose, so it only adds what it makes
    /// that line taller by — counting its whole box would over-report instead.
    func testAnInlineImageAddsOnlyWhatItMakesItsLineTaller() {
        let s = schema()
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 8).joined(separator: " ")
        let paras = (0 ..< 120).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([
                s.text("Para \(i): \(words) "),
                image(s, i, original: CGSize(width: 40, height: 40)),
            ]))
        }
        let v = view(try! s.node("doc", [:], content: Fragment.from(paras)))
        let estimated = v.documentHeight
        let exact = exactHeight(v)
        XCTAssertEqual(estimated, exact, accuracy: exact * 0.2,
                       "estimated \(estimated) but measured \(exact)")
    }
}
#endif
