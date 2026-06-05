import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// Registered into the shared `collector` from main.swift.

func registerTaskTests() {
    test("taskList: schema has taskList + taskItem with checked attr") {
        let editor = try Editor(extensions: fullKit())
        try expectNotNil(editor.schema.nodes["taskList"])
        let item = editor.schema.nodes["taskItem"]
        try expectNotNil(item)
        try expectEqual(item?.defaultAttrs["checked"], .bool(false))
    }

    test("toggleTaskList wraps the paragraph in a task list") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "todo")
        try expect(editor.run("toggleTaskList"))
        try expect(editor.isActive(node: "taskList"))
        try expect(editor.isActive(node: "taskItem"))
    }

    test("toggleTaskChecked flips the checked attribute") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "task")
        _ = editor.run("toggleTaskList")
        // initially unchecked
        try expect(!(editor.attributes(ofNode: "taskItem")?["checked"]?.boolValue ?? false))
        try expect(editor.run("toggleTaskChecked"))
        try expectEqual(editor.attributes(ofNode: "taskItem")?["checked"], .bool(true))
        try expect(editor.run("toggleTaskChecked"))
        try expectEqual(editor.attributes(ofNode: "taskItem")?["checked"], .bool(false))
    }

    test("Enter splits a task item into a new (unchecked) item") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "first")
        _ = editor.run("toggleTaskList")
        _ = editor.run("toggleTaskChecked") // check the first item
        // cursor at end of "first"
        var textEnd = 0
        editor.doc.descendants { node, pos, _, _ in
            if node.isText { textEnd = pos + node.nodeSize }
            return true
        }
        select(editor, textEnd, textEnd)
        // press Enter via the item's keymap (splitListItem)
        var handled = false
        for plugin in editor.state.plugins {
            if let h = plugin.props?.handleKeyDown, h("Enter", editor.state, { editor.dispatch($0) }) { handled = true; break }
        }
        try expect(handled)
        var items = 0
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "taskItem" { items += 1 }
            return true
        }
        try expect(items >= 2, "expected >= 2 task items, got \(items)")
    }
}
