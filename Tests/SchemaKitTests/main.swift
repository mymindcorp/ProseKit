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

registerM5Tests()
registerTaskTests()
registerTypographyTests()
registerSearchTests()
registerMarkdownShortcutTests()
registerEditorRevisionTests()

TestSuite.main("SchemaKitTests", collector.all)
