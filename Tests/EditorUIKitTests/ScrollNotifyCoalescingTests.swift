#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorStateKit
import DocumentTransform
@testable import EditorUIKit

/// Answering UIKit's per-tick questions during a scroll.
///
/// UIKit rebuilds its RTI document state on every `selectionDidChange`, asking
/// back for the selected text and character rects. We still notify per tick —
/// the system draws the selection and its own caret from that geometry, so
/// coalescing leaves both lagging the content mid-scroll. Instead the answers
/// are cached, since a scroll changes neither the document nor the selection.
///
/// The trap being guarded here: lazy realization turns estimated heights into
/// real ones and shifts everything below, so document-space geometry can go
/// stale while the document revision sits perfectly still.
@MainActor
final class ScrollNotifyCoalescingTests: XCTestCase {
    private final class SpyDelegate: NSObject, UITextInputDelegate {
        var selectionChanges = 0
        func selectionWillChange(_ textInput: (any UITextInput)?) {}
        func selectionDidChange(_ textInput: (any UITextInput)?) { selectionChanges += 1 }
        func textWillChange(_ textInput: (any UITextInput)?) {}
        func textDidChange(_ textInput: (any UITextInput)?) {}
        @available(iOS 18.4, *)
        func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
    }

    private func view(_ paragraphs: Int, words: Int = 12) -> (EditorTextView, Editor) {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let body = Array(repeating: "lorem ipsum dolor sit amet", count: words).joined(separator: " ")
        let paras = (0 ..< paragraphs).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(body)")]))
        }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from(paras)))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        v.layoutIfNeeded()
        return (v, editor)
    }

    func testScrollStillNotifiesOnEveryTick() {
        // Kept deliberately: the system draws the selection and its native
        // caret from this geometry. `UITextInputTests.testScrollResyncsSelectionGeometry`
        // covers the same ground; this pins it for a document-sized selection,
        // the case where notifying is expensive and skipping it is tempting.
        let (v, editor) = view(200)
        let spy = SpyDelegate()
        v.inputDelegate = spy
        let tr = editor.state.tr
        tr.setSelection(TextSelection.create(tr.doc, 1, tr.doc.content.size - 1))
        editor.dispatch(tr)
        spy.selectionChanges = 0
        for i in 1 ... 20 { v.contentOffsetY = CGFloat(i) * 10 }
        XCTAssertEqual(spy.selectionChanges, 20, "every tick must re-sync, however large the selection")
    }

    func testRepeatedTextQueriesAgreeWhileScrolling() {
        let (v, editor) = view(200)
        let range = DocTextRange(1, editor.doc.content.size - 1)
        let first = v.text(in: range)
        XCTAssertFalse(first!.isEmpty)
        for i in 1 ... 30 {
            v.contentOffsetY = CGFloat(i) * 40
            XCTAssertEqual(v.text(in: range), first, "scrolling changed the text UIKit is told")
        }
    }

    func testEditingInvalidatesTheCachedText() {
        let (v, _) = view(20)
        let range = DocTextRange(1, 12)
        let before = v.text(in: range)
        v.insertText("XYZ")
        v.layoutIfNeeded()
        XCTAssertNotEqual(v.text(in: range), before, "an edit must not serve stale text")
        XCTAssertEqual(v.text(in: range), v.projectedText(from: 1, to: 12))
    }

    func testFirstRectFollowsTheScrollAndSurvivesRealization() {
        // ~500-word paragraphs, so the document is long enough to still be
        // largely estimated — scrolling realizes more of it and moves the
        // geometry underneath any cache.
        let (v, editor) = view(60, words: 100)
        let range = DocTextRange(1, editor.doc.content.size - 1)
        for i in 0 ... 12 {
            let y = CGFloat(i) * 1500
            v.contentOffsetY = y
            v.layoutIfNeeded()
            let cached = v.firstRect(for: range)
            // The truth, computed fresh against the layout as it stands now.
            v.firstRectCache.removeAll()
            let fresh = v.firstRect(for: range)
            XCTAssertEqual(cached.origin.y, fresh.origin.y, accuracy: 0.01,
                           "cached first rect went stale at y=\(y)")
            XCTAssertEqual(cached.origin.x, fresh.origin.x, accuracy: 0.01)
        }
    }

    func testManyDistinctRangesAllStayCachedAcrossTicks() {
        // The bug in the first attempt at this: the caches held one entry, and
        // UIKit asks about many ranges per tick — character rects, tokenizer
        // probes — so every question evicted the last one and nothing ever
        // hit. It asks the *same* set each tick, so the set must be kept.
        let (v, editor) = view(200)
        let size = editor.doc.content.size
        let ranges = (0 ..< 60).map { DocTextRange(1 + $0 * 7, 1 + $0 * 7 + 5) }
        v.contentOffsetY = 500
        v.layoutIfNeeded()
        for r in ranges { _ = v.firstRect(for: r); _ = v.text(in: r) }

        // A second pass at the same offset must be served from the caches, so
        // clearing them has to change nothing about the answers.
        let cachedRects = ranges.map { v.firstRect(for: $0) }
        let cachedText = ranges.map { v.text(in: $0) }
        XCTAssertEqual(v.firstRectCache.count, ranges.count, "rects did not all stay cached")
        v.firstRectCache.removeAll()
        XCTAssertEqual(ranges.map { v.firstRect(for: $0) }, cachedRects)
        XCTAssertEqual(ranges.map { v.text(in: $0) }, cachedText)
        XCTAssertLessThan(size, 1_000_000)   // sanity: the doc is what we think
    }

    func testProjectedTextIsUnchangedBySlicing() {
        // The text handed to UIKit must stay one character per document
        // position now that whole nodes are no longer copied to slice them.
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let paras = [
            try! s.node("paragraph", [:], content: Fragment.from([s.text("first paragraph here")])),
            try! s.node("paragraph", [:], content: Fragment.from([s.text("second with 😀 emoji")])),
            try! s.node("paragraph", [:], content: Fragment.from([s.text("third cafe\u{0301} one")])),
        ]
        editor.setContent(try! s.node("doc", [:], content: Fragment.from(paras)))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        v.layoutIfNeeded()

        let size = editor.doc.content.size
        for from in 0 ... size {
            for to in from ... size {
                XCTAssertEqual(v.projectedText(from: from, to: to).count, max(0, to - from),
                               "range \(from)..<\(to) broke one-character-per-position")
            }
        }
        // A partial slice is the middle of the node, not its head.
        let whole = Array(v.projectedText(from: 1, to: size - 1))
        let middle = Array(v.projectedText(from: 3, to: 9))
        XCTAssertEqual(Array(whole[2 ..< 8]), middle)
    }
}
#endif
