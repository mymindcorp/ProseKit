#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorSerialization
@testable import EditorUIKit

/// Rendering helpers: the read-only `DocumentView` (visible-window only) and the
/// collaboration-cursor rendering.
@MainActor
final class DocumentViewTests: XCTestCase {
    private func schema() -> Schema { try! Editor(extensions: fullKit()).schema }

    private func tallDoc(_ schema: Schema, _ n: Int) -> Node {
        let paras = (0 ..< n).map { i in
            try! schema.node("paragraph", [:], content: Fragment.from([schema.text("Paragraph number \(i) — lorem ipsum dolor sit amet")]))
        }
        return try! schema.node("doc", [:], content: Fragment.from(paras))
    }

    /// Render a view's `draw(_:)` into a bitmap and return its premultiplied RGBA bytes.
    private func rgba(of view: UIView) -> (bytes: [UInt8], width: Int, height: Int) {
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = unsafe CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        view.draw(view.bounds)
        UIGraphicsPopContext()
        return (bytes, w, h)
    }

    private func inkPixels(_ b: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: b.count, by: 4) where b[i + 3] > 16 { n += 1 } // any non-transparent pixel
        return n
    }

    func testDocumentViewReportsFullHeightButRendersAViewportSlice() {
        let s = schema()
        let view = DocumentView(document: tallDoc(s, 120))
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        view.layoutIfNeeded()
        // The document is far taller than the 200pt viewport...
        XCTAssertGreaterThan(view.documentHeight, 1500)
        // ...yet a 200pt-tall render is non-blank (it draws the visible slice).
        let top = rgba(of: view)
        XCTAssertGreaterThan(inkPixels(top.bytes), 100, "visible text should be drawn")
    }

    func testDocumentViewRendersDifferentSlicesAtDifferentOffsets() {
        let s = schema()
        let view = DocumentView(document: tallDoc(s, 120))
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        view.layoutIfNeeded()

        view.contentOffsetY = 0
        let topImage = rgba(of: view).bytes
        view.contentOffsetY = view.documentHeight - 200 // scroll to the bottom
        let bottomImage = rgba(of: view).bytes

        XCTAssertGreaterThan(inkPixels(topImage), 100)
        XCTAssertGreaterThan(inkPixels(bottomImage), 100)
        XCTAssertNotEqual(topImage, bottomImage, "different scroll offsets render different content")
    }

    func testDocumentViewFromJSONStringRenders() throws {
        let s = schema()
        let json = try s.node("doc", [:], content: Fragment.from([
            try s.node("heading", ["level": .int(1)], content: Fragment.from([s.text("Title")])),
            try s.node("paragraph", [:], content: Fragment.from([s.text("Loaded from JSON")])),
        ])).toJSONString(pretty: true)
        let view = try DocumentView(json: json, schema: s)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        view.layoutIfNeeded()
        XCTAssertGreaterThan(view.documentHeight, 0)
        XCTAssertGreaterThan(inkPixels(rgba(of: view).bytes), 100, "the JSON document renders")
    }

    func testRenderIntoArbitraryContext() {
        let s = schema()
        let view = DocumentView(document: tallDoc(s, 30))
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        view.layoutIfNeeded()
        // Render into a caller-owned bitmap context via the public helper.
        let w = 300, h = 150
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = unsafe CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        view.render(into: ctx, height: CGFloat(h), offsetY: 0)
        UIGraphicsPopContext()
        XCTAssertGreaterThan(inkPixels(bytes), 100, "the helper renders into the provided context")
    }

    // MARK: - Collaboration cursor rendering

    /// Count pixels close to the agent's orange (#FF9500).
    private func orangePixels(_ b: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: b.count, by: 4) {
            let r = b[i], g = b[i + 1], bl = b[i + 2], a = b[i + 3]
            if a > 200, r > 210, g > 120, g < 190, bl < 70 { n += 1 }
        }
        return n
    }

    private func makeEditorView() -> EditorTextView {
        let editor = try! Editor(extensions: fullKit())
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([
            try! editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text("hello world")])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        view.layoutIfNeeded()
        return view
    }

    func testCollabCursorIsRendered() {
        let view = makeEditorView()
        XCTAssertEqual(orangePixels(rgba(of: view).bytes), 0, "no cursor yet → no orange")
        view.editor.setCollabCursor(id: "agent", anchor: 4, head: 4, color: "#FF9500", label: "Agent")
        view.setNeedsDisplay()
        XCTAssertGreaterThan(orangePixels(rgba(of: view).bytes), 30, "the orange remote caret + name flag should draw")
    }

    func testCollabCursorRemovedStopsRendering() {
        let view = makeEditorView()
        view.editor.setCollabCursor(id: "agent", anchor: 4, head: 4, color: "#FF9500", label: "Agent")
        XCTAssertGreaterThan(orangePixels(rgba(of: view).bytes), 30)
        view.editor.removeCollabCursor(id: "agent")
        view.setNeedsDisplay()
        XCTAssertEqual(orangePixels(rgba(of: view).bytes), 0, "removing the cursor stops drawing it")
    }
}
#endif
