#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// The drop logic (text move / insert, image insert). The drag/drop *gestures*
/// are touch-driven; this exercises the document transforms they invoke.
@MainActor
final class DragDropTests: XCTestCase {
    private func makeView(_ text: String) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([
            try! editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text(text)])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()
        return view
    }

    func testDropInsertsText() throws {
        let view = try makeView("ABCDEF")
        view.dropText("XY", at: 3, movingFrom: nil) // before "C"
        XCTAssertEqual(view.editor.doc.textContent, "ABXYCDEF")
    }

    func testDropMovesTextForward() throws {
        let view = try makeView("ABCDEF")
        view.dropText("AB", at: 7, movingFrom: (1, 3)) // move "AB" to the end
        XCTAssertEqual(view.editor.doc.textContent, "CDEFAB")
    }

    func testDropMovesTextBackward() throws {
        let view = try makeView("ABCDEF")
        view.dropText("EF", at: 1, movingFrom: (5, 7)) // move "EF" to the start
        XCTAssertEqual(view.editor.doc.textContent, "EFABCD")
    }

    func testDropOntoItselfIsNoOp() throws {
        let view = try makeView("ABCDEF")
        view.dropText("CD", at: 4, movingFrom: (3, 5)) // dropped inside the source range
        XCTAssertEqual(view.editor.doc.textContent, "ABCDEF")
    }

    func testDropImageInsertsAnImageNode() throws {
        let view = try makeView("ABCDEF")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { c in
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()!
        view.dropImage(png, at: 3)
        var foundImage = false
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "image", (node.attrs["src"]?.stringValue ?? "").hasPrefix("data:image/png") { foundImage = true }
            return true
        }
        XCTAssertTrue(foundImage, "a dropped image becomes an image node with a data: URL")
    }
}
#endif
