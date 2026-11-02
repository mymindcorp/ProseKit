#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class LayoutInputRegressionTests: XCTestCase {
    func view(_ build: (Schema) throws -> [Node]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(try build(editor.schema))))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        v.layoutIfNeeded()
        return v
    }
    nonisolated func para(_ s: Schema, _ t: String) throws -> Node { try s.node("paragraph", [:], content: Fragment.from([s.text(t)])) }
    func caret(_ v: EditorTextView, _ p: Int) { v.editor.dispatch(v.editor.state.tr.setSelection(TextSelection.create(v.editor.doc, p))) }

    func testRightToLeftNeedsAStrongLetterFirst() throws {
        for text in ["Привет שלום", "你好 שלום", "\u{FEFF}Hello", "123 Ελληνικά مرحبا"] {
            let v = try view { [try self.para($0, text)] }
            let l = v.ensureLayout()
            let x = l.blocks[0].lines[0].baselineOrigin.x
            XCTAssertEqual(x, l.theme.pageInsets.left, accuracy: 0.5, "\(text) aligned right")
        }
    }
    func testBlankLineCaretFollowsAlignment() throws {
        let v = try view { s in
            let para = try s.node("paragraph", [:], content: Fragment.from([s.text("abc"), try s.node("hardBreak")]))
            return [try s.node("table", [:], content: Fragment.from([
                try s.node("tableRow", [:], content: Fragment.from([try s.node("tableCell", ["align": .string("right")], content: Fragment.from([para]))]))]))]
        }
        let l = v.ensureLayout()
        let b = l.blocks[0]
        let end = try XCTUnwrap(l.caretRect(at: b.contentEnd))
        XCTAssertGreaterThan(end.minX, b.frame.maxX - 5, "blank line of right-aligned cell draws caret at left")
    }
    func testCRLFIsOneLineEnding() throws {
        let v = try view { s in [try s.node("codeBlock", [:], content: Fragment.from([s.text("a\r\nb")]))] }
        let l = v.ensureLayout()
        let b = l.blocks[0]
        XCTAssertEqual(b.lines.count, 2, "CRLF gives a phantom line")
    }
    func testCodeLabelReachesCachedListItems() throws {
        let v = try view { s in
            let code = try s.node("codeBlock", [:], content: Fragment.from([s.text("let x")]))
            let item = try s.node("listItem", [:], content: Fragment.from([try self.para(s, "i"), code]))
            return [try s.node("bulletList", [:], content: Fragment.from([item])), try s.node("codeBlock", [:], content: Fragment.from([s.text("y")]))]
        }
        _ = v.ensureLayout()
        v.codeLanguageLabel = { _, _ in "SWIFT" }
        let l = v.ensureLayout()
        var labels = 0
        for d in l.decorations { if case let .text(t, _, _) = d, t == "SWIFT" { labels += 1 } }
        XCTAssertEqual(labels, 2, "list-item code block keeps pre-hook decorations")
    }
    func testMarkedSelectedRangeCountsGraphemes() throws {
        let v = try view { [try $0.node("paragraph")] }
        v.setMarkedText("😀ab", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(v.editor.state.selection.head, 2, "after the emoji is contentStart(1)+1")
    }
    func testDownArrowStepsPastLaidOutBlocks() throws {
        let v = try view { s in try (0..<400).map { try self.para(s, "para \($0)") } }
        caret(v, 1)
        var head = 1, seen: [Int] = []
        for _ in 0..<200 {
            _ = v.handle(EditorTextView.KeyEvent(.keyboardDownArrow, modifiers: [], characters: ""))
            let h = v.editor.state.selection.head
            seen.append(h - head)
            if h - head > 100 { XCTFail("jump"); break }
            head = h
        }
    }
    func testPastedAndDroppedCRLFBecomeOneNewline() throws {
        let v = try view { [try $0.node("codeBlock")] }
        caret(v, 1)
        let pb = UIPasteboard.withUniqueName()
        pb.string = "c\r\nd"
        v.pasteAndMatchStyle(from: pb)
        XCTAssertFalse(v.editor.doc.textContent.contains("\r"))
        v.dropText("e\r\nf", at: 1, movingFrom: nil)
        XCTAssertFalse(v.editor.doc.textContent.contains("\r"))
    }
}
#endif
