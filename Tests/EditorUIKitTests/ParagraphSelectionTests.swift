#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class ParagraphSelectionTests: XCTestCase {
    private func view(_ paragraphs: [String]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let blocks = paragraphs.map { try! s.node("paragraph", [:], content: Fragment.from([s.text($0)])) }
        editor.setContent(try s.node("doc", [:], content: Fragment.from(blocks)))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        v.layoutIfNeeded()
        return v
    }

    func testParagraphRangeIsTheWholeBlock() throws {
        let v = try view(["hello there", "second paragraph"])
        let block = v.ensureLayout().blocks[1]
        let point = CGPoint(x: block.frame.midX, y: block.frame.midY)
        let range = try XCTUnwrap(v.paragraphRange(at: point))
        XCTAssertEqual(range.from, block.contentStart)
        XCTAssertEqual(range.to, block.contentEnd)
        XCTAssertEqual(v.editor.doc.textBetween(range.from, range.to), "second paragraph")
    }

    func testParagraphRangeForFirstBlock() throws {
        let v = try view(["hello there", "second paragraph"])
        let block = v.ensureLayout().blocks[0]
        let range = try XCTUnwrap(v.paragraphRange(at: CGPoint(x: block.frame.midX, y: block.frame.midY)))
        XCTAssertEqual(v.editor.doc.textBetween(range.from, range.to), "hello there")
    }
}
#endif
