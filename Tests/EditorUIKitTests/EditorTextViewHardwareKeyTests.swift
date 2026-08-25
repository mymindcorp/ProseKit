#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// `UIKey` and `UIPress` have no public initializers — which is why the view
/// carries its own `KeyEvent` struct — but both are `open`, so a subclass can
/// report scripted values. That reaches the press handlers themselves, which
/// nothing else can drive: the translation from a hardware press to a
/// `KeyEvent`, the "consume it or pass it up" decision, and the auto-repeat
/// they arm.
private final class FakeKey: UIKey {
    private let code: UIKeyboardHIDUsage
    private let mods: UIKeyModifierFlags
    private let chars: String
    init(_ code: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags = [], characters: String = "") {
        self.code = code
        self.mods = modifiers
        self.chars = characters
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var keyCode: UIKeyboardHIDUsage { code }
    override var modifierFlags: UIKeyModifierFlags { mods }
    override var charactersIgnoringModifiers: String { chars }
    override var characters: String { chars }
}

private final class FakePress: UIPress {
    private let fakeKey: UIKey?
    init(_ key: UIKey?) {
        self.fakeKey = key
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var key: UIKey? { fakeKey }
}

@MainActor
final class EditorTextViewHardwareKeyTests: XCTestCase {
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

    private func press(_ view: EditorTextView, _ code: UIKeyboardHIDUsage,
                       _ mods: UIKeyModifierFlags = [], _ chars: String = "") -> FakePress {
        let press = FakePress(FakeKey(code, modifiers: mods, characters: chars))
        view.pressesBegan([press], with: nil)
        return press
    }

    // MARK: - pressesBegan

    func testAnArrowPressMovesTheCaret() throws {
        let view = try makeView(["hello world"])
        cursor(view, 6)
        _ = press(view, .keyboardLeftArrow)
        XCTAssertEqual(view.editor.state.selection.head, 5)
        view.stopKeyRepeat()
    }

    func testShiftArrowExtendsTheSelection() throws {
        let view = try makeView(["hello world"])
        cursor(view, 6)
        _ = press(view, .keyboardRightArrow, .shift)
        let sel = view.editor.state.selection
        XCTAssertFalse(sel.empty)
        XCTAssertEqual(sel.to, 7)
        view.stopKeyRepeat()
    }

    func testBackspacePressDeletesBackwards() throws {
        let view = try makeView(["abc"])
        cursor(view, 4)
        _ = press(view, .keyboardDeleteOrBackspace)
        XCTAssertEqual(view.editor.doc.textContent, "ab")
        view.stopKeyRepeat()
    }

    func testSeveralKeysInOnePressSetAreAllHandled() throws {
        let view = try makeView(["abcdef"])
        cursor(view, 7)
        let a = FakePress(FakeKey(.keyboardLeftArrow))
        let b = FakePress(FakeKey(.keyboardLeftArrow))
        view.pressesBegan([a, b], with: nil)
        XCTAssertEqual(view.editor.state.selection.head, 5, "both presses moved the caret")
        view.stopKeyRepeat()
    }

    func testAPressWithNoKeyIsPassedUp() throws {
        let view = try makeView(["abc"])
        cursor(view, 2)
        // A press carrying no key (e.g. a game-controller button) is not ours.
        view.pressesBegan([FakePress(nil)], with: nil)
        XCTAssertEqual(view.editor.doc.textContent, "abc")
        XCTAssertEqual(view.editor.state.selection.head, 2)
    }

    func testAnUnhandledKeyIsPassedUpUntouched() throws {
        let view = try makeView(["abc"])
        cursor(view, 2)
        // F5 means nothing to the editor; it must reach super rather than being
        // swallowed.
        view.pressesBegan([FakePress(FakeKey(.keyboardF5))], with: nil)
        XCTAssertEqual(view.editor.doc.textContent, "abc")
        XCTAssertEqual(view.editor.state.selection.head, 2)
    }

    // MARK: - Auto-repeat armed by a press

    func testHoldingAnArrowKeepsMovingTheCaret() throws {
        let view = try makeView(["abcdefghij"])
        cursor(view, 11)
        _ = press(view, .keyboardLeftArrow)
        let afterFirst = view.editor.state.selection.head
        XCTAssertEqual(afterFirst, 10, "the press itself moves once")

        let repeated = expectation(description: "the held key repeated")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            repeated.fulfill()
        }
        wait(for: [repeated], timeout: 3)

        XCTAssertLessThan(view.editor.state.selection.head, afterFirst, "and keeps going while held")
        view.stopKeyRepeat()
    }

    func testANonRepeatingKeyArmsNothing() throws {
        let view = try makeView(["ab"])
        cursor(view, 3)
        // Return splits the block; holding it must not keep splitting.
        _ = press(view, .keyboardReturnOrEnter)
        let blocks = view.editor.doc.childCount

        let settled = expectation(description: "settled")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            settled.fulfill()
        }
        wait(for: [settled], timeout: 3)

        XCTAssertEqual(view.editor.doc.childCount, blocks, "no repeat was armed")
    }

    // MARK: - pressesEnded / pressesCancelled

    func testReleasingTheKeyEndsTheRepeat() throws {
        let view = try makeView(["abcdefghij"])
        cursor(view, 11)
        let held = press(view, .keyboardLeftArrow)
        let afterPress = view.editor.state.selection.head

        view.pressesEnded([held], with: nil)

        let settled = expectation(description: "settled")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            settled.fulfill()
        }
        wait(for: [settled], timeout: 3)

        XCTAssertEqual(view.editor.state.selection.head, afterPress, "the caret stopped when the key came up")
    }

    func testCancellingThePressEndsTheRepeat() throws {
        let view = try makeView(["abcdefghij"])
        cursor(view, 11)
        let held = press(view, .keyboardLeftArrow)
        let afterPress = view.editor.state.selection.head

        view.pressesCancelled([held], with: nil)

        let settled = expectation(description: "settled")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            settled.fulfill()
        }
        wait(for: [settled], timeout: 3)

        XCTAssertEqual(view.editor.state.selection.head, afterPress)
    }

    func testReleasingAPressWithNoKeyIsHarmless() throws {
        let view = try makeView(["abc"])
        view.pressesEnded([FakePress(nil)], with: nil)
        XCTAssertEqual(view.editor.doc.textContent, "abc")
    }
}
#endif
