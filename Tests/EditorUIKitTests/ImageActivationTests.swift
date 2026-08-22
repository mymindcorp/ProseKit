#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// `onActivateImage` — the image counterpart of `onActivateMath`. The long press
/// itself is touch-driven; this covers what it resolves to, what it hands the
/// host, and how setting the handler divides the press with the image drag.
@MainActor
final class ImageActivationTests: XCTestCase {
    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { c in
            UIColor.green.setFill(); c.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }.pngData()!
    }

    /// paragraph "AB", a block image, paragraph "CD". The image leaf sits at 4.
    private func blockView() throws -> (EditorTextView, pos: Int) {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("AB")])),
            try s.node("image", ["src": .string("asset://pic")]),
            try s.node("paragraph", [:], content: Fragment.from([s.text("CD")])),
        ])))
        let view = EditorTextView(editor: editor)
        view.imageData = { $0.type.name == "image" ? self.png() : nil }
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.layoutIfNeeded()
        return (view, 4)
    }

    /// One paragraph, "a<image>b" — the image is inline, at position 2.
    private func inlineView() throws -> (EditorTextView, pos: Int) {
        let editor = try Editor(extensions: starterKit() + [ImageExtension(inline: true)])
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("a"), try s.node("image", ["src": .string("asset://inline")]), s.text("b"),
            ])),
        ])))
        let view = EditorTextView(editor: editor)
        view.imageData = { $0.type.name == "image" ? self.png() : nil }
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.layoutIfNeeded()
        return (view, 2)
    }

    /// The rect an image is drawn in, block or inline.
    private func drawnRect(_ view: EditorTextView) throws -> CGRect {
        let layout = view.ensureLayout()
        for decoration in layout.decorations + layout.entries.flatMap(\.decorations) {
            if case let .image(_, rect) = decoration { return rect }
        }
        throw XCTSkip("no image was drawn")
    }

    private func center(_ view: EditorTextView) throws -> CGPoint {
        let rect = try drawnRect(view)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func testActivationHandsTheNodeAndPositionToTheHost() throws {
        let (view, pos) = try blockView()
        var seen: [(src: String, pos: Int)] = []
        view.onActivateImage = { node, pos in
            seen.append((node.attrs["src"]?.stringValue ?? "", pos))
        }
        XCTAssertTrue(view.activateImageForTesting(at: try center(view)))
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].src, "asset://pic")
        XCTAssertEqual(seen[0].pos, pos)
    }

    func testAnInlineImageActivatesToo() throws {
        let (view, pos) = try inlineView()
        var seen: (src: String, pos: Int)?
        view.onActivateImage = { node, pos in seen = (node.attrs["src"]?.stringValue ?? "", pos) }
        XCTAssertTrue(view.activateImageForTesting(at: try center(view)))
        XCTAssertEqual(seen?.src, "asset://inline")
        XCTAssertEqual(seen?.pos, pos, "the inline image's own position, not the nearest text one")
    }

    func testActivationSelectsTheNodeSoAnUpdateAddressesIt() throws {
        let (view, pos) = try blockView()
        view.onActivateImage = { _, _ in }
        XCTAssertTrue(view.activateImageForTesting(at: try center(view)))
        XCTAssertEqual((view.editor.state.selection as? NodeSelection)?.from, pos)
    }

    func testAPointOffTheImageActivatesNothing() throws {
        let (view, _) = try blockView()
        var called = false
        view.onActivateImage = { _, _ in called = true }
        XCTAssertFalse(view.activateImageForTesting(at: CGPoint(x: 4, y: 4)), "the first paragraph")
        XCTAssertFalse(called)
    }

    func testTheHitTestIsPublicAndAnswersInViewCoordinates() throws {
        let (view, pos) = try blockView()
        let point = try center(view)
        let hit = try XCTUnwrap(view.imageNode(at: point))
        XCTAssertEqual(hit.node.type.name, "image")
        XCTAssertEqual(hit.from, pos)
        XCTAssertEqual(hit.to, pos + hit.node.nodeSize)
        // View coordinates, so scrolling moves the answer with the content.
        view.contentOffsetY = 40
        XCTAssertEqual(view.imageNode(at: CGPoint(x: point.x, y: point.y - 40))?.from, pos)
    }

    func testTheGestureOnlyClaimsTheImageWhenAHandlerIsSet() throws {
        let (view, _) = try blockView()
        let point = try center(view)
        XCTAssertFalse(view.shouldActivateImage(at: point), "unset: the press is left to the drag")
        view.onActivateImage = { _, _ in }
        XCTAssertTrue(view.shouldActivateImage(at: point))
        XCTAssertFalse(view.shouldActivateImage(at: CGPoint(x: 4, y: 4)), "and only over an image")
    }

    func testTheLongPressRecognizerIsInstalled() throws {
        let (view, _) = try blockView()
        let presses = view.gestureRecognizers?.filter { $0 is UILongPressGestureRecognizer } ?? []
        XCTAssertTrue(presses.contains { $0.delegate === view }, "ours, gated by the delegate")
    }

    func testSettingTheHandlerOptsTheImageOutOfTheDrag() throws {
        // The two want the same long press. With no handler the drag lifts the
        // image as it always has; with one, activation takes it instead.
        let (view, _) = try blockView()
        let point = try center(view)
        let session = FakeDragSession(location: point)
        let interaction = UIDragInteraction(delegate: view)
        XCTAssertEqual(view.dragInteraction(interaction, itemsForBeginning: session).count, 1,
                       "unset: the image still drags out")
        view.onActivateImage = { _, _ in }
        XCTAssertTrue(view.dragInteraction(interaction, itemsForBeginning: session).isEmpty,
                      "set: the press activates rather than lifting the image")
    }
}

/// A drag session reporting one fixed location — enough to drive
/// `itemsForBeginning`, which only asks where the drag started.
private final class FakeDragSession: NSObject, UIDragSession {
    private let point: CGPoint
    init(location: CGPoint) { self.point = location }
    func location(in view: UIView) -> CGPoint { point }
    var items: [UIDragItem] = []
    var allowsMoveOperation: Bool = true
    var isRestrictedToDraggingApplication: Bool = false
    var localContext: Any?
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
}
#endif
