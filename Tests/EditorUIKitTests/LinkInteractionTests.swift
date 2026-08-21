#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class LinkInteractionTests: XCTestCase {
    /// "before " + linked "site" + " after", link href https://example.com,
    /// title "Example" (so the tests can see attrs beyond the URL).
    private func linkedView() throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let link = s.marks["link"]!.create(["href": .string("https://example.com"),
                                            "title": .string("Example")])
        let para = try s.node("paragraph", [:], content: Fragment.from([
            s.text("before "),
            s.text("site", [link]),
            s.text(" after"),
        ]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([para])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()
        return view
    }

    /// A point (DOCUMENT coordinates) inside the linked word, and one in the
    /// plain text before it.
    private func points(in view: EditorTextView) throws -> (onLink: CGPoint, offLink: CGPoint) {
        let l = view.ensureLayout()
        let link = try XCTUnwrap(l.selectionRects(from: 8, to: 12).first)
        let plain = try XCTUnwrap(l.selectionRects(from: 1, to: 3).first)
        return (CGPoint(x: link.midX, y: link.midY), CGPoint(x: plain.midX, y: plain.midY))
    }

    func testAClickActivatesALinkOnlyWhenAHostIsListening() throws {
        let view = try linkedView()
        let p = try points(in: view)
        XCTAssertFalse(view.shouldActivateLink(at: p.onLink),
                       "no onLinkClick — the click places the caret instead")
        view.onLinkClick = { _ in }
        XCTAssertTrue(view.shouldActivateLink(at: p.onLink))
    }

    func testAClickOffAnyLinkNeverActivates() throws {
        let view = try linkedView()
        let p = try points(in: view)
        view.onLinkClick = { _ in }
        XCTAssertFalse(view.shouldActivateLink(at: p.offLink))
    }

    func testLinkInfoFindsTheFullRangeAndHref() throws {
        let view = try linkedView()
        // "before " is 7 chars at doc pos 1..8; "site" is 8..12.
        let info = try XCTUnwrap(view.linkInfo(at: 9))
        XCTAssertEqual(info.from, 8)
        XCTAssertEqual(info.to, 12)
        XCTAssertEqual(info.href, "https://example.com")
    }

    func testLinkInfoNilOutsideTheLink() throws {
        let view = try linkedView()
        XCTAssertNil(view.linkInfo(at: 3), "plain text before the link")
        XCTAssertNil(view.linkInfo(at: 14), "plain text after the link")
    }

    func testPointerOverLinkIsALinkTargetOnlyWhenClickable() throws {
        let view = try linkedView()
        let l = view.ensureLayout()
        let linkRect = try XCTUnwrap(l.selectionRects(from: 8, to: 12).first)
        let onLink = CGPoint(x: linkRect.midX, y: linkRect.midY - view.contentOffsetY)
        XCTAssertEqual(view.pointerTarget(at: onLink), .text,
                       "inert without a handler — no highlight promising a click")
        view.onLinkClick = { _ in }
        let rect = try XCTUnwrap(l.selectionRects(from: 8, to: 12).first)
        let mid = CGPoint(x: rect.midX, y: rect.midY - view.contentOffsetY)
        guard case .link = view.pointerTarget(at: mid) else {
            return XCTFail("expected a link pointer target, got \(view.pointerTarget(at: mid))")
        }
        // Plain text elsewhere is a text target.
        let before = try XCTUnwrap(l.selectionRects(from: 1, to: 3).first)
        XCTAssertEqual(view.pointerTarget(at: CGPoint(x: before.midX, y: before.midY - view.contentOffsetY)), .text)
    }

    func testTheHandlerGetsTheNodeAndEveryLinkAttribute() throws {
        let view = try linkedView()
        var click: LinkClick?
        view.onLinkClick = { click = $0 }
        // Drive the handler the way the gated recognizer would.
        view.activateLink(at: 9, commandHeld: true)
        let got = try XCTUnwrap(click)
        XCTAssertEqual(got.node.text, "site", "the node clicked, not just its URL")
        XCTAssertEqual(got.url?.absoluteString, "https://example.com")
        XCTAssertEqual(got.title, "Example", "attrs beyond href reach the host")
        XCTAssertEqual(got.from, 8)
        XCTAssertEqual(got.to, 12)
        XCTAssertTrue(got.commandHeld)
    }

    func testNothingIsActivatedWithoutAHandler() throws {
        let view = try linkedView()
        // No onLinkClick: the view opens nothing itself, so this is a no-op
        // rather than a system open.
        view.activateLink(at: 9, commandHeld: false)
    }
}
#endif
