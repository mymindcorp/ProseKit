#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class BlockReorderTests: XCTestCase {
    private func view(_ paragraphs: [String]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let blocks = paragraphs.map { try! s.node("paragraph", [:], content: Fragment.from([s.text($0)])) }
        editor.setContent(try s.node("doc", [:], content: Fragment.from(blocks)))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        v.blockReorderingEnabled = true
        v.layoutIfNeeded()
        return v
    }

    private func texts(_ v: EditorTextView) -> [String] {
        (0..<v.editor.doc.childCount).map { v.editor.doc.child($0).textContent }
    }

    func testMoveBlockDown() throws {
        let v = try view(["A", "B", "C"])
        v.moveTopBlock(from: 0, to: 3) // move A to the end
        XCTAssertEqual(texts(v), ["B", "C", "A"])
    }

    func testMoveBlockUp() throws {
        let v = try view(["A", "B", "C"])
        v.moveTopBlock(from: 2, to: 0) // move C to the front
        XCTAssertEqual(texts(v), ["C", "A", "B"])
    }

    func testMoveIntoMiddle() throws {
        let v = try view(["A", "B", "C", "D"])
        v.moveTopBlock(from: 3, to: 1) // D before B
        XCTAssertEqual(texts(v), ["A", "D", "B", "C"])
    }

    func testAdjacentDropsAreNoOps() throws {
        let v = try view(["A", "B", "C"])
        v.moveTopBlock(from: 1, to: 1) // gap before itself
        XCTAssertEqual(texts(v), ["A", "B", "C"])
        v.moveTopBlock(from: 1, to: 2) // gap right after itself
        XCTAssertEqual(texts(v), ["A", "B", "C"])
    }

    func testHandleHitTestingOnlyWhenEnabled() throws {
        let v = try view(["First paragraph", "Second"])
        let handle = try XCTUnwrap(v.blockHandleRect(forEntryAt: 0))
        // Convert doc-space handle center to a view point (no scroll here).
        let viewPoint = CGPoint(x: handle.midX, y: handle.midY)
        XCTAssertEqual(v.blockHandleHit(at: viewPoint), 0)
        // A point in the text area (well right of the gutter) isn't a handle.
        XCTAssertNil(v.blockHandleHit(at: CGPoint(x: 150, y: handle.midY)))
        // Disabled → no hits.
        v.blockReorderingEnabled = false
        XCTAssertNil(v.blockHandleHit(at: viewPoint))
    }

    func testHandlesAllVisibleUntilPointerSeen() throws {
        let v = try view(["A", "B", "C"])
        // No pointer yet (touch): every handle shows.
        XCTAssertTrue(v.blockHandleVisibleForTesting(0))
        XCTAssertTrue(v.blockHandleVisibleForTesting(1))
        XCTAssertTrue(v.blockHandleVisibleForTesting(2))
    }

    func testDesktopHoverRevealsOnlyHoveredHandle() throws {
        let v = try view(["First", "Second", "Third"])
        let entries = v.ensureLayout().entries
        // Hover over the second block (pointer mode kicks in).
        v.updateBlockHover(at: CGPoint(x: 100, y: entries[1].topY + 2))
        XCTAssertFalse(v.blockHandleVisibleForTesting(0))
        XCTAssertTrue(v.blockHandleVisibleForTesting(1), "the hovered block's handle shows")
        XCTAssertFalse(v.blockHandleVisibleForTesting(2))
        // Move to the third.
        v.updateBlockHover(at: CGPoint(x: 100, y: entries[2].topY + 2))
        XCTAssertTrue(v.blockHandleVisibleForTesting(2))
        XCTAssertFalse(v.blockHandleVisibleForTesting(1))
    }

    func testDropIndexFromY() throws {
        let v = try view(["A", "B", "C"])
        let entries = v.ensureLayout().entries
        // Above the first block → gap 0.
        XCTAssertEqual(v.blockDropIndex(atViewY: entries[0].topY + 1), 0)
        // Past the last block → gap == count.
        XCTAssertEqual(v.blockDropIndex(atViewY: entries[2].topY + entries[2].height + 50), 3)
    }
}
#endif
