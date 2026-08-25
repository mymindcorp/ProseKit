#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// The rest of the `UIResponder` / UIKit surface: key commands, key auto-repeat,
/// the edit-menu and color-picker interactions, and the small view overrides.
@MainActor
final class EditorTextViewResponderTests: XCTestCase {
    private func makeView(_ lines: [String] = ["hello world"]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(
            try lines.map { line in
                try editor.schema.node("paragraph", [:], content: Fragment.from(
                    line.isEmpty ? [] : [editor.schema.text(line)]))
            })))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func cursor(_ view: EditorTextView, _ pos: Int) {
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, pos)))
    }

    /// The selector `keyCommands` wires the navigation commands to. Taken from a
    /// real command so a rename can't silently unhook these tests.
    private func navigationAction(_ view: EditorTextView) throws -> Selector {
        let commands = try XCTUnwrap(view.keyCommands)
        let home = try XCTUnwrap(commands.first { $0.input == UIKeyCommand.inputHome })
        return try XCTUnwrap(home.action)
    }

    private func send(_ view: EditorTextView, _ input: String, _ mods: UIKeyModifierFlags = []) throws {
        let action = try navigationAction(view)
        let command = UIKeyCommand(input: input, modifierFlags: mods, action: action)
        unsafe view.perform(action, with: command)
    }

    // MARK: - keyCommands

    func testKeyCommandsClaimTheKeysTheScrollViewWouldSwallow() throws {
        let view = try makeView()
        let commands = try XCTUnwrap(view.keyCommands)
        let inputs = Set(commands.compactMap(\.input))

        XCTAssertTrue(inputs.contains(UIKeyCommand.inputHome))
        XCTAssertTrue(inputs.contains(UIKeyCommand.inputEnd))
        XCTAssertTrue(inputs.contains("\t"), "Tab is claimed, for list indentation")
        XCTAssertTrue(inputs.contains("\r"), "Shift-Return needs a command; inserted text carries no modifiers")
        XCTAssertTrue(inputs.contains("f"), "Cmd-F opens find")
        XCTAssertTrue(inputs.contains("k"), "Cmd-K adds a link")
        XCTAssertFalse(inputs.contains(UIKeyCommand.inputUpArrow),
                       "arrows go through presses instead, so holding one repeats")

        // The keys that fight the enclosing scroll view take priority.
        for command in commands where command.input == UIKeyCommand.inputHome || command.input == "\t" {
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        }
    }

    // MARK: - handleNavigationCommand

    func testHomeAndEndMoveTheCaretToTheLineEdges() throws {
        let view = try makeView(["hello world"])
        cursor(view, 6)

        try send(view, UIKeyCommand.inputHome)
        XCTAssertEqual(view.editor.state.selection.head, 1, "Home goes to the line start")

        try send(view, UIKeyCommand.inputEnd)
        XCTAssertEqual(view.editor.state.selection.head, 12, "End goes to the line end")
    }

    func testShiftHomeExtendsTheSelection() throws {
        let view = try makeView(["hello world"])
        cursor(view, 6)
        try send(view, UIKeyCommand.inputHome, .shift)

        let sel = view.editor.state.selection
        XCTAssertFalse(sel.empty, "Shift-Home selects back to the line start")
        XCTAssertEqual(sel.from, 1)
        XCTAssertEqual(sel.to, 6)
    }

    func testArrowInputsRouteThroughTheSameHandler() throws {
        // Arrows aren't in `keyCommands`, but the handler still maps them — a
        // host that installs its own arrow command lands here.
        let view = try makeView(["hello world"])
        cursor(view, 6)
        try send(view, UIKeyCommand.inputLeftArrow)
        XCTAssertEqual(view.editor.state.selection.head, 5)
        try send(view, UIKeyCommand.inputRightArrow)
        XCTAssertEqual(view.editor.state.selection.head, 6)

        // Up/Down are mapped too; on a one-line document they run to the edges.
        try send(view, UIKeyCommand.inputDownArrow)
        XCTAssertEqual(view.editor.state.selection.head, 12, "Down from the only line goes to its end")
        try send(view, UIKeyCommand.inputUpArrow)
        XCTAssertEqual(view.editor.state.selection.head, 1, "Up from the only line goes to its start")
    }

    func testShiftReturnInsertsAHardBreak() throws {
        let view = try makeView(["ab"])
        cursor(view, 2)
        try send(view, "\r", .shift)

        var breaks = 0
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "hardBreak" { breaks += 1 }
            return true
        }
        XCTAssertEqual(breaks, 1)
    }

    func testTabIndentsAListItem() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func item(_ text: String) throws -> Node {
            try s.node("listItem", [:], content: Fragment.from([
                try s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
            ]))
        }
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("bulletList", [:], content: Fragment.from([try item("one"), try item("two")])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()

        // Caret in the second item, which can sink under the first.
        let secondItemText = view.editor.doc.content.size - 4
        cursor(view, secondItemText)
        try send(view, "\t")

        var depth = 0
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "bulletList" { depth += 1 }
            return true
        }
        XCTAssertEqual(depth, 2, "the item sank into a nested list")
    }

    func testAnUnmappedCommandInputIsIgnored() throws {
        let view = try makeView(["hello"])
        cursor(view, 3)
        try send(view, "q") // not a navigation key
        XCTAssertEqual(view.editor.state.selection.head, 3)
        XCTAssertEqual(view.editor.doc.textContent, "hello", "nothing was typed")
    }

    // MARK: - Key auto-repeat

    func testOnlyMovementAndDeletionKeysAutoRepeat() throws {
        let view = try makeView()
        for key in [UIKeyboardHIDUsage.keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow,
                    .keyboardDownArrow, .keyboardDeleteOrBackspace, .keyboardDeleteForward] {
            XCTAssertTrue(view.isAutoRepeatKey(key), "\(key) repeats when held")
        }
        for key in [UIKeyboardHIDUsage.keyboardA, .keyboardReturnOrEnter, .keyboardTab, .keyboardEscape] {
            XCTAssertFalse(view.isAutoRepeatKey(key), "\(key) does not repeat")
        }
    }

    func testHoldingAKeyRepeatsItAfterTheInitialDelay() throws {
        let view = try makeView(["abcdefghij"])
        cursor(view, 11) // end of the text
        view.startKeyRepeat(EditorTextView.KeyEvent(.keyboardLeftArrow))

        // Nothing yet — the first repeat waits out the initial delay.
        XCTAssertEqual(view.editor.state.selection.head, 11)

        let repeated = expectation(description: "the key repeated")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            repeated.fulfill()
        }
        wait(for: [repeated], timeout: 3)

        XCTAssertLessThan(view.editor.state.selection.head, 11, "held Left kept moving the caret")
        view.stopKeyRepeat()
    }

    func testReleasingTheKeyStopsTheRepeat() throws {
        let view = try makeView(["abcdefghij"])
        cursor(view, 11)
        view.startKeyRepeat(EditorTextView.KeyEvent(.keyboardLeftArrow))
        view.stopKeyRepeat(for: .keyboardLeftArrow)

        let settled = expectation(description: "settled")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            settled.fulfill()
        }
        wait(for: [settled], timeout: 3)

        XCTAssertEqual(view.editor.state.selection.head, 11, "the caret never moved")
    }

    func testReleasingADifferentKeyLeavesTheRepeatRunning() throws {
        let view = try makeView(["abcdefghij"])
        cursor(view, 11)
        view.startKeyRepeat(EditorTextView.KeyEvent(.keyboardLeftArrow))
        view.stopKeyRepeat(for: .keyboardRightArrow) // a key that isn't repeating

        let repeated = expectation(description: "still repeating")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            repeated.fulfill()
        }
        wait(for: [repeated], timeout: 3)

        XCTAssertLessThan(view.editor.state.selection.head, 11)
        view.stopKeyRepeat()
    }

    func testStartingASecondRepeatReplacesTheFirst() throws {
        let view = try makeView(["abcdefghij"])
        cursor(view, 6)
        view.startKeyRepeat(EditorTextView.KeyEvent(.keyboardLeftArrow))
        view.startKeyRepeat(EditorTextView.KeyEvent(.keyboardRightArrow))

        let repeated = expectation(description: "repeating")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            repeated.fulfill()
        }
        wait(for: [repeated], timeout: 3)

        XCTAssertGreaterThan(view.editor.state.selection.head, 6, "the second key won")
        view.stopKeyRepeat()
    }

    // MARK: - Edit menu

    func testSettingEditMenuItemsInstallsAndRemovesTheInteraction() throws {
        let view = try makeView()
        // UIKit's own text interaction already brings an edit-menu interaction,
        // so what matters is the one the editor adds on top of the baseline.
        func menuInteractions() -> Int {
            view.interactions.filter { $0 is UIEditMenuInteraction }.count
        }
        let baseline = menuInteractions()

        view.editMenuItems = { _ in [UIAction(title: "Custom") { _ in }] }
        XCTAssertEqual(menuInteractions(), baseline + 1, "the host's menu is installed")

        // Setting it again doesn't stack up a second interaction.
        view.editMenuItems = { _ in [] }
        XCTAssertEqual(menuInteractions(), baseline + 1)

        view.editMenuItems = nil
        XCTAssertEqual(menuInteractions(), baseline, "clearing it hands the menu back to the system")
    }

    func testTheCustomMenuIsBuiltFromTheHostsItems() throws {
        let view = try makeView()
        view.editMenuItems = { _ in [UIAction(title: "Explain") { _ in }] }
        let interaction = try XCTUnwrap(view.interactions.compactMap { $0 as? UIEditMenuInteraction }.first)

        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: 10, y: 10))
        let menu = view.editMenuInteraction(interaction, menuFor: configuration, suggestedActions: [])

        let titles = try XCTUnwrap(menu?.children.compactMap { ($0 as? UIAction)?.title })
        XCTAssertEqual(titles, ["Explain"])
    }

    // MARK: - Color picker

    /// Put the view in a window so the responder walk finds a view controller
    /// to present from. (The test bundle has no host app, so the presentation
    /// itself never completes — what is pinned here is the routing and the
    /// apply-on-dismiss behavior.)
    private func hosted(_ view: EditorTextView) -> UIViewController {
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.addSubview(view)
        return root
    }

    private func colorMark(_ view: EditorTextView, _ name: String) -> String? {
        var color: String?
        view.editor.doc.descendants { node, _, _, _ in
            if let mark = node.marks.first(where: { $0.type.name == name }) {
                color = mark.attrs["color"]?.stringValue
            }
            return true
        }
        return color
    }

    func testTextColorPickerAppliesItsChoiceOnDismiss() throws {
        let view = try makeView(["hello world"])
        _ = hosted(view)
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 1, 6)))

        view.formatTextColor(nil)
        let picker = UIColorPickerViewController()
        picker.selectedColor = .red
        view.colorPickerViewControllerDidFinish(picker)

        XCTAssertEqual(colorMark(view, "textColor"), "#ff0000",
                       "the picked color landed on the selection as a CSS hex")
    }

    func testBackgroundColorPickerTargetsTheHighlightMark() throws {
        let view = try makeView(["hello world"])
        _ = hosted(view)
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 1, 6)))

        view.formatBackgroundColor(nil)
        let picker = UIColorPickerViewController()
        picker.selectedColor = .blue
        view.colorPickerViewControllerDidFinish(picker)

        XCTAssertEqual(colorMark(view, "backgroundColor"), "#0000ff")
        XCTAssertNil(colorMark(view, "textColor"), "the text color was left alone")
    }

    func testColorPickerIsNotOfferedWithoutASelection() throws {
        let view = try makeView(["hello world"])
        let root = hosted(view)
        cursor(view, 3)
        view.formatTextColor(nil)
        XCTAssertNil(root.presentedViewController, "nothing to color, so nothing is presented")
    }

    func testCSSHexClampsAndFormats() {
        XCTAssertEqual(EditorTextView.cssHex(.red), "#ff0000")
        XCTAssertEqual(EditorTextView.cssHex(.black), "#000000")
        XCTAssertEqual(EditorTextView.cssHex(.white), "#ffffff")
        XCTAssertEqual(EditorTextView.cssHex(UIColor(red: 0.5, green: 0.25, blue: 0, alpha: 1)), "#804000")
        // Out-of-range components (extended sRGB) clamp rather than wrapping.
        XCTAssertEqual(EditorTextView.cssHex(UIColor(red: 2, green: -1, blue: 0.5, alpha: 1)), "#ff0080")
    }

    // MARK: - View overrides

    func testSizeThatFitsReportsTheDocumentHeight() throws {
        let view = try makeView(["one", "two", "three"])
        let fitted = view.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertEqual(fitted.width, 320, "the proposed width is kept")
        XCTAssertEqual(fitted.height, view.ensureLayout().height, accuracy: 0.5)
        XCTAssertEqual(view.intrinsicContentSize.height, fitted.height, accuracy: 0.5)
    }

    func testTheCaretBlinks() throws {
        let view = try makeView(["hello"])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()

        cursor(view, 3)
        XCTAssertTrue(view.becomeFirstResponder())

        let shapes = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? CAShapeLayer })
        XCTAssertFalse(shapes.isEmpty)
        let start = shapes.map(\.opacity)
        let blinked = expectation(description: "a layer changed opacity")
        Task { @MainActor in
            for _ in 0 ..< 25 {
                try? await Task.sleep(for: .milliseconds(100))
                if shapes.map(\.opacity) != start { break }
            }
            blinked.fulfill()
        }
        wait(for: [blinked], timeout: 6)
        XCTAssertNotEqual(shapes.map(\.opacity), start, "the blink timer toggled the caret")
    }
}
#endif
