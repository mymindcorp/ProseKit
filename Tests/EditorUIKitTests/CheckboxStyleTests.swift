#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
import DocumentTransform
@testable import EditorUIKit

@MainActor
final class CheckboxStyleTests: XCTestCase {
    private func taskListView() throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func item(_ text: String, checked: Bool) -> Node {
            try! s.node("taskItem", ["checked": .bool(checked)], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
            ]))
        }
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("taskList", [:], content: Fragment.from([
                item("done", checked: true), item("todo", checked: false),
            ])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func boxes(_ view: EditorTextView) -> [DefaultTaskCheckboxView] {
        view.subviews.compactMap { $0 as? DefaultTaskCheckboxView }.filter { !$0.isHidden }
    }

    func testACheckboxViewIsCreatedPerItemWithMatchingState() throws {
        let view = try taskListView()
        view.syncCheckboxViews()
        let b = boxes(view)
        XCTAssertEqual(b.count, 2, "one checkbox view per task item")
        XCTAssertEqual(Set(b.map(\.isChecked)), [true, false], "states mirror the document")
    }

    func testTappingACheckboxTogglesTheDocument() throws {
        let view = try taskListView()
        view.syncCheckboxViews()
        let todo = try XCTUnwrap(boxes(view).first { !$0.isChecked })
        todo.onToggle?() // what the view's tap recognizer invokes
        view.syncCheckboxViews()
        XCTAssertTrue(boxes(view).allSatisfy(\.isChecked), "the toggled item is now checked")
        // The document attribute actually changed.
        var checkedCount = 0
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "taskItem", node.attrs["checked"]?.boolValue == true { checkedCount += 1 }
            return true
        }
        XCTAssertEqual(checkedCount, 2)
    }

    func testTogglingACheckboxDoesNotFocusTheEditor() throws {
        // Ticking a task off is a one-shot action, not a request to edit: an
        // unfocused editor must stay unfocused (no keyboard).
        let view = try taskListView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.syncCheckboxViews()
        XCTAssertFalse(view.isFirstResponder)
        try XCTUnwrap(boxes(view).first { !$0.isChecked }).onToggle?()
        XCTAssertFalse(view.isFirstResponder, "toggling must not raise the keyboard")

        // And a focused editor keeps its focus (the tap doesn't blur it either).
        XCTAssertTrue(view.becomeFirstResponder())
        view.syncCheckboxViews()
        try XCTUnwrap(boxes(view).first).onToggle?()
        XCTAssertTrue(view.isFirstResponder, "an editing session survives a toggle")
    }

    func testTextInteractionIsBlockedOverCheckboxes() throws {
        // The checkbox views are subviews, but UITextInteraction's recognizers
        // live on the editor and still see those touches — so the interaction
        // must decline to begin over a checkbox, or it would place the caret
        // (and focus the editor) behind the toggle's back.
        let view = try taskListView()
        view.syncCheckboxViews()
        let interaction = UITextInteraction(for: .editable)
        let box = try XCTUnwrap(boxes(view).first)
        XCTAssertFalse(view.interactionShouldBegin(interaction, at: CGPoint(x: box.frame.midX, y: box.frame.midY)),
                       "no caret placement over a checkbox")
        XCTAssertTrue(view.interactionShouldBegin(interaction, at: CGPoint(x: 200, y: box.frame.midY)),
                      "tapping the item's text still places the caret")
    }

    func testDefaultViewIsCircularAndReflectsState() {
        let checked = DefaultTaskCheckboxView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        checked.isChecked = true
        checked.layoutIfNeeded()
        XCTAssertNotNil(checked.layer.sublayers, "draws via layers")
        // No crash toggling; accessibility reflects state.
        XCTAssertEqual(checked.accessibilityValue, "Checked")
        let unchecked = DefaultTaskCheckboxView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        XCTAssertEqual(unchecked.accessibilityValue, "Unchecked")
    }

    func testCustomProviderReplacesTheDefaultView() throws {
        final class CustomCheckbox: UIView, TaskCheckboxView {
            var isChecked = false
            var onToggle: (() -> Void)?
        }
        let view = try taskListView()
        view.checkboxViewProvider = { CustomCheckbox() }
        view.syncCheckboxViews()
        XCTAssertTrue(view.subviews.contains { $0 is CustomCheckbox }, "custom view is used")
        XCTAssertFalse(view.subviews.contains { ($0 as? DefaultTaskCheckboxView)?.isHidden == false },
                       "default views are removed when a provider is set")
    }

    func testViewsAreRecycledNotLeaked() throws {
        let view = try taskListView()
        view.syncCheckboxViews()
        view.syncCheckboxViews()
        view.syncCheckboxViews()
        // Repeated syncs must not accumulate visible checkbox views.
        XCTAssertEqual(boxes(view).count, 2)
    }

    func testDeletingARowReusesViewsAndUpdatesState() throws {
        // Regression: deleting a row flashed because every later item's position
        // shifted (pos-keyed remap missed) and layer changes implicitly animated.
        let view = try taskListView() // done(checked), todo(unchecked)
        view.syncCheckboxViews()
        let original = Set(boxes(view).map { ObjectIdentifier($0) })
        XCTAssertEqual(original.count, 2)

        // Delete the first task item (the checked "done" row).
        let editor = view.editor
        var itemPos = -1, itemSize = 0
        editor.doc.descendants { node, pos, _, _ in
            if itemPos < 0, node.type.name == "taskItem" { itemPos = pos; itemSize = node.nodeSize }
            return true
        }
        let tr = editor.state.tr
        try tr.delete(itemPos, itemPos + itemSize)
        editor.dispatch(tr)
        view.syncCheckboxViews()

        let remaining = boxes(view)
        XCTAssertEqual(remaining.count, 1, "one row left")
        XCTAssertFalse(remaining[0].isChecked, "the surviving 'todo' is unchecked")
        XCTAssertTrue(original.contains(ObjectIdentifier(remaining[0])), "view reused, not recreated")
    }

    func testTogglingOneCheckboxKeepsOtherViewsStable() throws {
        // Regression: toggling flashed the whole row because views were
        // reassigned to different items each sync. Each item must keep its view.
        let view = try taskListView()
        view.syncCheckboxViews()
        // Map each checkbox view to the text of its task item, before the toggle.
        func viewsByItem() -> [ObjectIdentifier] {
            boxes(view).sorted { $0.frame.minY < $1.frame.minY }.map { ObjectIdentifier($0) }
        }
        let before = viewsByItem()
        // Toggle the first item.
        let first = try XCTUnwrap(boxes(view).sorted { $0.frame.minY < $1.frame.minY }.first)
        first.onToggle?()
        view.syncCheckboxViews()
        let after = viewsByItem()
        XCTAssertEqual(before, after, "each item keeps the same view instance across a toggle (no flash)")
    }
}
#endif
