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

    /// Pump the main run loop until `condition` holds (or the deadline passes).
    /// A fixed sleep races async work on slow CI runners; polling waits exactly
    /// as long as needed.
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func waitForRedPixels(of view: UIView) -> Int {
        var n = 0
        pump(until: { n = redPixels(of: view); return n > 100 })
        return n
    }

    private func redPixels(of view: UIView) -> Int {
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = unsafe CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
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
        view.imageURLResolver = { node in node.attrs["src"]?.stringValue == "asset://x" ? fileURL : nil }
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

        pump(until: { imageSrc(view) == "asset://notes" })
        XCTAssertEqual(imageSrc(view), "asset://notes", "item-provider image went through onImageDrop")
        XCTAssertEqual(receivedUTI, UTType.png.identifier, "the original image UTI is preserved")
    }

    private func imageWidth(_ view: EditorTextView) -> Int? {
        var w: Int?
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "image" { w = node.attrs["width"]?.intValue }
            return true
        }
        return w
    }

    /// Build an editable view with a single block image (loaded via imageData).
    private func imageEditorView(width: Int? = nil) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        var attrs: Attrs = ["src": .string("asset://photo")]
        if let width { attrs["width"] = .int(width) }
        editor.setContent(try s.node("doc", [:], content: Fragment.from([try s.node("image", attrs)])))
        let view = EditorTextView(editor: editor)
        view.imageData = { _ in self.redPNG() } // 24×24
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        view.layoutIfNeeded()
        return view
    }

    func testImageRendersAtWidthAttr() throws {
        let view = try imageEditorView(width: 120)
        let rects = view.ensureLayout().imageRects
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects.first?.rect.width ?? 0, 120, accuracy: 0.5, "the width attr drives the drawn width")
        // Aspect ratio preserved (24×24 source → square).
        XCTAssertEqual(rects.first?.rect.height ?? 0, 120, accuracy: 0.5)
    }

    func testSetImageWidthClampsAndUpdatesAttr() throws {
        let view = try imageEditorView()
        let pos = 0 // the image is the document's first child
        view.setImageWidth(pos, to: 150)
        XCTAssertEqual(imageWidth(view), 150, "a normal resize sets the width attr")
        view.setImageWidth(pos, to: 5)
        XCTAssertEqual(imageWidth(view), 40, "below the minimum, width clamps to 40")
        let maxW = Int(view.ensureLayout().contentWidth.rounded())
        view.setImageWidth(pos, to: 99_999)
        XCTAssertEqual(imageWidth(view), maxW, "above the content width, width clamps to it")
    }

    func testResizeHandleRevealsOnHover() throws {
        let view = try imageEditorView(width: 120)
        let pos = 0
        let rect = view.ensureLayout().imageRects.first!.rect
        // Touch (no pointer yet): every image shows its handle.
        XCTAssertTrue(view.imageHandleVisibleForTesting(pos))
        // Pointer hovering the image → handle stays revealed.
        view.updateImageHover(at: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertTrue(view.imageHandleVisibleForTesting(pos), "hovered image reveals its handle")
        // Pointer away from any image → handle hides on desktop.
        view.updateImageHover(at: CGPoint(x: rect.midX, y: rect.maxY + 200))
        XCTAssertFalse(view.imageHandleVisibleForTesting(pos), "non-hovered image hides its handle")
    }

    func testImageWidthRoundTripsThroughHTML() throws {
        let s = try Editor(extensions: fullKit()).schema
        let img = try s.node("image", ["src": .string("a.png"), "width": .int(180)])
        let doc = try s.node("doc", [:], content: Fragment.from([img]))
        let html = HTMLSerializer.serialize(doc)
        XCTAssertTrue(html.contains("width=\"180\""), "serialized HTML carries the width")
        let back = try HTMLParser.parse(html, schema: s)
        XCTAssertEqual(imageWidthOf(back), 180, "width survives a round-trip")
    }

    private func imageWidthOf(_ doc: Node) -> Int? {
        var w: Int?
        doc.descendants { node, _, _, _ in
            if node.type.name == "image" { w = node.attrs["width"]?.intValue }
            return true
        }
        return w
    }

    func testDocumentViewLoadsImageFromSrc() throws {
        // No imageData hook: the read-only view must load the image from its src
        // (here a data: URL) via the async path, then redraw with it.
        let s = try Editor(extensions: fullKit()).schema
        let dataURL = "data:image/png;base64," + redPNG().base64EncodedString()
        let doc = try s.node("doc", [:], content: Fragment.from([try s.node("image", ["src": .string(dataURL)])]))
        let view = DocumentView(document: doc)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        _ = view.documentHeight // triggers ensureLayout → loadPendingImages
        XCTAssertGreaterThan(waitForRedPixels(of: view), 100, "DocumentView loaded the image from its src")
    }

    func testDocumentViewHonorsImageURLResolver() throws {
        // The read-only view resolves a custom src to a file it then loads.
        let s = try Editor(extensions: fullKit()).schema
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dv-\(UUID().uuidString).png")
        try redPNG().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let doc = try s.node("doc", [:], content: Fragment.from([try s.node("image", ["src": .string("asset://pic")])]))
        let view = DocumentView(document: doc)
        view.imageURLResolver = { node in node.attrs["src"]?.stringValue == "asset://pic" ? tmp : nil }
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        _ = view.documentHeight
        XCTAssertGreaterThan(waitForRedPixels(of: view), 100, "DocumentView resolved + loaded the custom src")
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
