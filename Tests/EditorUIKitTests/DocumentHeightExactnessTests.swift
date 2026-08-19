#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// `documentHeight` is an estimate past the lazy threshold, and a host that
/// sizes a scroll container to it needs to know that — a short extent is also a
/// short scroll, so the missing tail cannot be reached and never realizes.
@MainActor
final class DocumentHeightExactnessTests: XCTestCase {
    private func editor(_ n: Int, mixed: Bool = false) -> Editor {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        var blocks: [Node] = []
        for i in 0 ..< n {
            let text = Fragment.from([s.text("Para \(i): \(words)")])
            // Block types the estimator under-counts: it assumes a fixed average
            // character width and no wrap overhead, so markers and indents are
            // exactly what it misses.
            if mixed, i % 3 == 1 {
                let item = try! s.node("listItem", [:], content: Fragment.from([try! s.node("paragraph", [:], content: text)]))
                blocks.append(try! s.node("bulletList", [:], content: Fragment.from([item])))
            } else if mixed, i % 3 == 2 {
                blocks.append(try! s.node("blockquote", [:], content: Fragment.from([try! s.node("paragraph", [:], content: text)])))
            } else {
                blocks.append(try! s.node("paragraph", [:], content: text))
            }
        }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from(blocks)))
        return editor
    }

    private func view(_ e: Editor, width: CGFloat = 362, height: CGFloat = 800) -> EditorTextView {
        let v = EditorTextView(editor: e)
        v.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return v
    }

    /// The reference: the same document laid out with no realize window at all.
    private func fullHeight(_ e: Editor, width: CGFloat = 362) -> CGFloat {
        DocumentLayout(doc: e.doc, width: width, theme: DocumentTheme()).height
    }

    func testASmallDocumentIsExactImmediately() {
        let v = view(editor(8))
        XCTAssertTrue(v.documentHeightIsExact)
        XCTAssertEqual(v.measuredDocumentHeight(), v.documentHeight, accuracy: 0.01)
    }

    func testALazyDocumentIsNotExactUntilMeasured() {
        let v = view(editor(300))
        XCTAssertFalse(v.documentHeightIsExact, "most of a 300-block document is estimated")
        _ = v.measuredDocumentHeight()
        XCTAssertTrue(v.documentHeightIsExact, "measuring realizes the whole document")
    }

    func testMeasuredHeightMatchesAFullLayout() {
        let e = editor(300)
        let v = view(e)
        XCTAssertEqual(v.measuredDocumentHeight(), fullHeight(e), accuracy: 0.5)
    }

    /// The regression the app hit, at the library level: the estimate lands
    /// *under* the truth, and a host that sizes a scroll container to it then
    /// has no way to reach — or realize — the tail it cut off. Measured here at
    /// -2.2% on 300 paragraphs at a phone column.
    func testTheEstimateFallsShortAndMeasuringRecoversIt() {
        let e = editor(300)
        let v = view(e)
        let exact = fullHeight(e)
        XCTAssertLessThan(v.documentHeight, exact,
                          "the estimator under-reports this document — the case that clips a note")
        XCTAssertFalse(v.documentHeightIsExact)
        XCTAssertEqual(v.measuredDocumentHeight(), exact, accuracy: 0.5)
        XCTAssertTrue(v.documentHeightIsExact)
    }

    /// The same guarantee over a document carrying lists and quotes as well as
    /// paragraphs.
    ///
    /// Caveat on what this covers: this document currently lays out to exactly
    /// the height of the all-paragraph document of the same length, though an
    /// isolated `bulletList` measures 25 pt taller than a bare paragraph at this
    /// width. Until that is explained, read this as covering the API rather than
    /// the block-type layout.
    func testMeasuredHeightIsExactForAMixOfBlockTypes() {
        let e = editor(300, mixed: true)
        let v = view(e)
        XCTAssertFalse(v.documentHeightIsExact)
        XCTAssertEqual(v.measuredDocumentHeight(), fullHeight(e), accuracy: 0.5)
    }

    /// Measuring keeps its work, unlike laying the document out on a throwaway
    /// view: nothing is left estimated, so scrolling realizes nothing.
    func testMeasuringLeavesTheLayoutRealized() {
        let v = view(editor(300))
        _ = v.measuredDocumentHeight()
        XCTAssertFalse(v.ensureLayout().hasEstimatedContent)
        XCTAssertFalse(v.ensureLayout().entries.contains { $0.estimated })
    }
}
#endif
