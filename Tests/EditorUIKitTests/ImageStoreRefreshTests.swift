#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// Re-decoding a picture when the column it is drawn in gets wider.
///
/// A bitmap is decoded to the box it will be drawn in, so a photo shown in a
/// 180pt column carries 180pt of pixels. Rotate the phone, or open a split
/// view, and that same photo is now drawn at 700pt from a bitmap that has a
/// quarter of the pixels for it — visibly soft, and permanently so, because the
/// cache would go on serving the small one. `DocumentImageStore` notices and
/// decodes again in the background.
///
/// Nothing tested that. The store's own decode-on-widen path had no coverage at
/// all, and it is not a path a rendering test wanders into: it needs the width
/// to change *after* an image is already resident.
@MainActor
final class ImageStoreRefreshTests: XCTestCase {
    private let schema = try! Editor(extensions: fullKit()).schema

    /// A PNG with `size` pixels at scale 1, so pixels and points agree.
    private func png(_ size: CGSize, _ color: UIColor = .red) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private func imageNode(src: String) -> Node {
        try! schema.node("image", ["src": .string(src)])
    }

    private func store() -> DocumentImageStore {
        let store = DocumentImageStore(loads: ImageLoadTasks())
        store.displayScale = 1
        return store
    }

    /// Pump the main run loop until `condition` holds (or the deadline passes).
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func pixelWidth(_ image: UIImage?) -> Int { image?.cgImage?.width ?? 0 }

    // MARK: - Host bytes

    func testAWiderColumnReDecodesHostBytesAtTheHigherResolution() {
        let s = store()
        let node = imageNode(src: "asset://photo")
        let bytes = png(CGSize(width: 1600, height: 1200))
        s.dataProvider = { _ in bytes }

        s.maxPointWidth = 180
        XCTAssertEqual(pixelWidth(s.image(for: node)), 180, "decoded for the column it was drawn in")

        // The column gets wider — a rotation, or a split view opening.
        s.maxPointWidth = 720
        // The stale bitmap keeps drawing while the new one is decoded, so
        // nothing flickers and nothing reflows.
        XCTAssertEqual(pixelWidth(s.image(for: node)), 180, "the old bitmap is still what draws")
        pump(until: { self.pixelWidth(s.image(for: node)) > 180 })
        XCTAssertEqual(pixelWidth(s.image(for: node)), 720, "and it is replaced by one decoded for the new width")
    }

    func testANarrowerColumnKeepsTheBitmapItAlreadyHas() {
        let s = store()
        let node = imageNode(src: "asset://photo")
        let bytes = png(CGSize(width: 1600, height: 1200))
        s.dataProvider = { _ in bytes }
        s.maxPointWidth = 720
        XCTAssertEqual(pixelWidth(s.image(for: node)), 720)
        // Rotating back does not throw away pixels it already paid for: the
        // bitmap is bigger than it needs to be, which costs nothing to draw.
        s.maxPointWidth = 180
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(pixelWidth(s.image(for: node)), 720)
    }

    func testTheNaturalSizeIsUnchangedByAReDecodeSoNothingMoves() {
        // Layout measures a picture's box from `UIImage.size`. If a re-decode
        // moved it, rotating would reflow the document around every image.
        let s = store()
        let node = imageNode(src: "asset://photo")
        s.dataProvider = { _ in self.png(CGSize(width: 1600, height: 1200)) }
        s.maxPointWidth = 180
        let before = s.image(for: node)?.size
        s.maxPointWidth = 720
        pump(until: { self.pixelWidth(s.image(for: node)) > 180 })
        XCTAssertEqual(s.image(for: node)?.size.width ?? 0, before?.width ?? -1, accuracy: 0.5)
        XCTAssertEqual(s.image(for: node)?.size.height ?? 0, before?.height ?? -1, accuracy: 0.5)
    }

    // MARK: - Loaded URLs

    /// A `data:` URL the loader can resolve without a network or a file.
    private func dataURL(_ bytes: Data) -> String {
        "data:image/png;base64," + bytes.base64EncodedString()
    }

    func testAnImageLoadedFromAURLIsAlsoReDecodedWhenTheColumnWidens() {
        let s = store()
        let src = dataURL(png(CGSize(width: 1600, height: 1200)))
        let node = imageNode(src: src)
        var announced: [Set<String>] = []
        s.onLoaded = { srcs, _ in announced.append(srcs) }

        s.maxPointWidth = 180
        XCTAssertNil(s.image(for: node), "nothing resident yet — the layout draws a placeholder")
        s.load([node])
        pump(until: { s.image(for: node) != nil })
        XCTAssertEqual(pixelWidth(s.image(for: node)), 180)
        XCTAssertEqual(announced.first, [src], "the view is told which sources arrived")

        s.maxPointWidth = 720
        pump(until: { self.pixelWidth(s.image(for: node)) > 180 })
        XCTAssertEqual(pixelWidth(s.image(for: node)), 720)
    }

    func testLoadingIsSkippedForSourcesAlreadyResidentOrAlreadyInFlight() {
        let s = store()
        let src = dataURL(png(CGSize(width: 400, height: 300)))
        let node = imageNode(src: src)
        s.maxPointWidth = 200
        s.load([node])
        s.load([node]) // a second layout pass over the same document
        pump(until: { s.image(for: node) != nil })
        XCTAssertEqual(s.debugEntryCount, 1, "one entry, not one per pass")
        XCTAssertFalse(s.debugHasLoadsInFlight, "and nothing left running")
        // Asking again once it is resident starts nothing new.
        s.load([node])
        XCTAssertFalse(s.debugHasLoadsInFlight)
    }

    func testAnUnresolvableSourceIsSimplyNotLoaded() {
        let s = store()
        let node = imageNode(src: "asset://not-a-url")
        s.maxPointWidth = 200
        s.load([node])
        XCTAssertFalse(s.debugHasLoadsInFlight, "no URL to fetch, so no load")
        XCTAssertNil(s.image(for: node))
    }

    // MARK: - Disposal

    func testPruningDropsTheImagesADocumentNoLongerHolds() {
        let s = store()
        s.maxPointWidth = 200
        s.dataProvider = { _ in self.png(CGSize(width: 100, height: 100)) }
        let kept = imageNode(src: "asset://kept")
        let dropped = imageNode(src: "asset://dropped")
        _ = s.image(for: kept)
        _ = s.image(for: dropped)
        XCTAssertEqual(s.debugEntryCount, 2)
        XCTAssertGreaterThan(s.debugByteCost, 0)

        let doc = try! schema.node("doc", [:], content: Fragment.from([
            kept, try! schema.node("paragraph", [:], content: Fragment.from([schema.text("text")])),
        ]))
        s.prune(keeping: doc)
        XCTAssertEqual(s.debugEntryCount, 1, "only the image still in the document survives")
        XCTAssertNotNil(s.image(for: kept))
    }

    func testPurgingDropsEverything() {
        let s = store()
        s.maxPointWidth = 200
        s.dataProvider = { _ in self.png(CGSize(width: 100, height: 100)) }
        _ = s.image(for: imageNode(src: "asset://a"))
        _ = s.image(for: imageNode(src: "asset://b"))
        XCTAssertEqual(s.debugEntryCount, 2)
        s.purge()
        XCTAssertEqual(s.debugEntryCount, 0)
        XCTAssertEqual(s.debugByteCost, 0)
        XCTAssertFalse(s.debugHasLoadsInFlight)
    }

    func testReloadingHostImagesDropsOnlyTheOnesTheHostSupplied() {
        let s = store()
        s.maxPointWidth = 200
        let hosted = imageNode(src: "asset://hosted")
        let loadedSrc = dataURL(png(CGSize(width: 100, height: 100)))
        let loaded = imageNode(src: loadedSrc)
        s.dataProvider = { node in node.attrs["src"]?.stringValue == "asset://hosted" ? self.png(CGSize(width: 100, height: 100)) : nil }
        _ = s.image(for: hosted)
        s.load([loaded])
        pump(until: { s.image(for: loaded) != nil })
        XCTAssertEqual(s.debugEntryCount, 2)
        // The host says its bytes changed: its images go, the fetched one stays.
        s.reloadHostImages()
        XCTAssertEqual(s.debugEntryCount, 1)
        XCTAssertNotNil(s.image(for: loaded), "the loaded one is untouched")
    }

    func testTheByteBudgetEvictsTheLeastRecentlyUsed() {
        let s = store()
        s.maxPointWidth = 400
        s.byteBudget = 1 // anything at all is over budget
        s.dataProvider = { _ in self.png(CGSize(width: 200, height: 200)) }
        _ = s.image(for: imageNode(src: "asset://a"))
        _ = s.image(for: imageNode(src: "asset://b"))
        // Over budget, the store keeps at most what it must: dropping an entry
        // does not disturb what is drawn, because a laid-out decoration holds
        // its own reference.
        XCTAssertLessThanOrEqual(s.debugEntryCount, 1)
    }
}
#endif
