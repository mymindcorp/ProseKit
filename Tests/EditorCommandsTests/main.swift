import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorHistory
import EditorKeymap
import EditorInputRules
import TestHarness

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) { collector.test(name, body) }

/// Run a command on a state, returning the resulting state (or nil if it didn't apply).
func apply(_ command: Command, _ state: EditorState) -> EditorState? {
    var result: EditorState? = nil
    let did = command(state, { tr in result = state.apply(tr) }, nil)
    return did ? (result ?? state) : nil
}

// MARK: - Core commands

test("deleteSelection removes the selected range") {
    let state = B.state(B.doc(B.p("hello")), anchor: 1, head: 6)
    let out = apply(deleteSelection, state)
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.p("")))
}

test("moveBlock moves a top-level block down") {
    let state = B.state(B.doc(B.p("A"), B.p("B"), B.p("C")))
    let out = apply(moveBlock(0, 3), state) // A to the end
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.p("B"), B.p("C"), B.p("A")))
}

test("moveBlock moves a top-level block up") {
    let state = B.state(B.doc(B.p("A"), B.p("B"), B.p("C")))
    let out = apply(moveBlock(2, 0), state) // C to the front
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.p("C"), B.p("A"), B.p("B")))
}

test("moveBlock into the middle") {
    let state = B.state(B.doc(B.p("A"), B.p("B"), B.p("C"), B.p("D")))
    let out = apply(moveBlock(3, 1), state) // D before B
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.p("A"), B.p("D"), B.p("B"), B.p("C")))
}

test("moveBlock is a no-op for adjacent gaps") {
    let state = B.state(B.doc(B.p("A"), B.p("B"), B.p("C")))
    try expectNil(apply(moveBlock(1, 1), state)) // gap before itself
    try expectNil(apply(moveBlock(1, 2), state)) // gap right after itself
    try expectNil(apply(moveBlock(5, 0), state)) // out of range
}

test("joinBackward merges paragraph into previous") {
    let state = B.state(B.doc(B.p("foo"), B.p("bar")), anchor: 6) // cursor at start of "bar"
    let out = apply(joinBackward, state)
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.p("foobar")))
}

test("joinBackward lifts paragraph out of blockquote at its start") {
    let state = B.state(B.doc(B.blockquote(B.p("hi"))), anchor: 2)
    let out = apply(joinBackward, state)
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.p("hi")))
}

test("splitBlock splits a paragraph at the cursor") {
    let state = B.state(B.doc(B.p("hello")), anchor: 3) // he|llo
    let out = apply(splitBlock, state)
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.p("he"), B.p("llo")))
}

test("splitBlock at end of heading creates a paragraph") {
    let state = B.state(B.doc(B.h(1, B.t("Title"))), anchor: 6)
    let out = apply(splitBlock, state)
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.h(1, B.t("Title")), B.p("")))
}

test("liftEmptyBlock lifts an empty paragraph out of a blockquote") {
    let state = B.state(B.doc(B.blockquote(B.p(""))), anchor: 2)
    let out = apply(liftEmptyBlock, state)
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.p("")))
}

test("newlineInCode inserts a newline in a code block") {
    let state = B.state(B.doc(B.codeBlock("ab")), anchor: 3)
    let out = apply(newlineInCode, state)
    try expectNotNil(out)
    try expectEqual(out!.doc.textContent, "ab\n")
}

test("toggleMark adds and removes bold") {
    let state = B.state(B.doc(B.p("hello")), anchor: 1, head: 6)
    let bolded = apply(toggleMark(B.bold), state)
    try expectNotNil(bolded)
    try expectEqual(bolded!.doc, B.doc(B.p(B.strong("hello"))))
    // toggling again removes it
    let unbolded = apply(toggleMark(B.bold), bolded!)
    try expectNotNil(unbolded)
    try expectEqual(unbolded!.doc, B.doc(B.p("hello")))
}

test("toggleMark on empty selection sets a stored mark") {
    let state = B.state(B.doc(B.p("hi")), anchor: 2)
    let out = apply(toggleMark(B.bold), state)
    try expectNotNil(out)
    try expectEqual(out!.storedMarks?.count, 1)
}

test("setBlockType converts paragraph to heading") {
    let state = B.state(B.doc(B.p("Title")), anchor: 3)
    let out = apply(setBlockType(B.type("heading"), ["level": .int(2)]), state)
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.h(2, B.t("Title"))))
}

test("wrapIn wraps the selection in a blockquote") {
    let state = B.state(B.doc(B.p("hi")), anchor: 2)
    let out = apply(wrapIn(B.type("blockquote")), state)
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.blockquote(B.p("hi"))))
}

test("selectAll selects the whole doc") {
    let state = B.state(B.doc(B.p("a"), B.p("b")))
    let out = apply(selectAll, state)
    try expectNotNil(out)
    try expect(out!.selection is AllSelection)
}

test("chainCommands runs until one applies") {
    let state = B.state(B.doc(B.p("foo"), B.p("bar")), anchor: 6)
    let combined = chainCommands(deleteSelection, joinBackward)
    let out = apply(combined, state)
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.p("foobar")))
}

// MARK: - History

test("undo reverts a change, redo re-applies it") {
    let state = B.state(B.doc(B.p("hello")), anchor: 6, plugins: [history()])
    // type "!"
    let tr = state.tr
    try tr.insertText("!", 6)
    let typed = state.apply(tr)
    try expectEqual(typed.doc, B.doc(B.p("hello!")))

    var undone: EditorState? = nil
    _ = undo(typed) { undone = typed.apply($0) }
    try expectNotNil(undone)
    try expectEqual(undone!.doc, B.doc(B.p("hello")))

    var redone: EditorState? = nil
    _ = redo(undone!) { redone = undone!.apply($0) }
    try expectNotNil(redone)
    try expectEqual(redone!.doc, B.doc(B.p("hello!")))
}

test("undo restores the selection") {
    let state = B.state(B.doc(B.p("hello")), anchor: 1, head: 6, plugins: [history()])
    let tr = state.tr.setSelection(TextSelection.create(state.doc, 1, 6))
    tr.deleteSelection()
    let deleted = state.apply(tr)
    try expectEqual(deleted.doc, B.doc(B.p("")))
    var undone: EditorState? = nil
    _ = undo(deleted) { undone = deleted.apply($0) }
    try expectNotNil(undone)
    try expectEqual(undone!.doc, B.doc(B.p("hello")))
}

// MARK: - Keymap

test("keymap dispatches a bound command") {
    let km = keymap(["Mod-a": selectAll])
    let state = B.state(B.doc(B.p("hi")), plugins: [km])
    var handled = false
    var newState: EditorState? = nil
    if let handler = km.props?.handleKeyDown {
        handled = handler("Mod-a", state) { newState = state.apply($0) }
    }
    try expect(handled)
    try expect(newState!.selection is AllSelection)
}

// MARK: - Input rules

test("textblockTypeInputRule turns '# ' into a heading") {
    let rule = textblockTypeInputRule("^(#{1,6})\\s$", B.type("heading")) { m in
        ["level": .int((m[1] ?? "").count)]
    }
    let plugin = inputRules([rule])
    let state = B.state(B.doc(B.p("#")), anchor: 2, plugins: [plugin])
    var out: EditorState? = nil
    if let handler = plugin.props?.handleTextInput {
        _ = handler(2, 2, " ", state) { out = state.apply($0) }
    }
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.h(1)))
}

test("wrappingInputRule turns '- ' into a bullet list") {
    let rule = wrappingInputRule("^\\s*([-+*])\\s$", B.type("bulletList"))
    let plugin = inputRules([rule])
    let state = B.state(B.doc(B.p("-")), anchor: 2, plugins: [plugin])
    var out: EditorState? = nil
    if let handler = plugin.props?.handleTextInput {
        _ = handler(2, 2, " ", state) { out = state.apply($0) }
    }
    try expectNotNil(out)
    try expectEqual(out!.doc, B.doc(B.ul(B.li(B.p("")))))
}

registerPMCommandsTests(); registerPMHistoryTests(); registerPMKeymapTests(); registerPMInputRulesTests()

TestSuite.main("EditorCommandsTests", collector.all)
