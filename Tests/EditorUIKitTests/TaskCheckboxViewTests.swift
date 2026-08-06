#if canImport(UIKit)
import XCTest
import UIKit
@testable import EditorUIKit

/// The parts of `DefaultTaskCheckboxView` the existing checkbox tests reach
/// around rather than through.
///
/// `CheckboxStyleTests` toggles by calling `onToggle?()` directly — its own
/// comment says "what the view's tap recognizer invokes" — which is the right
/// way to test what the *editor* does with a toggle, but it means the view's
/// own tap path has never run. Neither has the optimistic check-on animation
/// behind it, nor either half of the pointer interaction.
///
/// That matters because this is the one control in the editor a user operates
/// by tapping rather than by typing. A checkbox that no longer responds to its
/// own tap, or that animates when it shouldn't, is invisible to every test
/// that goes through `onToggle`.

/// `UIPointerRegionRequest` has no way to set a location, so the delegate can't
/// be asked about a point without one of these. The property is read-only
/// rather than final, so a subclass can answer for it.
private final class FakePointerRequest: UIPointerRegionRequest {
    private let stubbed: CGPoint
    init(at location: CGPoint) { self.stubbed = location; super.init() }
    override var location: CGPoint { stubbed }
}

@MainActor
final class TaskCheckboxViewTests: XCTestCase {
    private func box(_ side: CGFloat = 30) -> DefaultTaskCheckboxView {
        let view = DefaultTaskCheckboxView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        view.layoutIfNeeded()
        return view
    }

    // The three layers, in the order `init` adds them. They're private, so this
    // is how a test sees what the control is drawing.
    private func fill(_ v: DefaultTaskCheckboxView) -> CALayer? { v.layer.sublayers?[0] }
    private func stroke(_ v: DefaultTaskCheckboxView) -> CALayer? { v.layer.sublayers?[1] }
    private func check(_ v: DefaultTaskCheckboxView) -> CALayer? { v.layer.sublayers?[2] }

    /// Send the action the tap recognizer sends. The handler is `@objc` for
    /// exactly this reason — it's the message `UITapGestureRecognizer` delivers.
    private func tap(_ v: DefaultTaskCheckboxView) {
        unsafe v.perform(NSSelectorFromString("handleTap"))
    }

    // MARK: The tap

    func testTheViewHasATapRecognizer() throws {
        // Without this the control is inert, and every test that calls
        // `onToggle` directly would still pass.
        let view = box()
        XCTAssertEqual(view.gestureRecognizers?.filter { $0 is UITapGestureRecognizer }.count, 1)
        XCTAssertTrue(view.interactions.contains { $0 is UIPointerInteraction })
    }

    func testTappingFiresOnToggle() {
        let view = box()
        var toggles = 0
        view.onToggle = { toggles += 1 }
        tap(view)
        XCTAssertEqual(toggles, 1)
        tap(view)
        XCTAssertEqual(toggles, 2, "each tap is its own toggle")
    }

    func testTappingDoesNotDecideTheState() {
        // The documented contract: the editor commits the change and the new
        // state arrives back through `isChecked`. A view that set it itself
        // would show a tick the document doesn't have when the edit is refused
        // or undone.
        let view = box()
        view.onToggle = {}
        tap(view)
        XCTAssertFalse(view.isChecked, "the view must not decide its own state")
        view.isChecked = true
        tap(view)
        XCTAssertTrue(view.isChecked)
    }

    func testTappingSurvivesHavingNoHandler() {
        // Views are recycled, and one that's between assignments has no
        // `onToggle`. A tap then must do nothing rather than trap.
        let view = box()
        XCTAssertNil(view.onToggle)
        tap(view)
    }

    // MARK: The optimistic animation

    func testTappingAnUncheckedBoxShowsTheTickAtOnce() {
        // The tick appears before the document round-trip, so the control feels
        // immediate. The layers flip now; `isChecked` catches up later.
        let view = box()
        view.onToggle = {}
        XCTAssertEqual(fill(view)?.isHidden, true, "unchecked: no fill")
        XCTAssertEqual(stroke(view)?.isHidden, false, "unchecked: an outline")
        tap(view)
        XCTAssertEqual(fill(view)?.isHidden, false, "the fill should show immediately")
        XCTAssertEqual(check(view)?.isHidden, false, "and the tick with it")
        XCTAssertEqual(stroke(view)?.isHidden, true, "the outline gives way")
    }

    func testTappingAnUncheckedBoxAnimatesBothLayers() {
        let view = box()
        view.onToggle = {}
        tap(view)
        XCTAssertNotNil(fill(view)?.animation(forKey: "checkOnScale"), "the fill should scale in")
        XCTAssertNotNil(check(view)?.animation(forKey: "checkOnStroke"), "the tick should draw on")
    }

    func testUncheckingIsInstant() {
        // System behaviour: ticking a box is celebrated, unticking isn't.
        let view = box()
        view.isChecked = true
        view.onToggle = {}
        tap(view)
        XCTAssertNil(fill(view)?.animation(forKey: "checkOnScale"),
                     "unchecking must not play the check-on animation")
        XCTAssertNil(check(view)?.animation(forKey: "checkOnStroke"))
    }

    func testSettingTheStateDirectlyNeverAnimates() {
        // `isChecked` is also set while scrolling and recycling, where an
        // animation would flash rows that merely came into view.
        let view = box()
        view.isChecked = true
        XCTAssertNil(fill(view)?.animation(forKey: "checkOnScale"))
        XCTAssertEqual(fill(view)?.isHidden, false)
        XCTAssertEqual(stroke(view)?.isHidden, true)
        view.isChecked = false
        XCTAssertEqual(fill(view)?.isHidden, true)
        XCTAssertEqual(stroke(view)?.isHidden, false)
    }

    func testTheAccessibleValueFollowsTheState() {
        let view = box()
        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertEqual(view.accessibilityTraits, .button)
        XCTAssertEqual(view.accessibilityLabel, "Task")
        XCTAssertEqual(view.accessibilityValue, "Unchecked")
        view.isChecked = true
        XCTAssertEqual(view.accessibilityValue, "Checked")
    }

    // MARK: The pointer

    func testThePointerOnlyRespondsOverTheCircle() throws {
        // The frame is padded so the control is comfortable to tap, but the
        // hover highlight has to sit on the circle the user can see — a
        // highlight over empty padding looks like a bug in the layout.
        let view = box(44)
        let interaction = UIPointerInteraction(delegate: nil)
        let whole = UIPointerRegion(rect: view.bounds)
        let centre = view.pointerInteraction(interaction,
                                             regionFor: FakePointerRequest(at: CGPoint(x: 22, y: 22)),
                                             defaultRegion: whole)
        XCTAssertNotNil(centre, "the middle of the circle should be interactive")
        let corner = view.pointerInteraction(interaction,
                                             regionFor: FakePointerRequest(at: .zero),
                                             defaultRegion: whole)
        XCTAssertNil(corner, "the padded corner is not the control")
    }

    func testThePointerRegionIsTheCircleNotTheFrame() throws {
        let view = box(44)
        let interaction = UIPointerInteraction(delegate: nil)
        let region = try XCTUnwrap(view.pointerInteraction(
            interaction, regionFor: FakePointerRequest(at: CGPoint(x: 22, y: 22)),
            defaultRegion: UIPointerRegion(rect: view.bounds)))
        XCTAssertLessThan(region.rect.width, view.bounds.width,
                          "the highlight should be the circle, not the whole padded frame")
        XCTAssertEqual(region.rect.midX, view.bounds.midX, accuracy: 0.01, "and centred on it")
        XCTAssertEqual(region.rect.midY, view.bounds.midY, accuracy: 0.01)
    }

    func testThePointerHasAStyle() throws {
        // Returning nil here would leave the checkbox with no hover affordance
        // at all, which is the difference between "clickable" and "decoration".
        let view = box(44)
        let interaction = UIPointerInteraction(delegate: nil)
        let region = UIPointerRegion(rect: CGRect(x: 7, y: 7, width: 16, height: 16))
        XCTAssertNotNil(view.pointerInteraction(interaction, styleFor: region))
    }

    // MARK: Sizing

    func testTheCircleSurvivesASqueezedFrame() {
        // `circleRect` floors the side at 8, so a frame smaller than the
        // padding still draws a circle rather than an inverted rectangle.
        for side in [CGFloat(0), 1, 10, 14, 15, 30] {
            let view = box(side)
            XCTAssertNotNil(view.layer.sublayers, "no layers at \(side)")
            for layer in view.layer.sublayers ?? [] where layer is CAShapeLayer {
                let path = (layer as? CAShapeLayer)?.path
                if let path {
                    XCTAssertFalse(path.boundingBox.width < 0, "negative geometry at \(side)")
                }
            }
        }
    }
}
#endif
