#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Tapping the empty space under a document that doesn't end in a paragraph.
/// Without it, a document ending in a code block is a trap on touch: every exit
/// binding needs a modifier key, and the tap that should escape resolves back
/// into the block, because a caret can only live in a textblock.
@MainActor
final class TrailingTapTests: XCTestCase {
    private func view(lastBlock: (Schema) throws -> Node) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("Intro")])),
            try lastBlock(s),
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        v.layoutIfNeeded()
        return v
    }
    private func codeBlock(_ s: Schema) throws -> Node {
        try s.node("codeBlock", [:], content: Fragment.from([s.text("let x = 1")]))
    }
    private func belowEverything(_ v: EditorTextView) -> CGPoint {
        CGPoint(x: 160, y: v.ensureLayout().height + 40)
    }

    func testTapBelowACodeBlockAppendsAParagraphAndPutsTheCaretInIt() throws {
        let v = try view(lastBlock: codeBlock)
        XCTAssertTrue(v.trailingGapTap(at: belowEverything(v)))
        XCTAssertTrue(v.appendTrailingParagraph())
        let doc = v.editor.doc
        XCTAssertEqual(doc.childCount, 3)
        let last = doc.child(2)
        XCTAssertEqual(last.type.name, "paragraph")
        XCTAssertEqual(last.content.size, 0, "an empty paragraph, ready to type in")
        // The caret is inside it, not back in the code block.
        let head = doc.resolve(v.editor.state.selection.head)
        XCTAssertEqual(head.parent.type.name, "paragraph")
    }

    func testTapBelowAParagraphChangesNothing() throws {
        let v = try view { s in
            try s.node("paragraph", [:], content: Fragment.from([s.text("Last")]))
        }
        XCTAssertFalse(v.trailingGapTap(at: belowEverything(v)),
                       "the caret it already offers is the one the tap wanted")
    }

    func testTapInsideTheContentIsNotClaimed() throws {
        let v = try view(lastBlock: codeBlock)
        let block = try XCTUnwrap(v.ensureLayout().blocks.last)
        XCTAssertFalse(v.trailingGapTap(at: CGPoint(x: 40, y: block.frame.midY)),
                       "a tap on the block itself still places a caret normally")
    }

    func testAReadOnlyViewNeverAppends() throws {
        let v = try view(lastBlock: codeBlock)
        v.isEditable = false
        XCTAssertFalse(v.trailingGapTap(at: belowEverything(v)))
        XCTAssertFalse(v.appendTrailingParagraph())
        XCTAssertEqual(v.editor.doc.childCount, 2)
    }

    func testTablesAndImagesGetTheSameEscape() throws {
        for name in ["table", "image"] {
            let v = try view { s in
                switch name {
                case "table":
                    let cell = try s.node("tableCell", [:], content: Fragment.from([
                        try s.node("paragraph", [:], content: Fragment.from([s.text("A")])),
                    ]))
                    return try s.node("table", [:], content: Fragment.from([
                        try s.node("tableRow", [:], content: Fragment.from([cell])),
                    ]))
                default:
                    return try s.node("image", ["src": .string("x.png")])
                }
            }
            XCTAssertTrue(v.trailingGapTap(at: belowEverything(v)), "\(name) traps the caret too")
        }
    }
}
#endif
