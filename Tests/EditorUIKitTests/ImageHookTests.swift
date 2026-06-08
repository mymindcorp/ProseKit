#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// The configurable hook that supplies image bytes for a node, falling back to a
/// placeholder when it returns nil.
@MainActor
final class ImageHookTests: XCTestCase {
    private func redPNG() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }.pngData()!
    }

    private func docWithImage() -> (Schema, Node) {
        let s = try! Editor(extensions: fullKit()).schema
        let image = try! s.node("image", ["src": .string("asset://photo"), "alt": .string("pic")])
        let para = try! s.node("paragraph", [:], content: Fragment.from([image]))
        return (s, try! s.node("doc", [:], content: Fragment.from([para])))
    }

    private func redPixels(of view: UIView) -> Int {
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        view.draw(view.bounds)
        UIGraphicsPopContext()
        var n = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i] > 200 && bytes[i + 1] < 70 && bytes[i + 2] < 70 && bytes[i + 3] > 200 { n += 1 }
        return n
    }

    func testHookSuppliesImageData() {
        let (_, doc) = docWithImage()
        let png = redPNG()
        let view = DocumentView(document: doc)
        view.imageData = { node in node.type.name == "image" ? png : nil }
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        view.invalidateLayout()
        XCTAssertGreaterThan(redPixels(of: view), 100, "the host-provided image should be drawn")
    }

    func testPlaceholderWhenNoHook() {
        let (_, doc) = docWithImage()
        let view = DocumentView(document: doc) // no imageData hook → "asset://" can't load
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        view.invalidateLayout()
        XCTAssertEqual(redPixels(of: view), 0, "with no hook (and no loadable src) a placeholder is drawn, not an image")
    }

    func testEditorTextViewHonorsTheHook() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema // build the doc against the editor's own schema
        let image = try s.node("image", ["src": .string("asset://photo"), "alt": .string("pic")])
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([image])),
        ])))
        let png = redPNG()
        let view = EditorTextView(editor: editor)
        view.imageData = { node in node.type.name == "image" ? png : nil }
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        view.layoutIfNeeded()
        XCTAssertGreaterThan(redPixels(of: view), 100, "EditorTextView draws the host-provided image")
    }
}
#endif
