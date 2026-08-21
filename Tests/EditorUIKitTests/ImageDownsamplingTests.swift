#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// Images are decoded to the size they are *drawn* at, not the size they were
/// saved at.
///
/// A note holding phone photographs used to hand `draw(in:)` the full-resolution
/// bitmap, so every frame of a scroll resampled twelve million pixels per
/// picture on the main thread. The fix is to downsample once — but a picture's
/// box is measured from `UIImage.size`, so the reduction has to be invisible to
/// layout. That is the invariant most of this file is about.
@MainActor
final class ImageDownsamplingTests: XCTestCase {
    /// A PNG of an exact pixel size (scale 1, so pixels and points agree).
    private func png(_ size: CGSize, _ color: UIColor = .red) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    // MARK: - The decode

    func testTheBitmapShrinksToTheBoxItIsDrawnIn() throws {
        // 2000×1000 into a 300pt column on a 2× screen: 600×300 pixels is all
        // that can be shown, and all that should be decoded.
        let image = try XCTUnwrap(decodeDownsampledImage(png(CGSize(width: 2000, height: 1000)),
                                                         maxPointWidth: 300, displayScale: 2))
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, 600)
        XCTAssertEqual(cg.height, 300)
    }

    func testTheNaturalSizeSurvivesTheDownsample() throws {
        // Layout measures the picture's box from `size`. If downsampling moved
        // it, every image in the document would silently change size.
        let image = try XCTUnwrap(decodeDownsampledImage(png(CGSize(width: 2000, height: 1000)),
                                                         maxPointWidth: 300, displayScale: 2))
        XCTAssertEqual(image.size.width, 2000, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 1000, accuracy: 0.5)
    }

    func testAnImageSmallerThanItsBoxIsNotUpsampled() throws {
        // Past the source's own resolution there is nothing to gain and a
        // full-size copy to pay for.
        let image = try XCTUnwrap(decodeDownsampledImage(png(CGSize(width: 50, height: 50)),
                                                         maxPointWidth: 300, displayScale: 3))
        XCTAssertEqual(try XCTUnwrap(image.cgImage).width, 50)
        XCTAssertEqual(image.size.width, 50, accuracy: 0.5)
    }

    func testATallImageKeepsEnoughPixelsForItsHeight() throws {
        // The thumbnail bound is on the *longer* side. A portrait photo fitted
        // to the column is taller than it is wide, so bounding by the width
        // would leave it half-resolution.
        let image = try XCTUnwrap(decodeDownsampledImage(png(CGSize(width: 1000, height: 3000)),
                                                         maxPointWidth: 300, displayScale: 2))
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, 600, "300pt wide at 2×")
        XCTAssertEqual(cg.height, 1800, "and three times as tall")
    }

    func testDataThatIsNotAnImageDecodesToNil() {
        // The fallback path: nonsense in, nil out — never a crash.
        XCTAssertNil(decodeDownsampledImage(Data("not an image".utf8), maxPointWidth: 300, displayScale: 2))
    }

    /// A JPEG carrying an EXIF orientation tag, as every phone camera writes.
    private func rotatedJPEG(_ size: CGSize, orientation: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testAnEXIFRotatedPhotoKeepsTheSizeItIsShownAt() throws {
        // Orientation 6 is a quarter turn: 100×200 of pixels is a 200×100
        // picture. The size layout uses has to be the *displayed* one — which is
        // what `UIImage(data:)` would have reported before any of this.
        let data = try rotatedJPEG(CGSize(width: 100, height: 200), orientation: 6)
        let plain = try XCTUnwrap(UIImage(data: data))
        let downsampled = try XCTUnwrap(decodeDownsampledImage(data, maxPointWidth: 1000, displayScale: 1))

        XCTAssertEqual(plain.size.width, 200, accuracy: 0.5, "the fixture isn't rotated")
        XCTAssertEqual(downsampled.size.width, plain.size.width, accuracy: 0.5)
        XCTAssertEqual(downsampled.size.height, plain.size.height, accuracy: 0.5)
    }

    func testARotatedPhotoIsStillBoundedByItsDisplayedShape() throws {
        // Bounding on the stored (un-rotated) dimensions would cut the wrong
        // side, leaving the picture short of pixels along its long edge.
        let data = try rotatedJPEG(CGSize(width: 1000, height: 2000), orientation: 6)
        let image = try XCTUnwrap(decodeDownsampledImage(data, maxPointWidth: 100, displayScale: 2))
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, 200, "100pt wide at 2×")
        XCTAssertEqual(cg.height, 100, "and half as tall, the way it is shown")
    }

    // MARK: - Layout is unaffected

    func testLayoutSizesTheImageFromTheOriginalNotTheBitmap() throws {
        // The picture fills the content column and keeps its 2:1 shape — which
        // is what it did before anything was downsampled.
        let s = try Editor(extensions: fullKit()).schema
        let doc = try s.node("doc", [:], content: Fragment.from([
            try s.node("image", ["src": .string("asset://wide")]),
        ]))
        let view = DocumentView(document: doc)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        view.layoutIfNeeded()
        let bytes = png(CGSize(width: 2000, height: 1000))
        view.imageData = { $0.type.name == "image" ? bytes : nil }
        view.reloadImages()

        let layout = try XCTUnwrap(view.ensureLayout())
        let rect = try XCTUnwrap(layout.imageRects.first?.rect)
        XCTAssertEqual(rect.width / rect.height, 2, accuracy: 0.01, "the original's aspect ratio")
        XCTAssertGreaterThan(rect.width, 200, "and it fills the column")
    }
}

/// The store's side of it: what stays resident, and what is let go of.
@MainActor
final class DocumentImageStoreTests: XCTestCase {
    private func png(_ side: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()!
    }

    private func store(_ bytes: @escaping (Node) -> Data?) -> DocumentImageStore {
        let store = DocumentImageStore(loads: ImageLoadTasks())
        store.maxPointWidth = 300
        store.displayScale = 2
        store.dataProvider = bytes
        return store
    }

    private func image(_ schema: Schema, _ src: String) throws -> Node {
        try schema.node("image", ["src": .string(src)])
    }

    func testHostBytesAreDecodedOnceAndKept() throws {
        let schema = try Editor(extensions: fullKit()).schema
        let node = try image(schema, "asset://one")
        var asks = 0
        let store = store { _ in asks += 1; return self.png(200) }

        XCTAssertNotNil(store.image(for: node))
        XCTAssertNotNil(store.image(for: node))
        XCTAssertEqual(asks, 1, "the second look-up is served from the cache")
        XCTAssertEqual(store.debugEntryCount, 1)
    }

    func testPruningDropsImagesTheDocumentNoLongerHolds() throws {
        // A picture deleted from the note is a bitmap nobody will look at again.
        let schema = try Editor(extensions: fullKit()).schema
        let kept = try image(schema, "asset://kept")
        let removed = try image(schema, "asset://removed")
        let store = store { _ in self.png(200) }
        _ = store.image(for: kept)
        _ = store.image(for: removed)
        XCTAssertEqual(store.debugEntryCount, 2)

        let doc = try schema.node("doc", [:], content: Fragment.from([kept]))
        store.prune(keeping: doc)

        XCTAssertEqual(store.debugEntryCount, 1, "only the one still in the document survives")
    }

    func testPruningKeepsAnImageNestedInsideABlock() throws {
        // The walk has to reach an inline image inside a paragraph, not just the
        // document's own children.
        let editor = try Editor(extensions: starterKit() + [ImageExtension(inline: true)])
        let schema = editor.schema
        let inline = try image(schema, "asset://inline")
        let store = store { _ in self.png(120) }
        _ = store.image(for: inline)

        let doc = try schema.node("doc", [:], content: Fragment.from([
            try schema.node("paragraph", [:], content: Fragment.from([schema.text("a "), inline])),
        ]))
        store.prune(keeping: doc)
        XCTAssertEqual(store.debugEntryCount, 1)
    }

    func testTheCacheStaysUnderItsByteBudget() throws {
        let schema = try Editor(extensions: fullKit()).schema
        let store = store { _ in self.png(200) }
        _ = store.image(for: try image(schema, "asset://0"))
        // Room for that one bitmap and no more.
        let one = store.debugByteCost
        XCTAssertGreaterThan(one, 0)
        store.byteBudget = one

        for i in 1..<5 { _ = store.image(for: try image(schema, "asset://\(i)")) }

        XCTAssertLessThanOrEqual(store.debugByteCost, one, "the least recently drawn are let go")
        XCTAssertEqual(store.debugEntryCount, 1)
    }

    func testPurgingReleasesEverything() throws {
        let schema = try Editor(extensions: fullKit()).schema
        let store = store { _ in self.png(200) }
        _ = store.image(for: try image(schema, "asset://one"))
        store.purge()
        XCTAssertEqual(store.debugEntryCount, 0)
        XCTAssertEqual(store.debugByteCost, 0)
    }

    func testReloadingHostImagesDropsTheirDecodes() throws {
        let schema = try Editor(extensions: fullKit()).schema
        let node = try image(schema, "asset://one")
        var asks = 0
        let store = store { _ in asks += 1; return self.png(200) }
        _ = store.image(for: node)
        store.reloadHostImages()
        _ = store.image(for: node)
        XCTAssertEqual(asks, 2, "the host is asked again for bytes that may have changed")
    }

    // MARK: - Loads in flight

    /// A load that runs until it is cancelled, and says so.
    private final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func finish() { lock.lock(); done = true; lock.unlock() }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }

    private func waitFor(_ flag: Ran) async {
        for _ in 0..<500 where !flag.isDone {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testCancellingStopsALoadInFlight() async {
        // A download for a note the reader has already closed is work nobody
        // is waiting for, and on a slow connection it outlives the view.
        let loads = ImageLoadTasks()
        let ran = Ran()
        loads.start("asset://slow") {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            ran.finish()
        }
        XCTAssertTrue(loads.contains("asset://slow"))
        loads.cancelAll()
        await waitFor(ran)
        XCTAssertTrue(ran.isDone, "the load never noticed it had been cancelled")
        XCTAssertTrue(loads.isEmpty)
    }

    func testCancellingIsSelective() async {
        let loads = ImageLoadTasks()
        let ran = Ran()
        loads.start("gone") {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            ran.finish()
        }
        loads.start("kept") {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        loads.cancel { $0 != "kept" }
        await waitFor(ran)
        XCTAssertTrue(ran.isDone)
        XCTAssertTrue(loads.contains("kept"), "an image still in the document keeps loading")
        loads.cancelAll()
    }
}

/// Adopting an image that has just loaded touches only the blocks that show it.
///
/// The bytes arriving is the one change that alters the layout without altering
/// the document, so it used to be handled by throwing the layout away and
/// building it again — a whole-document re-flow per picture, arriving while the
/// reader is scrolling through them.
@MainActor
final class LoadedImageRelayoutTests: XCTestCase {
    private func png(_ side: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()!
    }

    /// A paragraph, a block image, a paragraph.
    private func document(_ schema: Schema, src: String) throws -> Node {
        try schema.node("doc", [:], content: Fragment.from([
            try schema.node("paragraph", [:], content: Fragment.from([schema.text("above")])),
            try schema.node("image", ["src": .string(src)]),
            try schema.node("paragraph", [:], content: Fragment.from([schema.text("below")])),
        ]))
    }

    func testOnlyTheBlocksShowingTheImageAreRelaid() throws {
        let schema = try Editor(extensions: fullKit()).schema
        let doc = try document(schema, src: "asset://late")
        var loaded: UIImage?
        let layout = DocumentLayout(doc: doc, width: 320, theme: DocumentTheme(),
                                    imageProvider: { _ in loaded })

        let above = try XCTUnwrap(layout.blocks.first).frame
        let below = try XCTUnwrap(layout.blocks.last).frame
        let placeholderHeight = layout.height

        // 200pt square, well past the 120pt placeholder box.
        loaded = UIImage(data: png(200))
        XCTAssertTrue(layout.relayoutImages(matching: { $0.attrs["src"]?.stringValue == "asset://late" }))

        XCTAssertEqual(try XCTUnwrap(layout.blocks.first).frame, above,
                       "the paragraph above the picture never moved")
        XCTAssertGreaterThan(try XCTUnwrap(layout.blocks.last).frame.minY, below.minY,
                             "the one below it was pushed down")
        XCTAssertGreaterThan(layout.height, placeholderHeight)
    }

    func testAnImageNobodyIsWaitingForChangesNothing() throws {
        let schema = try Editor(extensions: fullKit()).schema
        let layout = DocumentLayout(doc: try document(schema, src: "asset://late"), width: 320,
                                    theme: DocumentTheme(), imageProvider: { _ in nil })
        XCTAssertFalse(layout.relayoutImages(matching: { $0.attrs["src"]?.stringValue == "asset://other" }))
    }

    func testTheLayoutIsPatchedRatherThanRebuilt() throws {
        // A file-backed image, loaded by the renderer's own async path.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-\(UUID().uuidString).png")
        try png(200).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let editor = try Editor(extensions: fullKit())
        editor.setContent(try document(editor.schema, src: url.path))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        view.layoutIfNeeded()
        let before = view.ensureLayout()
        let placeholderHeight = before.height

        let deadline = Date().addingTimeInterval(10)
        while view.ensureLayout().height <= placeholderHeight, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertGreaterThan(view.ensureLayout().height, placeholderHeight, "the image never landed")
        XCTAssertTrue(view.ensureLayout() === before,
                      "adopting it should patch the layout in place, not build a new one")
    }

    // MARK: - The predicate the block cache evicts on

    func testAnInlineImageIsFoundInsideItsParagraph() throws {
        let editor = try Editor(extensions: starterKit() + [ImageExtension(inline: true)])
        let schema = editor.schema
        let paragraph = try schema.node("paragraph", [:], content: Fragment.from([
            schema.text("before "), try schema.node("image", ["src": .string("asset://in")]),
        ]))
        XCTAssertTrue(DocumentLayout.containsImage(paragraph) { $0.attrs["src"]?.stringValue == "asset://in" })
        XCTAssertFalse(DocumentLayout.containsImage(paragraph) { $0.attrs["src"]?.stringValue == "asset://out" })
    }

    func testABlockImageIsItsOwnMatch() throws {
        let schema = try Editor(extensions: fullKit()).schema
        let image = try schema.node("image", ["src": .string("asset://block")])
        XCTAssertTrue(DocumentLayout.containsImage(image) { $0.attrs["src"]?.stringValue == "asset://block" })
    }

    func testAParagraphWithNoImageIsLeftAlone() throws {
        let schema = try Editor(extensions: fullKit()).schema
        let paragraph = try schema.node("paragraph", [:], content: Fragment.from([schema.text("plain")]))
        XCTAssertFalse(DocumentLayout.containsImage(paragraph) { _ in true })
    }
}
#endif
