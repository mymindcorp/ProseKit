#if canImport(UIKit)
import XCTest
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// Vertical caret movement (↑/↓) must land on the adjacent block in flow, never
/// skipping a short block whose width doesn't reach the caret column.
@MainActor
final class VerticalCaretTests: XCTestCase {
    private func listLayout() throws -> (DocumentLayout, [TextBlock]) {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func li(_ text: String) -> Node {
            try! s.node("listItem", [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
            ]))
        }
        // A wide item, a short item, a wide item.
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("bulletList", [:], content: Fragment.from([
                li("the first list item is quite wide indeed"),
                li("B"),
                li("the third list item is also quite wide"),
            ])),
        ])))
        let layout = DocumentLayout(doc: editor.doc, width: 400, theme: TextTheme())
        return (layout, layout.blocks)
    }

    func testDownArrowDoesNotSkipAShortListItem() throws {
        let (layout, blocks) = try listLayout()
        XCTAssertGreaterThanOrEqual(blocks.count, 3)
        let firstItem = blocks[0], shortItem = blocks[1]
        // Caret near the end of the wide first item → a large preferred column.
        let startPos = firstItem.contentEnd
        let preferredX = firstItem.frame.maxX
        let down = try XCTUnwrap(layout.verticalPosition(from: startPos, up: false, preferredX: preferredX))
        XCTAssertTrue(down >= shortItem.contentStart && down <= shortItem.contentEnd,
                      "↓ lands in the short item (\(shortItem.contentStart)...\(shortItem.contentEnd)), got \(down)")
    }

    func testUpArrowDoesNotSkipAShortListItem() throws {
        let (layout, blocks) = try listLayout()
        let thirdItem = blocks[2], shortItem = blocks[1]
        let startPos = thirdItem.contentEnd
        let preferredX = thirdItem.frame.maxX
        let up = try XCTUnwrap(layout.verticalPosition(from: startPos, up: true, preferredX: preferredX))
        XCTAssertTrue(up >= shortItem.contentStart && up <= shortItem.contentEnd,
                      "↑ lands in the short item, got \(up)")
    }
}
#endif
