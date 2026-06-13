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

    func testDropMoveWithInlineAtomDoesNotCrash() throws {
        // A selection containing an inline atom: the dragged text's character
        // count differs from the document-position span, which used to push the
        // move math out of range and trap. Must be crash-safe.
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        // A wiki-link is an inline atom (images are block-level), so the selection's
        // text length ("ab") still differs from its document-position span.
        let atom = try s.node("wikiLink", ["target": .string("p"), "label": .string("L")])
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("a"), atom, s.text("b")])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()
        // The paragraph content spans positions 1...4 (a, atom, b); the text is "ab".
        view.dropText("ab", at: editor.doc.content.size, movingFrom: (1, 4))
        XCTAssertNoThrow(try editor.doc.check(), "document stays valid")
    }

    /// Build a doc: paragraph "AB", then a block image, then paragraph "CD". The
    /// image is a top-level block leaf (one position).
    private func makeViewWithImage() throws -> (EditorTextView, from: Int, to: Int) {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let img = try s.node("image", ["src": .string("asset://pic")])
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("AB")])),
            img,
            try s.node("paragraph", [:], content: Fragment.from([s.text("CD")])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.layoutIfNeeded()
        // Para "AB" occupies [0,4) (open,A,B,close); the image leaf sits at 4..5.
        return (view, 4, 5)
    }

    private func imageSrcs(_ view: EditorTextView) -> [String] {
        var srcs: [String] = []
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "image", let s = node.attrs["src"]?.stringValue { srcs.append(s) }
            return true
        }
        return srcs
    }

    func testMoveImageForwardReinsertsSameNode() throws {
        let (view, from, to) = try makeViewWithImage()
        let node = view.editor.doc.nodeAt(from)!
        XCTAssertEqual(node.type.name, "image")
        view.moveImage((node: node, from: from, to: to), to: view.editor.doc.content.size)
        XCTAssertEqual(imageSrcs(view), ["asset://pic"], "the same image node is moved, not duplicated")
        // It should now sit after "CD" rather than between "AB" and "CD".
        let lastText = view.editor.doc.textContent
        XCTAssertEqual(lastText, "ABCD", "text is undisturbed; only the image moved")
    }

    func testMoveImageOntoItselfIsNoOp() throws {
        let (view, from, to) = try makeViewWithImage()
        let node = view.editor.doc.nodeAt(from)!
        view.moveImage((node: node, from: from, to: to), to: from) // inside its own range
        XCTAssertEqual(imageSrcs(view), ["asset://pic"], "still exactly one image")
        XCTAssertNoThrow(try view.editor.doc.check())
    }

    func testImageAtFindsImageUnderPoint() throws {
        let (view, from, _) = try makeViewWithImage()
        // The block image draws on its own row; grab its drawn rect from the layout.
        guard let entry = view.ensureLayout().entries.first(where: { $0.node.type.name == "image" }),
              let rect = entry.decorations.compactMap({ d -> CGRect? in
                  if case let .stroke(r, _, _) = d { return r } // placeholder box (no image hook)
                  if case let .image(_, r) = d { return r }
                  return nil
              }).first else {
            return XCTFail("no block image rect in the layout")
        }
        let hit = view.imageAt(CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(hit?.node.type.name, "image", "a point on the block image resolves to the image node")
        XCTAssertEqual(hit?.from, from, "and to its document position")
    }

    func testDropImageInsertsAnImageNode() throws {
        let view = try makeView("ABCDEF")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { c in
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()!
        view.insertDroppedImage(png, typeIdentifier: "public.png", suggestedName: nil, at: 3)
        var foundImage = false
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "image", (node.attrs["src"]?.stringValue ?? "").hasPrefix("data:image/png") { foundImage = true }
            return true
        }
        XCTAssertTrue(foundImage, "a dropped image becomes an image node with a data: URL")
    }
}
#endif
