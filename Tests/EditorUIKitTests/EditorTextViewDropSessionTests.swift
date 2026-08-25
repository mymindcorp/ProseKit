#if canImport(UIKit)
import XCTest
import UIKit
import UniformTypeIdentifiers
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// `UIDragSession` / `UIDropSession` are protocols, so the drag-and-drop
/// delegate can be driven end to end with scripted sessions — which is the only
/// way to reach it without a real touch drag. `DragDropTests` covers the
/// document transforms underneath; this covers the delegate that calls them.
@MainActor
private final class FakeDragSession: NSObject, UIDragSession {
    var items: [UIDragItem] = []
    var point: CGPoint = .zero
    var localContext: Any?
    var allowsMoveOperation = true
    var isRestrictedToDraggingApplication = false

    func location(in view: UIView) -> CGPoint { point }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
}

@MainActor
private final class FakeDropSession: NSObject, @preconcurrency UIDropSession {
    var items: [UIDragItem] = []
    var point: CGPoint = .zero
    var localDragSession: (any UIDragSession)?
    var allowsMoveOperation = true
    var isRestrictedToDraggingApplication = false
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .default
    var progress = Progress()

    /// Objects handed to `loadObjects(ofClass:)`, keyed by the class asked for.
    var stringObjects: [NSString] = []
    var imageObjects: [UIImage] = []

    func location(in view: UIView) -> CGPoint { point }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
        items.contains { item in
            item.itemProvider.registeredTypeIdentifiers.contains { typeIdentifiers.contains($0) }
        }
    }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
        if aClass == NSString.self { return !stringObjects.isEmpty }
        if aClass == UIImage.self { return !imageObjects.isEmpty }
        return false
    }
    func loadObjects(ofClass aClass: any NSItemProviderReading.Type,
                     completion: @escaping ([any NSItemProviderReading]) -> Void) -> Progress {
        if aClass == NSString.self { completion(stringObjects) }
        if aClass == UIImage.self { completion(imageObjects) }
        return Progress()
    }
}

@MainActor
final class EditorTextViewDropSessionTests: XCTestCase {
    private func makeView(_ build: (Schema) throws -> [Node]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(build(editor.schema))))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        view.layoutIfNeeded()
        _ = view.ensureLayout()
        return view
    }

    private func textView(_ text: String) throws -> EditorTextView {
        try makeView { s in
            [try s.node("paragraph", [:], content: Fragment.from([s.text(text)]))]
        }
    }

    private func imageDoc() throws -> EditorTextView {
        try makeView { s in
            [
                try s.node("image", ["src": .string("https://example.com/a.png"),
                                     "width": .int(100), "height": .int(80)]),
                try s.node("paragraph", [:], content: Fragment.from([s.text("after")])),
            ]
        }
    }

    private var dropInteraction: UIDropInteraction { UIDropInteraction(delegate: NoopDropDelegate.shared) }
    private var dragInteraction: UIDragInteraction { UIDragInteraction(delegate: NoopDragDelegate.shared) }

    /// The view point that lands at the caret position we want to drop at.
    private func pointFor(_ view: EditorTextView, position: Int) throws -> CGPoint {
        let rect = try XCTUnwrap(view.ensureLayout().caretRect(at: position))
        return CGPoint(x: rect.midX, y: rect.midY - view.contentOffsetY)
    }

    /// The drop-cursor layer the delegate draws into.
    private func dropCursorPath(_ view: EditorTextView) -> CGPath? {
        view.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.compactMap(\.path).first
    }

    // MARK: - canHandle

    func testCanHandleAcceptsTextAndImagesButNotAnEmptySession() throws {
        let view = try textView("ABCDEF")
        let session = FakeDropSession()

        XCTAssertFalse(view.dropInteraction(dropInteraction, canHandle: session),
                       "nothing loadable, nothing to accept")

        session.stringObjects = ["dropped"]
        XCTAssertTrue(view.dropInteraction(dropInteraction, canHandle: session))

        session.stringObjects = []
        session.imageObjects = [UIImage()]
        XCTAssertTrue(view.dropInteraction(dropInteraction, canHandle: session))
    }

    func testCanHandleAcceptsAProviderCarryingImageBytes() throws {
        let view = try textView("ABCDEF")
        let session = FakeDropSession()
        session.items = [UIDragItem(itemProvider: pngProvider())]
        XCTAssertTrue(view.dropInteraction(dropInteraction, canHandle: session),
                      "a registered public.image type is enough")
    }

    func testReadOnlyRefusesEveryDrop() throws {
        let view = try textView("ABCDEF")
        view.isEditable = false
        let session = FakeDropSession()
        session.stringObjects = ["dropped"]
        XCTAssertFalse(view.dropInteraction(dropInteraction, canHandle: session))
    }

    // MARK: - sessionDidUpdate / exit / end

    func testSessionUpdateProposesCopyForOutsideDragsAndMoveForOurOwn() throws {
        let view = try textView("ABCDEF")
        let session = FakeDropSession()
        session.point = try pointFor(view, position: 3)

        XCTAssertEqual(view.dropInteraction(dropInteraction, sessionDidUpdate: session).operation, .copy)

        session.localDragSession = FakeDragSession()
        XCTAssertEqual(view.dropInteraction(dropInteraction, sessionDidUpdate: session).operation, .move)
    }

    func testSessionUpdateDrawsTheDropCursorAndExitClearsIt() throws {
        let view = try textView("ABCDEF")
        let session = FakeDropSession()
        session.point = try pointFor(view, position: 3)

        _ = view.dropInteraction(dropInteraction, sessionDidUpdate: session)
        XCTAssertNotNil(dropCursorPath(view), "the drop indicator is drawn")

        view.dropInteraction(dropInteraction, sessionDidExit: session)
        XCTAssertNil(dropCursorPath(view), "leaving the view clears it")

        _ = view.dropInteraction(dropInteraction, sessionDidUpdate: session)
        XCTAssertNotNil(dropCursorPath(view))
        view.dropInteraction(dropInteraction, sessionDidEnd: session)
        XCTAssertNil(dropCursorPath(view), "the session ending clears it")
    }

    func testDropCursorFollowsAPointOutsideTheDocumentToTheNearestPosition() throws {
        let view = try textView("ABCDEF")
        let session = FakeDropSession()
        session.point = try pointFor(view, position: 3)
        _ = view.dropInteraction(dropInteraction, sessionDidUpdate: session)
        let atThree = try XCTUnwrap(dropCursorPath(view)).boundingBox

        // Hit-testing clamps, so a point above and left of everything still
        // resolves — to the very start of the document.
        session.point = CGPoint(x: -5000, y: -5000)
        _ = view.dropInteraction(dropInteraction, sessionDidUpdate: session)
        let clamped = try XCTUnwrap(dropCursorPath(view)).boundingBox
        XCTAssertLessThan(clamped.minX, atThree.minX, "the indicator moved back to the start")
    }

    // MARK: - performDrop

    func testPerformDropInsertsDroppedText() throws {
        let view = try textView("ABCDEF")
        let session = FakeDropSession()
        session.stringObjects = ["XY"]
        session.point = try pointFor(view, position: 3) // before "C"

        view.dropInteraction(dropInteraction, performDrop: session)

        let inserted = expectation(description: "text dropped")
        Task { @MainActor in inserted.fulfill() }
        wait(for: [inserted], timeout: 2)

        XCTAssertEqual(view.editor.doc.textContent, "ABXYCDEF")
        XCTAssertNil(dropCursorPath(view), "the indicator is cleared as the drop lands")
    }

    func testPerformDropIgnoresAnEmptyString() throws {
        let view = try textView("ABCDEF")
        let session = FakeDropSession()
        session.stringObjects = [""]
        session.point = try pointFor(view, position: 3)

        view.dropInteraction(dropInteraction, performDrop: session)
        let done = expectation(description: "settled")
        Task { @MainActor in done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(view.editor.doc.textContent, "ABCDEF")
    }

    func testPerformDropOfAUIImageInsertsAnImageNode() throws {
        let view = try textView("ABCDEF")
        let session = FakeDropSession()
        session.imageObjects = [solidImage()]
        session.point = try pointFor(view, position: 3)

        view.dropInteraction(dropInteraction, performDrop: session)

        let dropped = expectation(description: "image dropped")
        Task { @MainActor in Task { @MainActor in dropped.fulfill() } }
        wait(for: [dropped], timeout: 3)

        XCTAssertTrue(hasImage(view), "an image node was inserted")
    }

    func testPerformDropOutsideTheDocumentLandsAtTheNearestPosition() throws {
        let view = try textView("ABCDEF")
        let session = FakeDropSession()
        session.stringObjects = ["XY"]
        session.point = CGPoint(x: -5000, y: -5000) // above and left of everything

        view.dropInteraction(dropInteraction, performDrop: session)
        let done = expectation(description: "settled")
        Task { @MainActor in done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(view.editor.doc.textContent, "XYABCDEF", "clamped to the document start")
    }

    // MARK: - A local drag, start to finish

    func testDraggingSelectedTextWithinTheDocumentMovesIt() throws {
        let view = try textView("ABCDEF")
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 1, 3))) // "AB"

        let drag = FakeDragSession()
        drag.point = try pointFor(view, position: 2) // inside the selection
        let items = view.dragInteraction(dragInteraction, itemsForBeginning: drag)
        XCTAssertEqual(items.count, 1, "the selection is draggable")

        let drop = FakeDropSession()
        drop.localDragSession = drag
        drop.stringObjects = ["AB"]
        drop.point = try pointFor(view, position: 7) // the end

        view.dropInteraction(dropInteraction, performDrop: drop)
        let moved = expectation(description: "moved")
        Task { @MainActor in moved.fulfill() }
        wait(for: [moved], timeout: 2)

        XCTAssertEqual(view.editor.doc.textContent, "CDEFAB", "the text moved rather than being copied")
    }

    func testADragStartedOffTheSelectionCarriesNothing() throws {
        let view = try textView("ABCDEF")
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 1, 3)))

        let drag = FakeDragSession()
        drag.point = try pointFor(view, position: 6) // well outside "AB"
        XCTAssertTrue(view.dragInteraction(dragInteraction, itemsForBeginning: drag).isEmpty)
    }

    func testADragWithNoSelectionCarriesNothing() throws {
        let view = try textView("ABCDEF")
        let drag = FakeDragSession()
        drag.point = try pointFor(view, position: 3)
        XCTAssertTrue(view.dragInteraction(dragInteraction, itemsForBeginning: drag).isEmpty)
    }

    func testDraggingAnImageOffersItAndMovesTheNodeOnDrop() throws {
        let view = try imageDoc()
        let rect = try XCTUnwrap(view.ensureLayout().imageRects.first).rect

        let drag = FakeDragSession()
        drag.point = CGPoint(x: rect.midX, y: rect.midY - view.contentOffsetY)
        let items = view.dragInteraction(dragInteraction, itemsForBeginning: drag)
        XCTAssertEqual(items.count, 1, "grabbing an image starts a drag of that node")
        XCTAssertNotNil(items.first?.localObject, "the node travels with the item for a local move")

        // Drop it back at the end of the document.
        let drop = FakeDropSession()
        drop.localDragSession = drag
        drop.point = try pointFor(view, position: view.editor.doc.content.size - 1)
        view.dropInteraction(dropInteraction, performDrop: drop)

        XCTAssertTrue(hasImage(view), "the image is still in the document")
        XCTAssertEqual(view.editor.doc.child(0).type.name, "paragraph",
                       "the image is no longer the first block — it moved")
    }

    func testAnImageDragIsSuppressedWhenAHostClaimsImageActivation() throws {
        let view = try imageDoc()
        view.onActivateImage = { _, _ in }
        let rect = try XCTUnwrap(view.ensureLayout().imageRects.first).rect

        let drag = FakeDragSession()
        drag.point = CGPoint(x: rect.midX, y: rect.midY - view.contentOffsetY)
        XCTAssertTrue(view.dragInteraction(dragInteraction, itemsForBeginning: drag).isEmpty,
                      "the long press belongs to the host, so the drag stands down")
    }

    func testADragStartingOnTheResizeHandleIsNotAReorder() throws {
        let view = try imageDoc()
        view.imageResizingEnabled = true
        let rect = try XCTUnwrap(view.ensureLayout().imageRects.first).rect

        let drag = FakeDragSession()
        drag.point = CGPoint(x: rect.maxX - 4, y: rect.maxY - 4 - view.contentOffsetY)
        XCTAssertTrue(view.dragInteraction(dragInteraction, itemsForBeginning: drag).isEmpty,
                      "that grip resizes the image instead")
    }

    func testDragEndClearsTheMoveSource() throws {
        let view = try textView("ABCDEF")
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 1, 3)))

        let drag = FakeDragSession()
        drag.point = try pointFor(view, position: 2)
        _ = view.dragInteraction(dragInteraction, itemsForBeginning: drag)
        view.dragInteraction(dragInteraction, session: drag, didEndWith: .cancel)

        // With the source forgotten, a later local drop copies instead of moving.
        let drop = FakeDropSession()
        drop.localDragSession = drag
        drop.stringObjects = ["AB"]
        drop.point = try pointFor(view, position: 7)
        view.dropInteraction(dropInteraction, performDrop: drop)
        let done = expectation(description: "settled")
        Task { @MainActor in done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(view.editor.doc.textContent, "ABCDEFAB", "copied, not moved")
    }


    // MARK: - What an image drag offers other apps

    /// Load the drag item's registered PNG bytes, the way a receiving app would.
    private func loadPNG(_ item: UIDragItem) throws -> Data? {
        let loaded = expectation(description: "bytes loaded")
        nonisolated(unsafe) var result: Data?
        _ = item.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
            unsafe result = data
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 3)
        return unsafe result
    }

    func testAnImageDragOffersTheHostsOwnBytes() throws {
        let view = try imageDoc()
        let hostBytes = Data("the host's original file".utf8)
        view.imageData = { _ in hostBytes }

        let rect = try XCTUnwrap(view.ensureLayout().imageRects.first).rect
        let drag = FakeDragSession()
        drag.point = CGPoint(x: rect.midX, y: rect.midY - view.contentOffsetY)
        let item = try XCTUnwrap(view.dragInteraction(dragInteraction, itemsForBeginning: drag).first)

        XCTAssertEqual(try loadPNG(item), hostBytes,
                       "what leaves the app is the original, not the downsampled bitmap")
    }

    func testAnImageDragFallsBackToTheFileBehindTheNode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosekit-drag-test.png")
        let bytes = try XCTUnwrap(solidImage().pngData())
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let view = try makeView { s in
            [
                try s.node("image", ["src": .string(url.absoluteString),
                                     "width": .int(100), "height": .int(80)]),
                try s.node("paragraph", [:], content: Fragment.from([s.text("after")])),
            ]
        }
        // No host provider: the file behind the node is the next best source.
        let rect = try XCTUnwrap(view.ensureLayout().imageRects.first).rect
        let drag = FakeDragSession()
        drag.point = CGPoint(x: rect.midX, y: rect.midY - view.contentOffsetY)
        let item = try XCTUnwrap(view.dragInteraction(dragInteraction, itemsForBeginning: drag).first)

        XCTAssertEqual(try loadPNG(item), bytes, "the node's own file was offered")
    }

    // MARK: - Helpers

    private func hasImage(_ view: EditorTextView) -> Bool {
        var found = false
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "image" { found = true }
            return true
        }
        return found
    }

    private func solidImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func pngProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = solidImage().pngData()!
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

/// The interactions themselves are never exercised — the delegate methods take
/// one only because UIKit passes it — so these stand in as their delegates.
@MainActor
private final class NoopDropDelegate: NSObject, UIDropInteractionDelegate {
    static let shared = NoopDropDelegate()
}

@MainActor
private final class NoopDragDelegate: NSObject, UIDragInteractionDelegate {
    static let shared = NoopDragDelegate()
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] { [] }
}
#endif
