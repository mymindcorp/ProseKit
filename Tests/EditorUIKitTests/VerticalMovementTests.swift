#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Tests for caret up/down movement in the CoreText layout (the bug where
/// moving between paragraphs snapped back into the inter-paragraph gap).
final class VerticalMovementTests: XCTestCase {
    private func editor(_ paragraphs: [String]) throws -> Editor {
        let editor = try Editor(extensions: starterKit())
        let paras = paragraphs.map { line in
            try! editor.schema.node("paragraph", [:], content: Fragment.from(line.isEmpty ? [] : [editor.schema.text(line)]))
        }
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from(paras)))
        return editor
    }

    private func layout(_ editor: Editor, width: CGFloat = 320) -> DocumentLayout {
        DocumentLayout(doc: editor.doc, width: width, theme: TextTheme())
    }

    func testDownMovesToNextParagraph() throws {
        let editor = try editor(["alpha", "bravo"])
        let l = layout(editor)
        let caret = try XCTUnwrap(l.caretRect(at: 3)) // inside "alpha"
        let down = try XCTUnwrap(l.verticalPosition(from: 3, up: false, preferredX: caret.midX),
                                 "down arrow should find the next line")
        XCTAssertEqual(editor.doc.resolve(down).parent.textContent, "bravo")
    }

    func testUpMovesToPreviousParagraph() throws {
        let editor = try editor(["alpha", "bravo"])
        let l = layout(editor)
        // Find a position inside "bravo".
        var bravoPos = 0
        editor.doc.descendants { node, pos, _, _ in
            if node.isText, node.text == "bravo" { bravoPos = pos + 1 }
            return true
        }
        let caret = try XCTUnwrap(l.caretRect(at: bravoPos))
        let up = try XCTUnwrap(l.verticalPosition(from: bravoPos, up: true, preferredX: caret.midX),
                               "up arrow should find the previous line")
        XCTAssertEqual(editor.doc.resolve(up).parent.textContent, "alpha")
    }

    func testNoMovementPastDocumentEdges() throws {
        let editor = try editor(["only"])
        let l = layout(editor)
        XCTAssertNil(l.verticalPosition(from: 3, up: true, preferredX: 0), "no line above the first")
        XCTAssertNil(l.verticalPosition(from: 3, up: false, preferredX: 0), "no line below the last")
    }

    func testDownWithinWrappedParagraph() throws {
        let editor = try editor([String(repeating: "word ", count: 60)])
        let l = layout(editor, width: 180) // narrow → wraps to several lines
        let caret = try XCTUnwrap(l.caretRect(at: 3))
        let down = try XCTUnwrap(l.verticalPosition(from: 3, up: false, preferredX: caret.midX),
                                 "down should move to the next wrapped line")
        XCTAssertGreaterThan(down, 3)
    }

    func testColumnIsPreserved() throws {
        let editor = try editor(["abcdefgh", "ijklmnop"])
        let l = layout(editor)
        let fromPos = 5 // middle of "abcdefgh"
        let caret = try XCTUnwrap(l.caretRect(at: fromPos))
        let down = try XCTUnwrap(l.verticalPosition(from: fromPos, up: false, preferredX: caret.midX))
        // Should land in "ijklmnop" near the same column, not at its start/end.
        let resolved = editor.doc.resolve(down)
        XCTAssertEqual(resolved.parent.textContent, "ijklmnop")
        XCTAssertGreaterThan(resolved.parentOffset, 0)
    }
}
#endif
