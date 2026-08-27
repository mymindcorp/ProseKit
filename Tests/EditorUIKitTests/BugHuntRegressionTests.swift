#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Regressions found by reading the layer rather than by a failing screen.
@MainActor
final class BugHuntRegressionTests: XCTestCase {

    // MARK: an emoji at a soft wrap

    /// ↓ and ↑ move by one line. The clamp that stops the caret bouncing past a
    /// soft-wrapped line used to back up one UTF-16 unit, which lands inside a
    /// surrogate pair when the wrap falls after an emoji — and a broken pair
    /// counts as a whole character again, putting the caret on the line the
    /// clamp was steering it away from.
    func testDownArrowDoesNotSkipAWrappedLineEndingInAnEmoji() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        // No spaces: the wrap has to fall between emoji, mid-run.
        let text = String(repeating: "😀", count: 60)
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
        ])))
        let layout = DocumentLayout(doc: editor.doc, width: 200, theme: DocumentTheme())
        let block = try XCTUnwrap(layout.blocks.first)
        try XCTSkipUnless(block.lines.count >= 3, "needs at least three wrapped lines")

        // Start on the first line, at a column past where the lines wrap.
        let start = block.contentStart + 1
        let farRight = block.frame.maxX
        let first = try XCTUnwrap(layout.verticalPosition(from: start, up: false, preferredX: farRight))
        let second = try XCTUnwrap(layout.verticalPosition(from: first, up: false, preferredX: farRight))
        XCTAssertGreaterThan(first, start, "↓ moves forward")
        XCTAssertGreaterThan(second, first, "↓ keeps moving forward")

        // Each ↓ crosses exactly one line, so the caret is never two lines on.
        func lineIndex(_ pos: Int) -> Int? {
            let attr = block.attrIndex(forDocPos: pos)
            return block.lines.lastIndex { attr >= $0.stringRange.location }
        }
        let startLine = try XCTUnwrap(lineIndex(start))
        XCTAssertEqual(lineIndex(first), startLine + 1, "one line down, not two")
        XCTAssertEqual(lineIndex(second), startLine + 2, "one line down, not two")
    }

    // MARK: a mention is words, not a picture

    /// Every inline atom that can say what it is, says it. A mention used to
    /// fall to the "no spelling for this" branch and typeset as 🖼.
    func testAMentionTypesetsAsItsLabel() throws {
        let editor = try Editor(extensions: fullKit(mentionSuggestions: { _ in [] }))
        let s = editor.schema
        let mention = try s.node("mention", ["id": .string("u1"), "label": .string("Ari")])
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("ask "), mention])),
        ])))
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: DocumentTheme())
        let text = try XCTUnwrap(layout.blocks.first).attributed.string
        XCTAssertTrue(text.contains("@Ari"), "typeset as \(text)")
        XCTAssertFalse(text.contains("🖼"), "typeset as \(text)")
    }

    // MARK: a photograph nobody can see reserves nothing

    /// A closed `details` lays out its summary alone. Counting the pictures in
    /// its hidden body made the estimate too tall, so the document shrank under
    /// the reader the moment the block was realized.
    func testAClosedDetailsDoesNotReserveHeightForHiddenImages() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func doc(open: Bool, images: Bool) throws -> Node {
            let body = images
                ? [try s.node("image", ["src": .string("a.png")]),
                   try s.node("image", ["src": .string("b.png")])]
                : [try s.node("paragraph", [:], content: Fragment.from([s.text("x")]))]
            let details = try s.node("details", ["open": .bool(open)], content: Fragment.from([
                try s.node("detailsSummary", [:], content: Fragment.from([s.text("Photos")])),
                try s.node("detailsContent", [:], content: Fragment.from(body)),
            ]))
            // Enough above it that the details is estimated, not typeset.
            let filler = (0 ..< 80).map { i in
                try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i)")]))
            }
            return try s.node("doc", [:], content: Fragment.from(filler + [details]))
        }
        func estimatedHeight(open: Bool, images: Bool) throws -> CGFloat {
            editor.setContent(try doc(open: open, images: images))
            let layout = DocumentLayout(doc: editor.doc, width: 320, theme: DocumentTheme(),
                                        realizeWindow: 0 ... 400)
            XCTAssertTrue(layout.hasEstimatedContent, "the details is below the window")
            return layout.height
        }
        // Everything above the details is identical, so any difference is what
        // the body reserved. Closed, the pictures are not laid out and reserve
        // nothing; open, they reserve their boxes.
        let closedWithImages = try estimatedHeight(open: false, images: true)
        let closedWithout = try estimatedHeight(open: false, images: false)
        let openWithImages = try estimatedHeight(open: true, images: true)
        XCTAssertEqual(closedWithImages, closedWithout, accuracy: 1,
                       "a picture nobody can see reserves no height")
        XCTAssertGreaterThan(openWithImages, closedWithImages + 100,
                             "the same pictures, shown, do reserve their boxes")
    }

    // MARK: a composition survives someone else's edit

    /// `markedRange` is held in document positions, so an edit from anywhere
    /// else moves the text under it. Unmapped, the next keystroke of the
    /// composition replaced whatever had taken those offsets.
    func testMarkedRangeMovesWithAnEditBeforeIt() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("hello")])),
        ])))
        let view = EditorTextView(editor: editor)
        // A composition over "llo".
        view.markedRange = (3, 6)

        // A peer inserts before it.
        let tr = editor.state.tr
        try tr.insertText("XY", 1)
        editor.dispatch(tr)

        let moved = try XCTUnwrap(view.markedRange)
        XCTAssertEqual(moved.0, 5, "the composition moved by the two characters inserted before it")
        XCTAssertEqual(moved.1, 8)
        XCTAssertEqual(editor.doc.textBetween(moved.0, moved.1, blockSeparator: nil), "llo",
                       "still addressing the text being composed")
    }

    /// A composition over text a peer deletes outright has nothing left to
    /// replace, and ends.
    func testMarkedRangeEndsWhenItsTextIsDeleted() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("hello")])),
        ])))
        let view = EditorTextView(editor: editor)
        view.markedRange = (3, 6)

        let tr = editor.state.tr
        try tr.delete(1, 6)
        editor.dispatch(tr)

        XCTAssertNil(view.markedRange, "the composed text is gone")
    }
}
#endif
