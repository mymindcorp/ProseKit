#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class CodeBlockLayoutTests: XCTestCase {
    private func view(code: String) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let block = try s.node("codeBlock", [:], content: Fragment.from([s.text(code)]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([block])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        v.layoutIfNeeded()
        return v
    }

    private func codeBlockLineCount(_ v: EditorTextView) -> Int {
        // The code block is the only text block here.
        v.ensureLayout().blocks.first?.lines.count ?? 0
    }

    func testNewlinesCreateSeparateLines() throws {
        let oneLine = try view(code: "let x = 1")
        XCTAssertEqual(codeBlockLineCount(oneLine), 1)

        let threeLines = try view(code: "let x = 1\nlet y = 2\nlet z = 3")
        XCTAssertEqual(codeBlockLineCount(threeLines), 3, "each \\n starts a new visual line")
    }

    func testBlankLinesArePreserved() throws {
        let v = try view(code: "a\n\nb")
        XCTAssertEqual(codeBlockLineCount(v), 3, "the empty middle line counts")
    }

    func testReturnInCodeBlockInsertsNewlineNotNewBlock() throws {
        let v = try view(code: "ab")
        // Caret between a and b (content starts at 1).
        v.editor.dispatch(v.editor.state.tr.setSelection(TextSelection.create(v.editor.doc, 2)))
        // Drive Return through the key handler.
        _ = v.handle(EditorTextView.KeyEvent(.keyboardReturnOrEnter))
        // Still a single code block, now containing a newline.
        var codeBlocks = 0
        v.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "codeBlock" { codeBlocks += 1 }
            return true
        }
        XCTAssertEqual(codeBlocks, 1, "Return stays inside the code block (no split)")
        XCTAssertTrue(v.editor.doc.textContent.contains("\n"), "a newline was inserted")
        XCTAssertEqual(codeBlockLineCount(v), 2, "and it renders as two lines")
    }

    func testUpArrowMovesThroughCodeBlockLinesNoStick() throws {
        let v = try view(code: "alpha\nbeta\ngamma")
        let l = v.ensureLayout()
        XCTAssertEqual(l.blocks.first?.lines.count, 3)
        // Start at the end (on the "gamma" line), walk up line by line.
        let endPos = v.editor.doc.content.size - 1
        var pos = endPos
        let bigX: CGFloat = 1000 // a column to the right, exercises clamping
        let up1 = try XCTUnwrap(l.verticalPosition(from: pos, up: true, preferredX: bigX))
        XCTAssertNotEqual(up1, pos, "up moves off the last line")
        XCTAssertLessThan(up1, pos, "and earlier in the document")
        pos = up1
        let up2 = try XCTUnwrap(l.verticalPosition(from: pos, up: true, preferredX: bigX))
        XCTAssertLessThan(up2, up1, "up keeps moving (not stuck)")
        // Each step landed on a distinct earlier line.
        XCTAssertNotEqual(up2, up1)
    }

    func testCaretLandsOnTheNewLineAfterReturn() throws {
        let v = try view(code: "ab")
        v.editor.dispatch(v.editor.state.tr.setSelection(TextSelection.create(v.editor.doc, v.editor.doc.content.size - 1)))
        _ = v.handle(EditorTextView.KeyEvent(.keyboardReturnOrEnter))
        let l = v.ensureLayout()
        XCTAssertEqual(l.blocks.first?.lines.count, 2, "a trailing empty line exists for the caret")
        let firstLine = try XCTUnwrap(l.blocks.first?.lines.first)
        let caret = try XCTUnwrap(l.caretRect(at: v.editor.state.selection.head))
        XCTAssertGreaterThan(caret.minY, firstLine.baselineOrigin.y - firstLine.ascent + 1,
                             "caret sits on the new line, not the end of the first")
    }
}
#endif
