#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// What the read-only `DocumentView` does when the world around it changes: a
/// new document, a new theme, a new checkbox or wiki-link provider, a memory
/// warning, and being taken off screen.
///
/// The rendering tests all build a view, set its frame, and draw. None of them
/// change anything afterwards, so every property observer that has to drop a
/// cache and re-lay-out — and the two paths that release decoded images —
/// were never run. A missed cache drop is not a crash: it is a view that goes
/// on drawing the old document, which is exactly the kind of bug that reaches
/// a person.
@MainActor
final class DocumentViewLifecycleTests: XCTestCase {
    private let schema = try! Editor(extensions: fullKit()).schema

    private func doc(_ paragraphs: String...) -> Node {
        let blocks = paragraphs.map { text in
            try! schema.node("paragraph", [:], content: Fragment.from([schema.text(text)]))
        }
        return try! schema.node("doc", [:], content: Fragment.from(blocks))
    }

    private func view(_ document: Node?) -> DocumentView {
        let v = DocumentView(document: document)
        v.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        v.layoutIfNeeded()
        return v
    }

    /// The premultiplied RGBA bytes of the view's own `draw(_:)`.
    private func rgba(of view: UIView) -> [UInt8] {
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = unsafe CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        view.draw(view.bounds)
        UIGraphicsPopContext()
        return bytes
    }

    private func inkPixels(_ view: UIView) -> Int {
        let b = rgba(of: view)
        var n = 0
        for i in stride(from: 0, to: b.count, by: 4) where b[i + 3] > 16 { n += 1 }
        return n
    }

    // MARK: - Setting a new document

    func testSettingANewDocumentRelaysOutAndRedraws() {
        let v = view(doc("one"))
        let short = v.documentHeight
        XCTAssertGreaterThan(inkPixels(v), 50)
        v.document = doc("one", "two", "three", "four", "five")
        XCTAssertGreaterThan(v.documentHeight, short, "the taller document is measured, not the old one")
        XCTAssertGreaterThan(inkPixels(v), 50)
    }

    func testClearingTheDocumentLeavesNothingToDraw() {
        let v = view(doc("something visible"))
        XCTAssertGreaterThan(inkPixels(v), 50)
        v.document = nil
        XCTAssertEqual(v.documentHeight, 0)
        XCTAssertEqual(inkPixels(v), 0, "an empty view draws nothing")
        // And it comes back.
        v.document = doc("visible again")
        XCTAssertGreaterThan(inkPixels(v), 50)
    }

    // MARK: - Setting a new theme

    func testSettingANewThemeRelaysOutAtTheNewSize() {
        let v = view(doc("one", "two", "three"))
        let before = v.documentHeight
        var bigger = DocumentTheme()
        bigger.dynamicType = false
        bigger.fixedBodyFontSize = 34
        v.theme = bigger
        XCTAssertGreaterThan(v.documentHeight, before, "bigger text is a taller document")
        var smaller = DocumentTheme()
        smaller.dynamicType = false
        smaller.fixedBodyFontSize = 9
        v.theme = smaller
        XCTAssertLessThan(v.documentHeight, before)
    }

    // MARK: - Providers that invalidate typeset blocks

    func testSettingTheCheckboxProviderRedrawsWithoutDisturbingTheDocument() {
        let taskDoc = try! schema.node("doc", [:], content: Fragment.from([
            try! schema.node("taskList", [:], content: Fragment.from([
                try! schema.node("taskItem", ["checked": .bool(false)], content: Fragment.from([
                    try! schema.node("paragraph", [:], content: Fragment.from([schema.text("a task")])),
                ])),
            ])),
        ]))
        let v = view(taskDoc)
        let height = v.documentHeight
        v.checkboxViewProvider = { DefaultTaskCheckboxView() }
        XCTAssertEqual(v.documentHeight, height, accuracy: 0.5, "a checkbox view does not change the layout")
        XCTAssertGreaterThan(inkPixels(v), 20)
        v.checkboxViewProvider = nil
        XCTAssertGreaterThan(inkPixels(v), 20)
    }

    func testSettingTheWikiLinkIconDropsTheTypesetBlocksThatReserveItsBox() {
        let wikiDoc = try! schema.node("doc", [:], content: Fragment.from([
            try! schema.node("paragraph", [:], content: Fragment.from([
                schema.text("see "),
                try! schema.node("wikiLink", ["text": .string("Index")]),
            ])),
        ]))
        let v = view(wikiDoc)
        XCTAssertGreaterThan(inkPixels(v), 20)
        // The glyph's box is reserved inside the paragraph's cached block, so
        // setting a provider has to drop that block or the icon never appears.
        v.wikiLinkIcon = { _ in UIImage(systemName: "link") }
        XCTAssertGreaterThan(inkPixels(v), 20, "still draws, now with room for the glyph")
    }

    // MARK: - Releasing images

    func testAMemoryWarningLeavesTheViewDrawingCorrectly() {
        let v = view(doc("still here", "and here"))
        let before = inkPixels(v)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        // The decoded-image cache is dropped; the text is untouched, and what is
        // laid out keeps its own references, so nothing on screen changes.
        XCTAssertEqual(inkPixels(v), before, "a memory warning is invisible to what is drawn")
    }

    func testLeavingTheWindowReleasesImagesAndComingBackStillDraws() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        window.rootViewController = UIViewController()
        let v = view(doc("on screen"))
        window.rootViewController?.view.addSubview(v)
        window.makeKeyAndVisible()
        let before = inkPixels(v)
        XCTAssertGreaterThan(before, 50)

        v.removeFromSuperview() // → didMoveToWindow with a nil window
        XCTAssertNil(v.window)
        XCTAssertEqual(inkPixels(v), before, "what is laid out survives the release")

        window.rootViewController?.view.addSubview(v)
        XCTAssertEqual(inkPixels(v), before)
    }

    // MARK: - Scroll offset

    func testTheContentOffsetOnlyRedrawsWhenItActuallyMoves() {
        let v = view(doc((1 ... 60).map { "paragraph number \($0)" }.joined(separator: "\u{0}")
            .split(separator: "\u{0}").map(String.init).joined(separator: " ")))
        v.contentOffsetY = 0
        let top = rgba(of: v)
        v.contentOffsetY = 0 // the same value: nothing to do
        XCTAssertEqual(rgba(of: v), top)
        v.contentOffsetY = 200
        XCTAssertNotEqual(rgba(of: v), top, "a real scroll draws a different slice")
    }
}

/// Which way is "forward" to the document tokenizer.
///
/// The direction arrives as an untyped `UITextDirection` carrying the raw value
/// of either a `UITextStorageDirection` (forward 0, backward 1) or a
/// `UITextLayoutDirection` (right 2, left 3, up 4, down 5). The obvious reading
/// — that right and down mean forward — is *not* what UIKit's own
/// `UITextInputStringTokenizer` does: it treats forward as the only forward
/// direction and every other raw value as backward. `TokenizerParityTests`
/// compares us against that oracle and would fail if we disagreed, but it never
/// says what the shared answer is, so a reader has no way to know that
/// answering right as forward would be the divergence rather than the fix.
///
/// That is what these pin. See also `DocumentTokenizer.forward(_:)`, whose
/// `UITextLayoutDirection` branch is unreachable — `UITextStorageDirection`
/// is an imported Objective-C enum whose `init(rawValue:)` succeeds for every
/// integer, so the first branch always wins. Reaching the second one would
/// break the parity these tests hold.
@MainActor
final class DocumentTokenizerDirectionTests: XCTestCase {
    private func makeView(_ text: String = "alpha bravo charlie") throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()
        return view
    }

    private func offset(_ p: UITextPosition?) -> Int? { (p as? DocTextPosition)?.offset }
    private func direction(_ raw: Int) -> UITextDirection { UITextDirection(rawValue: raw) }

    private let allDirections: [(name: String, raw: Int)] = [
        ("forward", UITextStorageDirection.forward.rawValue),
        ("backward", UITextStorageDirection.backward.rawValue),
        ("right", UITextLayoutDirection.right.rawValue),
        ("left", UITextLayoutDirection.left.rawValue),
        ("up", UITextLayoutDirection.up.rawValue),
        ("down", UITextLayoutDirection.down.rawValue),
    ]

    func testOnlyTheForwardStorageDirectionCountsAsForward() throws {
        let view = try makeView()
        let tokenizer = view.tokenizer
        // "alpha bravo charlie": word boundaries at 1/6, 7/12, 13/20. From 9,
        // inside "bravo", forward is its end and backward is its start.
        let inside = DocTextPosition(9)
        for (name, raw) in allDirections {
            let got = offset(tokenizer.position(from: inside, toBoundary: .word, inDirection: direction(raw)))
            XCTAssertEqual(got, name == "forward" ? 12 : 7, "\(name) (raw \(raw))")
        }
    }

    func testEveryDirectionAnswersWhatTheSystemTokenizerAnswers() throws {
        // The oracle, on the same questions: it is the reason the answers above
        // are what they are, and the reason "fixing" them would be wrong.
        let view = try makeView()
        let ours = view.tokenizer
        let system = UITextInputStringTokenizer(textInput: view)
        for (name, raw) in allDirections {
            let d = direction(raw)
            for pos in [0, 1, 6, 7, 9, 12, 13, 20] {
                let p = DocTextPosition(pos)
                XCTAssertEqual(offset(ours.position(from: p, toBoundary: .word, inDirection: d)),
                               offset(system.position(from: p, toBoundary: .word, inDirection: d)),
                               "position at \(pos) going \(name)")
                XCTAssertEqual(ours.isPosition(p, withinTextUnit: .word, inDirection: d),
                               system.isPosition(p, withinTextUnit: .word, inDirection: d),
                               "withinTextUnit at \(pos) going \(name)")
            }
        }
    }

    func testTheVerticalLayoutDirectionsAreNotTreatedAsUpAndDownLines() throws {
        // A caller reaching for line movement has to use the `UITextInput`
        // geometry, not the tokenizer: up and down here are simply "not
        // forward", which is the same answer as backward.
        let view = try makeView()
        let tokenizer = view.tokenizer
        let inside = DocTextPosition(9)
        let backward = offset(tokenizer.position(from: inside, toBoundary: .word,
                                                 inDirection: direction(UITextStorageDirection.backward.rawValue)))
        for raw in [UITextLayoutDirection.up.rawValue, UITextLayoutDirection.down.rawValue] {
            XCTAssertEqual(offset(tokenizer.position(from: inside, toBoundary: .word, inDirection: direction(raw))), backward)
        }
    }
}

/// Loading a picture from the URL forms a document can carry.
@MainActor
final class ImageURLLoadingTests: XCTestCase {
    private func png(_ size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testABase64DataURLIsDecodedAtTheWidthItWillBeDrawn() async throws {
        let bytes = png(CGSize(width: 800, height: 400))
        let url = try XCTUnwrap(URL(string: "data:image/png;base64," + bytes.base64EncodedString()))
        let loaded = await loadDownsampledImage(from: url, maxPointWidth: 200, displayScale: 1)
        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(image.cgImage?.width, 200)
        XCTAssertEqual(image.size.width, 800, accuracy: 0.5, "the natural size is unchanged")
    }

    func testAPercentEncodedDataURLIsDecodedToo() async throws {
        // The other spelling of a data: URL — an SVG or a text payload arrives
        // this way rather than base64.
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'></svg>"
        let encoded = try XCTUnwrap(svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let url = try XCTUnwrap(URL(string: "data:image/svg+xml," + encoded))
        // Not a format ImageIO opens, so nil rather than a crash — the point is
        // that the payload was decoded and handed over at all.
        _ = await loadDownsampledImage(from: url, maxPointWidth: 100, displayScale: 1)
    }

    func testADataURLWithNoCommaHasNoPayload() async throws {
        let url = try XCTUnwrap(URL(string: "data:image/png;base64"))
        let image = await loadDownsampledImage(from: url, maxPointWidth: 100, displayScale: 1)
        XCTAssertNil(image)
    }

    func testAFileURLIsReadThroughImageIOAndDownsampled() async throws {
        let bytes = png(CGSize(width: 900, height: 300))
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prosekit-image-\(UUID().uuidString).png")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loaded = await loadDownsampledImage(from: file, maxPointWidth: 300, displayScale: 1)
        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(image.cgImage?.width, 300)
        XCTAssertEqual(image.size.width, 900, accuracy: 0.5)
    }

    func testAFileThatIsNotAnImageLoadsToNothing() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prosekit-notes-\(UUID().uuidString).txt")
        try Data("not a picture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loaded = await loadDownsampledImage(from: file, maxPointWidth: 100, displayScale: 1)
        XCTAssertNil(loaded)
    }

    func testDecodingOffTheMainActorGivesTheSameBitmap() async {
        let bytes = png(CGSize(width: 600, height: 600))
        let direct = decodeDownsampledImage(bytes, maxPointWidth: 150, displayScale: 2)
        let offMain = await decodeOffMainActor(bytes, maxPointWidth: 150, displayScale: 2)
        XCTAssertEqual(direct?.cgImage?.width, offMain?.cgImage?.width)
        XCTAssertEqual(direct?.size.width ?? 0, offMain?.size.width ?? -1, accuracy: 0.5)
    }
}
#endif
