#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// Painting must never leave a lazily-estimated block blank.
///
/// Realization used to be driven only by a `contentOffsetY` write, so a frame
/// could legitimately paint nothing where prose belonged and only fill in later,
/// when something else happened to move the offset. `draw(_:)` now typesets the
/// band it is about to paint.
@MainActor
final class PaintRealizeTests: XCTestCase {
    private func bigEditor(_ n: Int) -> Editor {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let paras = (0 ..< n).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from(paras)))
        return editor
    }

    /// Render the view the way the system would, so `draw(_:)` runs for real.
    private func paint(_ view: EditorTextView) {
        _ = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.draw(view.bounds)
        }
    }

    /// The index of the entry covering `y`. Realize rebuilds `entries` one-for-one
    /// in order, so the index stays valid across it while `topY` does not.
    private func entryIndex(_ l: DocumentLayout, atY y: CGFloat) -> Int? {
        l.entries.firstIndex { y >= $0.topY && y < $0.topY + $0.height }
    }

    /// The real failure: the first layout is built while the view is still
    /// short, so only a small window is realized. The bounds then grow to the
    /// true viewport — which invalidates nothing and does not touch
    /// `contentOffsetY`, so nothing realizes — and the frame paints blank below
    /// the original window.
    func testPaintingRealizesContentTheGrownBoundsNowShow() throws {
        let view = EditorTextView(editor: bigEditor(300))
        view.bounds = CGRect(x: 0, y: 0, width: 390, height: 80)
        let layout = view.ensureLayout()
        XCTAssertTrue(layout.hasEstimatedContent, "a 300-block document starts partly estimated")

        // Well below the window realized at 80 pt tall, but inside the viewport
        // once the view reaches its real height.
        let i = try XCTUnwrap(entryIndex(layout, atY: 1_500))
        XCTAssertTrue(layout.entries[i].estimated, "not realized while the view is short")

        view.bounds.size.height = 2_000   // no invalidation, no offset write
        XCTAssertTrue(view.ensureLayout().entries[i].estimated, "still estimated before painting")

        paint(view)

        XCTAssertFalse(view.ensureLayout().entries[i].estimated,
                       "the band that was painted must have been typeset first")
    }

    /// The hysteresis case: a virtualizing host holds `contentOffsetY` fixed
    /// between re-slices, so the paint path cannot lean on it.
    func testPaintingRealizesWithTheOffsetHeldFixed() throws {
        let view = EditorTextView(editor: bigEditor(300))
        view.bounds = CGRect(x: 0, y: 0, width: 390, height: 800)
        view.contentOffsetY = 400          // one write, then never again
        let layout = view.ensureLayout()

        let i = try XCTUnwrap(entryIndex(layout, atY: layout.height * 0.75))
        XCTAssertTrue(layout.entries[i].estimated, "far down the document, still estimated")

        // The host grows its slice without writing an offset.
        view.bounds.size.height = layout.height
        paint(view)

        XCTAssertFalse(view.ensureLayout().entries[i].estimated, "painted, so realized")
    }

    /// A document under the lazy threshold is laid out in full, so the paint
    /// path must leave it exactly alone.
    func testSmallDocumentIsUnaffected() {
        let view = EditorTextView(editor: bigEditor(8))
        view.bounds = CGRect(x: 0, y: 0, width: 390, height: 800)
        let before = view.ensureLayout()
        XCTAssertFalse(before.hasEstimatedContent)
        let height = before.height
        let blocks = before.blocks.count

        paint(view)

        let after = view.ensureLayout()
        XCTAssertEqual(after.height, height, accuracy: 0.01)
        XCTAssertEqual(after.blocks.count, blocks)
    }
}
#endif
