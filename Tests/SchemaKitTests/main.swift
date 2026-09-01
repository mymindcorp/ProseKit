import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) { collector.test(name, body) }

func makeEditor() throws -> Editor { try Editor(extensions: starterKit()) }

/// Type text into an empty editor at position 1.
func type(_ editor: Editor, _ text: String) throws {
    let tr = editor.state.tr
    try tr.insertText(text, 1)
    editor.dispatch(tr)
}

func select(_ editor: Editor, _ from: Int, _ to: Int) {
    editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, from, to)))
}

/// Drive a key through the editor's plugin keymaps.
func key(_ editor: Editor, _ k: String) -> Bool {
    for plugin in editor.state.plugins {
        if let h = plugin.props?.handleKeyDown, h(k, editor.state, { editor.dispatch($0) }) { return true }
    }
    return false
}

/// Drive a text-input through the editor's input-rule plugins.
func textInput(_ editor: Editor, at pos: Int, _ text: String) -> Bool {
    for plugin in editor.state.plugins {
        if let h = plugin.props?.handleTextInput, h(pos, pos, text, editor.state, { editor.dispatch($0) }) { return true }
    }
    return false
}

// MARK: - Schema building

test("ExtensionManager builds a schema from extensions") {
    let manager = try ExtensionManager(starterKit())
    try expectNotNil(manager.schema.nodes["doc"])
    try expectNotNil(manager.schema.nodes["paragraph"])
    try expectNotNil(manager.schema.nodes["heading"])
    try expectNotNil(manager.schema.nodes["bulletList"])
    try expectNotNil(manager.schema.marks["bold"])
    try expectNotNil(manager.schema.marks["italic"])
}

test("Editor initializes with a filled default document") {
    let editor = try makeEditor()
    try expect(editor.doc.childCount >= 1)
    try expectEqual(editor.doc.child(0).type.name, "paragraph")
}

// MARK: - Commands via named registry

test("named command toggleBold applies via Editor.run") {
    let editor = try makeEditor()
    try type(editor, "hello")
    select(editor, 1, 6)
    try expect(editor.run("toggleBold"))
    try expect(editor.isActive(mark: "bold"))
}

test("toggleHeading converts paragraph to heading and back") {
    let editor = try makeEditor()
    try type(editor, "Title")
    try expect(editor.run("toggleHeading2"))
    try expect(editor.isActive(node: "heading", attrs: ["level": .int(2)]))
    try expect(editor.run("toggleHeading2"))
    try expect(editor.isActive(node: "paragraph"))
}

test("toggleBulletList wraps the paragraph in a list") {
    let editor = try makeEditor()
    try type(editor, "item")
    try expect(editor.run("toggleBulletList"))
    try expect(editor.isActive(node: "bulletList"))
    try expect(editor.isActive(node: "listItem"))
}

// MARK: - Input rules + keymap wiring

test("'# ' input rule creates a heading through the plugin chain") {
    let editor = try makeEditor()
    try type(editor, "#")
    try expect(textInput(editor, at: 2, " "))
    try expect(editor.isActive(node: "heading"))
}

test("'- ' input rule creates a bullet list") {
    let editor = try makeEditor()
    try type(editor, "-")
    try expect(textInput(editor, at: 2, " "))
    try expect(editor.isActive(node: "bulletList"))
}

test("keymap Mod-b toggles bold through the plugin chain") {
    let editor = try makeEditor()
    try type(editor, "hello")
    select(editor, 1, 6)
    try expect(key(editor, "Mod-b"))
    try expect(editor.isActive(mark: "bold"))
}

// MARK: - History wired by default

test("undo via default Mod-z keymap") {
    let editor = try makeEditor()
    try type(editor, "abc")
    try expectEqual(editor.doc.textContent, "abc")
    try expect(key(editor, "Mod-z"))
    try expectEqual(editor.doc.textContent, "")
}

test("splitListItem on Enter inside a list creates a new item") {
    let editor = try makeEditor()
    try type(editor, "one")
    _ = editor.run("toggleBulletList")
    // Place the cursor at the end of "one", inside the list item's paragraph.
    var textEnd = 0
    editor.doc.descendants { node, pos, _, _ in
        if node.isText { textEnd = pos + node.nodeSize }
        return true
    }
    select(editor, textEnd, textEnd)
    _ = key(editor, "Enter")
    // Expect two list items now
    var listItems = 0
    editor.doc.descendants { node, _, _, _ in
        if node.type.name == "listItem" { listItems += 1 }
        return true
    }
    try expect(listItems >= 2, "expected at least two list items, got \(listItems)")
}

test("undoInputRule: Backspace right after an input rule reverts it") {
    let editor = try makeEditor()
    try type(editor, "#")
    try expect(textInput(editor, at: 2, " "))
    try expect(editor.isActive(node: "heading"))
    try expect(key(editor, "Backspace"))
    try expect(editor.isActive(node: "paragraph"))
    try expectEqual(editor.doc.textContent, "# ")
    // The rule state is consumed: a second Backspace must not revert again.
    // (Character deletion itself is the view's deleteBackward, not the keymap.)
    _ = key(editor, "Backspace")
    try expectEqual(editor.doc.textContent, "# ")
    try expect(editor.isActive(node: "paragraph"))
}

test("underline: toggleUnderline applies the mark") {
    let editor = try makeEditor()
    try type(editor, "hello")
    select(editor, 1, 6)
    try expect(editor.run("toggleUnderline"))
    try expect(editor.isActive(mark: "underline"))
    try expect(key(editor, "Mod-u")) // toggles back off
    try expect(!editor.isActive(mark: "underline"))
}

test("autolink: typing a space after a URL links it") {
    let editor = try makeEditor()
    try type(editor, "see https://x.dev")
    try expect(textInput(editor, at: editor.state.selection.head, " "))
    try expectEqual(editor.doc.textContent, "see https://x.dev ")
    try expect(editor.doc.rangeHasMark(5, 18, editor.schema.marks["link"]!))
    try expectEqual(editor.doc.nodeAt(5)?.marks.first?.attrs["href"]?.stringValue, "https://x.dev")
    // The typed space is not part of the link (the mark is inclusive: false).
    try expect(!editor.doc.rangeHasMark(18, 19, editor.schema.marks["link"]!))
}

test("autolink: www URLs get an https href") {
    let editor = try makeEditor()
    try type(editor, "www.x.com")
    try expect(textInput(editor, at: editor.state.selection.head, " "))
    try expectEqual(editor.doc.nodeAt(1)?.marks.first?.attrs["href"]?.stringValue, "https://www.x.com")
}

test("mention: @ query is tracked and accepting replaces it with a mention node") {
    let editor = try Editor(extensions: fullKit(mentionSuggestions: { q in
        ["jose", "jane"].filter { $0.hasPrefix(q) }
    }))
    try type(editor, "hi @jo")
    try expectEqual(editor.mentionSuggestion?.query, "jo")
    try expect(editor.acceptMentionSuggestion(id: "jose"))
    var mention: Node?
    editor.doc.descendants { n, _, _, _ in
        if n.type.name == "mention" { mention = n }
        return true
    }
    try expectEqual(mention?.attrs["id"]?.stringValue, "jose")
    try expect(editor.mentionSuggestion == nil) // query consumed
}

test("mention: @ mid-word doesn't trigger") {
    let editor = try Editor(extensions: fullKit(mentionSuggestions: { _ in [] }))
    try type(editor, "user@host")
    try expect(editor.mentionSuggestion == nil)
}

registerM5Tests()
registerTaskTests()
registerTaskSortTests()
registerTaskSortBench()
registerTypographyTests()
registerDetailsTests()
registerMathTests()
registerImageModelTests(); registerImageCommandTests()
registerImageModelMarkdownTests()
registerMathMLPasteTests()
registerMathEdgeCaseTests()
registerMarkdownImageTests()
registerMarkdownImageEdgeTests()
registerSearchTests()
registerMarkdownShortcutTests()
registerHighlightTests()
registerMarksParityTests()
registerIsActiveQueryTests()
registerEditorContentAPITests()
registerEditorRevisionTests()
registerEditorNotificationTests()
registerEditorHistoryIntegrationTests()
registerSlashMenuTests()
registerSlashMenuSourceTests()
registerWikiLinkAsyncTests()
registerSuggestionOffsetTests()
registerWikiLinkContextTests()
registerWikiLinkTargetIdTests()
registerCollabCursorTests()
registerUniqueIDTests()
registerFuzzTests()
registerSelectionFuzzTests()
registerTransformFuzzTests()
registerHistoryFuzzTests()
registerSerializationFuzzTests()
registerCollabFuzzTests()
registerPasteFuzzTests()
registerSuggestionFuzzTests()
registerTableFuzzTests()
registerMarkFuzzTests()
registerInputRuleFuzzTests()
registerDecorationFuzzTests()
registerSearchFuzzTests()
registerSelectionCommandFuzzTests()

registerPMListTests(); registerPMTableMapTests(); registerPMTableCommandsTests(); registerPMCellCopyPasteTests(); registerPMTableExtraTests()
registerPMTableMoveTests()
registerFootnoteTests(); registerPMColumnResizingTests(); registerTableOptionTests(); registerCellSelectionMappingTests()
registerSuggestionModeTests()
registerPolishCoverageTests()
registerFigureTests()

// Shared builders for the checklist-import tests below.
private let clSchema = try! makeFullEditor().schema
private func clNode(_ t: String, _ a: Attrs = [:], _ c: [Node] = []) -> Node {
    try! clSchema.node(t, a, content: Fragment.from(c))
}
private func clPara(_ s: String) -> Node { clNode("paragraph", [:], [clSchema.text(s)]) }
private func clItem(_ s: String, _ extra: [Node] = []) -> Node { clNode("listItem", [:], [clPara(s)] + extra) }

test("checklist import: bullet list with a checked line → task list") {
    // bulletList(li "milk", li "eggs", li "bread") with "milk" and "bread" checked
    let bl = clNode("bulletList", [:], [clItem("milk"), clItem("eggs"), clItem("bread")])
    let out = applyChecklistMarkers(Fragment.from([bl]), checkedTexts: ["milk", "bread"], schema: clSchema)
    let list = out.firstChild
    try expectEqual(list?.type.name, "taskList")
    try expectEqual(list?.childCount, 3)
    try expectEqual(list?.child(0).attrs["checked"]?.boolValue, true)   // milk
    try expectEqual(list?.child(1).attrs["checked"]?.boolValue, false)  // eggs
    try expectEqual(list?.child(2).attrs["checked"]?.boolValue, true)   // bread
    try expectEqual(list?.child(0).textContent, "milk")
}

test("checklist import: all-unchecked checklist (via proto lines) → task list") {
    let bl = clNode("bulletList", [:], [clItem("beta"), clItem("gamma")])
    // No checked items, but proto told us these are checklist lines.
    let out = applyChecklistMarkers(Fragment.from([bl]), checkedTexts: [],
                                    checklistLines: [("beta", false), ("gamma", false)], schema: clSchema)
    try expectEqual(out.firstChild?.type.name, "taskList")
    try expectEqual(out.firstChild?.child(0).attrs["checked"]?.boolValue, false)
    try expectEqual(out.firstChild?.child(1).attrs["checked"]?.boolValue, false)
}

test("checklist import: plain bullet list (no checked lines) is unchanged") {
    let bl = clNode("bulletList", [:], [clItem("a")])
    let out = applyChecklistMarkers(Fragment.from([bl]), checkedTexts: ["something else"], schema: clSchema)
    try expectEqual(out.firstChild?.type.name, "bulletList")
}

test("checklist import: duplicate item texts resolve positionally (proto lines)") {
    let bl = clNode("bulletList", [:], [clItem("call mom"), clItem("call mom")])
    let out = applyChecklistMarkers(Fragment.from([bl]), checkedTexts: [],
                                    checklistLines: [("call mom", true), ("call mom", false)], schema: clSchema)
    try expectEqual(out.firstChild?.type.name, "taskList")
    try expectEqual(out.firstChild?.child(0).attrs["checked"]?.boolValue, true)
    try expectEqual(out.firstChild?.child(1).attrs["checked"]?.boolValue, false)
}

test("checklist import: item with a nested plain sub-list still matches its line") {
    // Item text must be line-scoped: "milk" with a nested list must not become
    // "milksub" for matching, and the inner plain list must stay a bulletList.
    let nested = clNode("bulletList", [:], [clItem("sub")])
    let bl = clNode("bulletList", [:], [clItem("milk", [nested]), clItem("eggs")])
    let out = applyChecklistMarkers(Fragment.from([bl]), checkedTexts: ["milk", "eggs"], schema: clSchema)
    let list = out.firstChild
    try expectEqual(list?.type.name, "taskList")
    try expectEqual(list?.child(0).attrs["checked"]?.boolValue, true)
    try expectEqual(list?.child(0).child(1).type.name, "bulletList") // inner list untouched
}

test("checklist import: duplicate texts across nesting levels resolve in note order") {
    // Outer 'call mom' (unchecked, first line) with a nested 'call mom' (checked,
    // second line): consumption must follow document order, not recursion order.
    let nested = clNode("bulletList", [:], [clItem("call mom")])
    let bl = clNode("bulletList", [:], [clItem("call mom", [nested])])
    let out = applyChecklistMarkers(Fragment.from([bl]), checkedTexts: [],
                                    checklistLines: [("call mom", false), ("call mom", true)], schema: clSchema)
    let outer = out.firstChild
    try expectEqual(outer?.type.name, "taskList")
    try expectEqual(outer?.child(0).attrs["checked"]?.boolValue, false)
    try expectEqual(outer?.child(0).child(1).child(0).attrs["checked"]?.boolValue, true)
}

test("checklist import: blank row doesn't block conversion (proto lines)") {
    // The proto drops empty lines but the HTML keeps the empty <li>; it must not
    // defeat the all-items-match gate.
    let blank = clNode("listItem", [:], [clNode("paragraph")])
    let bl = clNode("bulletList", [:], [clItem("milk"), blank, clItem("bread")])
    let out = applyChecklistMarkers(Fragment.from([bl]), checkedTexts: [],
                                    checklistLines: [("milk", true), ("bread", false)], schema: clSchema)
    try expectEqual(out.firstChild?.type.name, "taskList")
    try expectEqual(out.firstChild?.child(0).attrs["checked"]?.boolValue, true)
    try expectEqual(out.firstChild?.child(1).attrs["checked"]?.boolValue, false)
    try expectEqual(out.firstChild?.child(2).attrs["checked"]?.boolValue, false)
}

test("checklist import: literal RTF marker prefixes normalize on both sides") {
    // "✓\tmilk" as item text vs "milk" as checked text — and the reverse.
    let bl = clNode("bulletList", [:], [clNode("listItem", [:], [clPara("✓\tmilk")])])
    let out = applyChecklistMarkers(Fragment.from([bl]), checkedTexts: ["milk"], schema: clSchema)
    try expectEqual(out.firstChild?.type.name, "taskList")
    try expectEqual(out.firstChild?.child(0).attrs["checked"]?.boolValue, true)

    let bl2 = clNode("bulletList", [:], [clItem("milk")])
    let out2 = applyChecklistMarkers(Fragment.from([bl2]), checkedTexts: ["☑\tmilk"], schema: clSchema)
    try expectEqual(out2.firstChild?.type.name, "taskList")
    try expectEqual(out2.firstChild?.child(0).attrs["checked"]?.boolValue, true)
}

test("checklist import: unrelated bullet list sharing one line text stays a bullet list") {
    // With full proto lines, a list converts only if ALL its items are checklist
    // lines — a coincidental "milk" in a plain list must not flip it.
    let checklist = clNode("bulletList", [:], [clItem("milk"), clItem("bread")])
    let plain = clNode("bulletList", [:], [clItem("milk"), clItem("apples")])
    let out = applyChecklistMarkers(Fragment.from([checklist, plain]), checkedTexts: [],
                                    checklistLines: [("milk", true), ("bread", false)], schema: clSchema)
    try expectEqual(out.firstChild?.type.name, "taskList")
    try expectEqual(out.firstChild?.child(0).attrs["checked"]?.boolValue, true)
    try expectEqual(out.child(1).type.name, "bulletList")
}

TestSuite.main("SchemaKitTests", collector.all)
