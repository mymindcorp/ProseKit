#if canImport(UIKit)
import XCTest
import UIKit
import UniformTypeIdentifiers
import DocumentModel
import SchemaKit
import EditorSerialization
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
        // Images are block-level: the image is a top-level child of the document.
        let image = try! s.node("image", ["src": .string("asset://photo"), "alt": .string("pic")])
        return (s, try! s.node("doc", [:], content: Fragment.from([image])))
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

    private func emptyEditorView() throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([try s.node("paragraph", [:], content: .empty)])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        view.layoutIfNeeded()
        return view
    }

    private func imageSrc(_ view: EditorTextView) -> String? {
        var src: String?
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "image" { src = node.attrs["src"]?.stringValue }
            return true
        }
        return src
    }

    func testOnImageDropUsesHostAttributes() throws {
        let view = try emptyEditorView()
        view.onImageDrop = { img in
            ["src": .string("asset://saved"), "alt": .string("\(img.typeIdentifier ?? "?")/\(img.suggestedName ?? "?")")]
        }
        view.insertDroppedImage(redPNG(), typeIdentifier: "public.png", suggestedName: "pic.png", at: 1)
        XCTAssertEqual(imageSrc(view), "asset://saved", "the host's chosen src is used")
        var alt: String?
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "image" { alt = node.attrs["alt"]?.stringValue }
            return true
        }
        XCTAssertEqual(alt, "public.png/pic.png", "the dropped image's UTI + name reach the handler")
    }

    func testImageDropFallsBackToDataURL() throws {
        let view = try emptyEditorView()
        view.insertDroppedImage(redPNG(), typeIdentifier: "public.png", suggestedName: nil, at: 1)
        XCTAssertEqual(imageSrc(view)?.hasPrefix("data:image/png;base64,"), true,
                       "no handler → bytes embedded as a data: URL")
    }

    func testImageURLResolverResolvesCustomSrc() throws {
        let editor = try Editor(extensions: fullKit())
        let view = EditorTextView(editor: editor)
        let fileURL = URL(fileURLWithPath: "/tmp/assets/x.png")
        view.imageURLResolver = { src in src == "asset://x" ? fileURL : nil }
        XCTAssertEqual(view.imageURLForTesting("asset://x"), fileURL, "resolver maps a custom src")
        // Built-in handling still applies when the resolver returns nil.
        XCTAssertEqual(view.imageURLForTesting("https://example.com/a.png")?.scheme, "https")
        XCTAssertNil(view.imageURLForTesting("relative/unknown.png"))
    }

    func testItemProviderImageRoutesThroughHook() throws {
        // Mirrors how Apple Notes (and Finder/Photos) vend a dragged image: an
        // item provider with an image data representation, not a UIImage object.
        let view = try emptyEditorView()
        let png = redPNG()
        var receivedUTI: String?
        view.onImageDrop = { img in receivedUTI = img.typeIdentifier; return ["src": .string("asset://notes")] }

        let provider = NSItemProvider()
        provider.suggestedName = "from-notes"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
        view.loadDroppedImage(from: provider, at: 1)

        let done = expectation(description: "image inserted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(imageSrc(view), "asset://notes", "item-provider image went through onImageDrop")
        XCTAssertEqual(receivedUTI, UTType.png.identifier, "the original image UTI is preserved")
    }

    func testHTMLImageInParagraphLiftsToBlock() throws {
        // Pasted/clipboard HTML often nests <img> inside a paragraph; with a
        // block-image schema the parser lifts it out into a sibling block so the
        // document stays valid (a textblock can't hold a block image).
        let s = try Editor(extensions: fullKit()).schema
        let doc = try HTMLParser.parse("<p>before<img src=\"a.png\" alt=\"x\">after</p>", schema: s)
        var kinds: [String] = []
        for i in 0..<doc.childCount { kinds.append(doc.child(i).type.name) }
        XCTAssertEqual(kinds, ["paragraph", "image", "paragraph"], "the image splits the paragraph")
        XCTAssertNoThrow(try doc.check(), "the lifted document is valid")
    }

    func testEditorTextViewHonorsTheHook() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema // build the doc against the editor's own schema
        let image = try s.node("image", ["src": .string("asset://photo"), "alt": .string("pic")])
        editor.setContent(try s.node("doc", [:], content: Fragment.from([image])))
        let png = redPNG()
        let view = EditorTextView(editor: editor)
        view.imageData = { node in node.type.name == "image" ? png : nil }
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        view.layoutIfNeeded()
        XCTAssertGreaterThan(redPixels(of: view), 100, "EditorTextView draws the host-provided image")
    }
}
#endif
