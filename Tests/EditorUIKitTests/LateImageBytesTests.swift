#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// Images whose bytes arrive *after* the first layout.
///
/// The renderer resolves images while laying out, so a host that doesn't have
/// the bytes yet gets a placeholder — the size of which is baked into the
/// layout. Nothing about that is wrong until the bytes turn up: the document
/// hasn't changed, so the usual "relayout when the document changes" trigger
/// never fires and the placeholder is what stays on screen.
@MainActor
final class LateImageBytesTests: XCTestCase {
    private func png(_ side: CGFloat, _ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()!
    }

    /// A view showing a single block image, laid out once with no bytes
    /// available. Nodes are built from the editor's own schema — node types are
    /// compared by identity, so a document from a *different* editor's schema
    /// would be rejected and leave an empty paragraph behind.
    private func viewAwaitingBytes(src: String = "asset://photo") throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("image", ["src": .string(src), "alt": .string("pic")]),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        view.layoutIfNeeded()
        _ = view.ensureLayout() // bake in the placeholder
        return view
    }

    /// The drawn rect of the first block-level image (or its placeholder box).
    private func imageRect(_ view: EditorTextView) -> CGRect? {
        view.ensureLayout().imageRects.first?.rect
    }

    // MARK: - Host bytes arriving late

    func testHostBytesArrivingAfterLayoutAreAdopted() throws {
        let view = try viewAwaitingBytes()
        let placeholder = try XCTUnwrap(imageRect(view))
        let placeholderHeight = view.ensureLayout().height

        // The host now has the bytes — a 200pt square, far taller than the
        // 120pt placeholder.
        let bytes = png(200, .red)
        view.imageData = { $0.type.name == "image" ? bytes : nil }
        view.reloadImages()

        let resolved = try XCTUnwrap(imageRect(view))
        XCTAssertGreaterThan(resolved.height, placeholder.height,
                             "the image should lay out at its own size, not the placeholder's")
        XCTAssertGreaterThan(view.ensureLayout().height, placeholderHeight,
                             "and the document should grow to fit it")
    }

    func testTheHeightChangeIsReportedToTheHost() throws {
        // The host sizes its scroll view from this callback; without it the
        // image draws into space the scroll view doesn't know exists.
        let view = try viewAwaitingBytes()
        var reported: [CGFloat] = []
        view.onDocumentHeightChange = { reported.append($0) }

        let bytes = png(200, .red)
        view.imageData = { $0.type.name == "image" ? bytes : nil }
        view.reloadImages()
        _ = view.ensureLayout()

        XCTAssertEqual(reported.count, 1, "exactly one height report")
        XCTAssertEqual(reported.last, view.ensureLayout().height)
    }

    func testInlineImageBytesArrivingLateAreAdopted() throws {
        // An inline image is typeset into its paragraph's cached block, so it
        // takes more than dropping the document layout to pick up.
        let editor = try Editor(extensions: starterKit() + [ImageExtension(inline: true)])
        let s = editor.schema
        let img = try s.node("image", ["src": .string("asset://inline")])
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("before "), img, s.text(" after"),
            ])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        view.layoutIfNeeded()
        let placeholderHeight = view.ensureLayout().height

        let bytes = png(120, .red)
        view.imageData = { $0.type.name == "image" ? bytes : nil }
        view.reloadImages()

        XCTAssertGreaterThan(view.ensureLayout().height, placeholderHeight,
                             "the line should grow to fit the inline image")
    }

    func testReloadingImagesReAsksTheHostForBytesItAlreadyGave() throws {
        // The host swapped the asset — same node, different bytes.
        let view = try viewAwaitingBytes()
        var current = png(60, .red)
        var asks = 0
        view.imageData = { node in
            guard node.type.name == "image" else { return nil }
            asks += 1
            return current
        }
        view.reloadImages()
        let small = try XCTUnwrap(imageRect(view))
        let asksAfterFirst = asks

        current = png(200, .red)
        view.reloadImages()
        let large = try XCTUnwrap(imageRect(view))

        XCTAssertGreaterThan(asks, asksAfterFirst, "the hook is consulted again")
        XCTAssertGreaterThan(large.height, small.height, "and the new bytes are used")
    }

    func testReloadingWithoutBytesKeepsThePlaceholder() throws {
        let view = try viewAwaitingBytes()
        let before = try XCTUnwrap(imageRect(view))
        view.reloadImages()
        XCTAssertEqual(try XCTUnwrap(imageRect(view)), before, "nothing to adopt, nothing changes")
    }

    // MARK: - URL-loaded images

    func testImagesLoadedFromTheirSrcAppear() throws {
        // The renderer's own async loader has the same problem: it finishes
        // after layout, and the document hasn't changed.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("late-\(UUID().uuidString).png")
        try png(200, .red).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let view = try viewAwaitingBytes(src: url.path)
        let placeholderHeight = view.ensureLayout().height

        // Pump the run loop until the async load lands.
        let deadline = Date().addingTimeInterval(10)
        while view.ensureLayout().height <= placeholderHeight, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(view.ensureLayout().height, placeholderHeight,
                             "the loaded image never reached the layout")
    }

    // MARK: - The read-only renderer

    func testDocumentViewAdoptsLateHostBytes() throws {
        let s = try Editor(extensions: fullKit()).schema
        let doc = try s.node("doc", [:], content: Fragment.from([
            try s.node("image", ["src": .string("asset://photo")]),
        ]))
        let view = DocumentView(document: doc)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        view.layoutIfNeeded()
        let placeholderHeight = try XCTUnwrap(view.ensureLayout()).height

        let bytes = png(200, .red)
        view.imageData = { $0.type.name == "image" ? bytes : nil }
        view.reloadImages()

        XCTAssertGreaterThan(try XCTUnwrap(view.ensureLayout()).height, placeholderHeight)
    }
}
#endif
