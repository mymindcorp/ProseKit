#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class PointerCursorTests: XCTestCase {
    private func makeView() throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func cell(_ text: String) -> Node {
            try! s.node("tableCell", [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
            ]))
        }
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("plain text paragraph")])),
            try s.node("taskList", [:], content: Fragment.from([
                try s.node("taskItem", ["checked": .bool(false)], content: Fragment.from([
                    try s.node("paragraph", [:], content: Fragment.from([s.text("a task")])),
                ])),
            ])),
            try s.node("table", [:], content: Fragment.from([
                try s.node("tableRow", [:], content: Fragment.from([cell("A"), cell("B")])),
            ])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        view.layoutIfNeeded()
        return view
    }

    func testPointerTargets() throws {
        let view = try makeView()
        let l = view.ensureLayout()

        // Over plain text → text (I-beam).
        let firstBlock = l.blocks[0]
        XCTAssertEqual(view.pointerTarget(at: CGPoint(x: firstBlock.frame.midX, y: firstBlock.frame.midY)), .text)

        // Checkboxes are their own subviews now (each with its own pointer
        // hover), so the editor's pointer target over a checkbox is just text.
        view.syncCheckboxViews()
        XCTAssertTrue(view.subviews.contains { $0 is DefaultTaskCheckboxView }, "checkbox subview exists")

        // Over the table's internal column border → columnBorder.
        let table = l.tables[0]
        let borderPoint = CGPoint(x: table.borderX(after: 0), y: (table.top + table.bottom) / 2)
        guard case .columnBorder(let borderRect) = view.pointerTarget(at: borderPoint) else {
            return XCTFail("expected column-border target")
        }
        XCTAssertTrue(borderRect.contains(borderPoint))

        // The pointer interaction is installed.
        XCTAssertTrue(view.interactions.contains { $0 is UIPointerInteraction })
    }
}
#endif
