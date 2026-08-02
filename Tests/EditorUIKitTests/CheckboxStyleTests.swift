#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class CheckboxStyleTests: XCTestCase {
    private func taskListView(theme: TextTheme = TextTheme()) throws -> EditorTextView {
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
        let view = EditorTextView(editor: editor, theme: theme)
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

    // MARK: - Checked-item text styling

    private func strikethrough(_ view: EditorTextView, _ text: String) -> Bool {
        guard let block = view.ensureLayout().blocks.first(where: { $0.attributed.string == text }),
              block.attributed.length > 0 else { return false }
        return block.attributed.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil
    }

    private func textColor(_ view: EditorTextView, _ text: String) -> UIColor? {
        guard let block = view.ensureLayout().blocks.first(where: { $0.attributed.string == text }),
              block.attributed.length > 0 else { return nil }
        return block.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
    }

    func testCheckedItemsAreUnstyledByDefault() throws {
        let view = try taskListView()
        XCTAssertFalse(strikethrough(view, "done"), "no strikethrough unless the host asks for it")
    }

    func testStrikethroughAppliesOnlyToCheckedItems() throws {
        var theme = TextTheme()
        theme.taskItem.strikethroughWhenChecked = true
        let view = try taskListView(theme: theme)
        XCTAssertTrue(strikethrough(view, "done"), "the checked item reads as done")
        XCTAssertFalse(strikethrough(view, "todo"), "the unchecked item is untouched")
    }

    func testCheckedTextColorAppliesOnlyToCheckedItems() throws {
        var theme = TextTheme()
        theme.taskItem.checkedTextColor = .systemRed
        let view = try taskListView(theme: theme)
        XCTAssertEqual(textColor(view, "done"), .systemRed)
        XCTAssertEqual(textColor(view, "todo"), theme.textColor)
    }

    func testTogglingRestylesTheItem() throws {
        // Regression: the block cache is keyed on the paragraph, which is the
        // *same* node whether its item is checked or not — so without the
        // checked flag in the key, a toggle reused the stale typeset.
        var theme = TextTheme()
        theme.taskItem.strikethroughWhenChecked = true
        let view = try taskListView(theme: theme)
        view.syncCheckboxViews()
        try XCTUnwrap(boxes(view).first { !$0.isChecked }).onToggle?() // check "todo"
        XCTAssertTrue(strikethrough(view, "todo"), "checking restyles the item")

        try XCTUnwrap(boxes(view).sorted { $0.frame.minY < $1.frame.minY }.first).onToggle?() // uncheck "done"
        XCTAssertFalse(strikethrough(view, "done"), "unchecking clears the strikethrough")
    }

    func testANestedUncheckedItemIsNotStruckThrough() throws {
        // A sub-task is still to do, whatever its parent says. (Tiptap's
        // descendant CSS selector strikes these; we deliberately don't.)
        var theme = TextTheme()
        theme.taskItem.strikethroughWhenChecked = true
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func para(_ t: String) -> Node { try! s.node("paragraph", [:], content: Fragment.from([s.text(t)])) }
        let sub = try s.node("taskList", [:], content: Fragment.from([
            try s.node("taskItem", ["checked": .bool(false)], content: Fragment.from([para("sub")])),
        ]))
        let outer = try s.node("taskItem", ["checked": .bool(true)],
                               content: Fragment.from([para("parent"), sub]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("taskList", [:], content: Fragment.from([outer])),
        ])))
        let view = EditorTextView(editor: editor, theme: theme)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        XCTAssertTrue(strikethrough(view, "parent"), "the checked item itself is struck")
        XCTAssertFalse(strikethrough(view, "sub"), "its unchecked sub-task is not")
    }

    func testCheckboxColorsAreThemeable() {
        var theme = TextTheme()
        theme.taskItem.checkboxTint = .systemPink
        theme.taskItem.checkboxBorderColor = .systemGreen
        let box = DefaultTaskCheckboxView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        box.theme = theme
        box.layoutIfNeeded()
        let fill = box.layer.sublayers?.compactMap { ($0 as? CAShapeLayer)?.fillColor }
        let stroke = box.layer.sublayers?.compactMap { ($0 as? CAShapeLayer)?.strokeColor }
        XCTAssertEqual(fill?.contains(UIColor.systemPink.cgColor), true, "checkbox tint")
        XCTAssertEqual(stroke?.contains(UIColor.systemGreen.cgColor), true, "checkbox border")
    }

    func testCheckboxColorsFallBackToTheCaretAndBarColors() {
        // The historical behaviour, kept as the default so existing hosts see
        // no change when they haven't set the new options.
        var theme = TextTheme()
        theme.caretColor = .systemPurple
        theme.quoteBarColor = .systemTeal
        let box = DefaultTaskCheckboxView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        box.theme = theme
        box.layoutIfNeeded()
        let fill = box.layer.sublayers?.compactMap { ($0 as? CAShapeLayer)?.fillColor }
        let stroke = box.layer.sublayers?.compactMap { ($0 as? CAShapeLayer)?.strokeColor }
        XCTAssertEqual(fill?.contains(UIColor.systemPurple.cgColor), true)
        XCTAssertEqual(stroke?.contains(UIColor.systemTeal.cgColor), true)
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
