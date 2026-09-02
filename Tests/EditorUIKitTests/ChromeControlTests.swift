#if canImport(UIKit)
import XCTest
import UIKit
@testable import EditorUIKit

/// The editor's chrome — the link popover, the find bar, the suggestion popup —
/// driven through its own controls rather than by calling its callbacks.
///
/// The existing tests reach these views and then invoke `onSubmit` / `onNext`
/// directly, which is the right way to test what the *editor* does with the
/// answer. It means the views' own halves — the URL the link field normalizes
/// before it hands one over, which button is wired to which closure, which
/// field's return key means "replace" rather than "find next" — were never run.
/// A control wired to the wrong closure is invisible to every test that starts
/// from the closure.
@MainActor
final class ChromeControlTests: XCTestCase {
    private let theme = DocumentTheme()

    /// Every view of a kind in a hierarchy, in subview order.
    private func descendants<T: UIView>(_ type: T.Type, of root: UIView) -> [T] {
        var out: [T] = []
        func walk(_ v: UIView) {
            if let match = v as? T { out.append(match) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Fire a control's registered actions for an event.
    ///
    /// `sendActions(for:)` routes through `UIApplication`, which a library test
    /// bundle has no instance of, so it silently does nothing here. Invoking the
    /// registered target/action pairs is the same dispatch without the detour.
    private func fire(_ control: UIControl, _ event: UIControl.Event = .touchUpInside) {
        for target in control.allTargets {
            for action in control.actions(forTarget: target, forControlEvent: event) ?? [] {
                _ = unsafe (target as AnyObject).perform(Selector(action), with: control)
            }
        }
    }
    private func tap(_ button: UIButton) { fire(button) }

    // MARK: - Link popover

    private func linkPopup(_ initial: String?, showRemove: Bool = false) -> (view: LinkPopupView, field: UITextField, buttons: [UIButton]) {
        let popup = LinkPopupView(theme: theme, initialURL: initial, showRemove: showRemove)
        popup.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        popup.layoutIfNeeded()
        return (popup, descendants(UITextField.self, of: popup)[0], descendants(UIButton.self, of: popup))
    }

    /// Submit the popover the way the keyboard's Done key does.
    private func submitted(_ typed: String, initial: String? = nil) -> String? {
        let (popup, field, _) = linkPopup(initial)
        var got: String?
        var cancelled = false
        popup.onSubmit = { got = $0 }
        popup.onCancel = { cancelled = true }
        field.text = typed
        XCTAssertTrue(popup.textFieldShouldReturn(field), "the return key is consumed")
        XCTAssertEqual(cancelled, got == nil)
        return got
    }

    func testABareDomainGetsAnHTTPSScheme() {
        // The rule the autolink input rule follows, so a link typed here and a
        // link typed into the document mean the same thing.
        XCTAssertEqual(submitted("example.com"), "https://example.com")
        XCTAssertEqual(submitted("example.com/a/b?c=d"), "https://example.com/a/b?c=d")
    }

    func testAURLThatAlreadyHasASchemeIsLeftAlone() {
        XCTAssertEqual(submitted("https://example.com"), "https://example.com")
        XCTAssertEqual(submitted("http://example.com"), "http://example.com")
        XCTAssertEqual(submitted("mailto:someone@example.com"), "mailto:someone@example.com")
        XCTAssertEqual(submitted("ftp://files.example.com"), "ftp://files.example.com")
    }

    func testSurroundingWhitespaceIsTrimmedBeforeTheSchemeIsDecided() {
        // A URL pasted from a mail client arrives with a newline on it. Without
        // the trim the scheme test sees " https://…" and prefixes it again.
        XCTAssertEqual(submitted("  example.com \n"), "https://example.com")
        XCTAssertEqual(submitted("\thttps://example.com  "), "https://example.com")
    }

    func testAnEmptyFieldCancelsRatherThanLinkingToNothing() {
        XCTAssertNil(submitted(""), "nothing submitted")
        XCTAssertNil(submitted("   \n "), "whitespace is nothing too")
    }

    func testTheApplyButtonSubmitsTheSameWayTheReturnKeyDoes() {
        let (popup, field, buttons) = linkPopup(nil)
        var got: String?
        popup.onSubmit = { got = $0 }
        field.text = "example.com"
        XCTAssertGreaterThanOrEqual(buttons.count, 1)
        tap(buttons[0])
        XCTAssertEqual(got, "https://example.com")
    }

    func testTheRemoveButtonSubmitsAnEmptyURLWhichIsHowALinkIsUnset() {
        // Only offered when editing an existing link.
        let (plain, _, plainButtons) = linkPopup("https://example.com", showRemove: false)
        XCTAssertEqual(plainButtons.count, 1, "apply only")
        _ = plain

        let (popup, field, buttons) = linkPopup("https://example.com", showRemove: true)
        XCTAssertEqual(field.text, "https://example.com", "the field opens on the current link")
        XCTAssertEqual(buttons.count, 2, "apply and remove")
        var got: String? = "untouched"
        popup.onSubmit = { got = $0 }
        tap(buttons[1])
        XCTAssertEqual(got, "", "an empty URL is the signal to remove the link")
    }

    // MARK: - Find bar

    /// A find bar with every callback recorded by name, in the order fired.
    private func findBar() -> (view: FindBarView, fired: FiredBox) {
        let bar = FindBarView(theme: theme)
        bar.frame = CGRect(x: 0, y: 0, width: 600, height: 44)
        bar.layoutIfNeeded()
        let fired = FiredBox()
        bar.onQueryChange = { fired.names.append("query:\($0)") }
        bar.onNext = { fired.names.append("next") }
        bar.onPrevious = { fired.names.append("previous") }
        bar.onReplace = { fired.names.append("replace") }
        bar.onReplaceAll = { fired.names.append("replaceAll") }
        bar.onClose = { fired.names.append("close") }
        return (bar, fired)
    }
    private final class FiredBox { var names: [String] = [] }

    func testEditingTheQueryFieldReportsEachChange() {
        let (bar, fired) = findBar()
        bar.queryField.text = "wor"
        fire(bar.queryField, .editingChanged)
        bar.queryField.text = "word"
        fire(bar.queryField, .editingChanged)
        XCTAssertEqual(fired.names, ["query:wor", "query:word"])
    }

    func testEachButtonIsWiredToItsOwnAction() {
        let (bar, fired) = findBar()
        let buttons = descendants(UIButton.self, of: bar)
        let titled = buttons.filter { $0.title(for: .normal) != nil }
        let icons = buttons.filter { $0.title(for: .normal) == nil }
        XCTAssertEqual(titled.map { $0.title(for: .normal) }, ["Replace", "All"])
        XCTAssertEqual(icons.count, 3, "previous, next, close")
        icons.forEach(tap)
        titled.forEach(tap)
        XCTAssertEqual(fired.names, ["previous", "next", "close", "replace", "replaceAll"],
                       "each control fires its own callback, and only its own")
    }

    func testTheReturnKeyMeansFindNextInTheQueryFieldAndReplaceInTheReplaceField() {
        let (bar, fired) = findBar()
        // False both times: the bar keeps the keyboard up so the next Return
        // steps to the following match instead of dismissing.
        XCTAssertFalse(bar.textFieldShouldReturn(bar.queryField))
        XCTAssertFalse(bar.textFieldShouldReturn(bar.replaceField))
        XCTAssertEqual(fired.names, ["next", "replace"])
    }

    func testEscapeClosesTheFindBar() throws {
        let (bar, fired) = findBar()
        let commands = try XCTUnwrap(bar.keyCommands)
        let escape = try XCTUnwrap(commands.first { $0.input == UIKeyCommand.inputEscape })
        XCTAssertTrue(escape.modifierFlags.isEmpty)
        _ = unsafe bar.perform(escape.action)
        XCTAssertEqual(fired.names, ["close"])
    }

    // MARK: - Suggestion popup

    /// A touch that reports a location we choose — `UITouch` has no way to be
    /// built at a point, and the popup selects on touch-down by design.
    private final class TouchAt: UITouch {
        var point: CGPoint = .zero
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private func popup(_ titles: [String]) -> SuggestionPopupView {
        let view = SuggestionPopupView(theme: theme)
        view.setItems(titles.map { SuggestionPopupView.Item(title: $0, subtitle: nil, icon: nil) })
        view.frame = CGRect(origin: .zero, size: view.fittingSize())
        view.layoutIfNeeded()
        return view
    }

    /// The vertical middle of row `index`, in the coordinate space
    /// `touchesBegan` measures against.
    private func midY(ofRow index: Int, in view: SuggestionPopupView) throws -> CGFloat {
        let stack = try XCTUnwrap(descendants(UIStackView.self, of: view).first)
        let row = stack.arrangedSubviews[index]
        return row.frame.midY
    }

    func testTouchingARowSelectsItAndReportsIt() throws {
        let view = popup(["First", "Second", "Third"])
        var chosen: [Int] = []
        view.onSelect = { chosen.append($0) }
        let touch = TouchAt()
        touch.point = CGPoint(x: 40, y: try midY(ofRow: 2, in: view))
        view.touchesBegan([touch], with: nil)
        XCTAssertEqual(chosen, [2], "the row under the finger")
        XCTAssertEqual(view.selectedIndex, 2, "and the highlight moves to it")
        XCTAssertEqual(view.selected, 2)
    }

    func testTouchingBelowTheLastRowSelectsNothing() throws {
        let view = popup(["First", "Second"])
        var chosen: [Int] = []
        view.onSelect = { chosen.append($0) }
        let before = view.selectedIndex
        let touch = TouchAt()
        touch.point = CGPoint(x: 40, y: 10_000)
        view.touchesBegan([touch], with: nil)
        XCTAssertEqual(chosen, [], "no row there, so nothing is chosen")
        XCTAssertEqual(view.selectedIndex, before, "and the highlight stays where it was")
    }

    func testTheCardIsAFixedWidthAndGrowsWithItsRowsUpToACap() {
        let two = popup(["First", "Second"])
        let many = popup((1 ... 20).map { "Item \($0)" })
        XCTAssertEqual(two.intrinsicContentSize.width, 280)
        XCTAssertEqual(two.intrinsicContentSize.height, UIView.noIntrinsicMetric)
        XCTAssertGreaterThan(many.fittingSize().height, two.fittingSize().height)
        // Past seven rows the card stops growing and the list scrolls instead.
        let seven = popup((1 ... 7).map { "Item \($0)" })
        XCTAssertEqual(many.fittingSize().height, seven.fittingSize().height, accuracy: 0.5)
    }

    func testMovingTheSelectionWrapsAroundBothWays() {
        let view = popup(["First", "Second", "Third"])
        XCTAssertEqual(view.selectedIndex, 0)
        view.moveSelection(by: -1)
        XCTAssertEqual(view.selectedIndex, 2, "up from the first wraps to the last")
        view.moveSelection(by: 1)
        XCTAssertEqual(view.selectedIndex, 0, "and down from the last comes back")
        // An empty list has nothing to move to, and must not divide by zero.
        let empty = popup([])
        empty.moveSelection(by: 1)
        XCTAssertNil(empty.selected)
    }
}
#endif
