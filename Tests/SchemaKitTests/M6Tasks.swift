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
        var checkedStates: [Bool] = []
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "taskItem" { checkedStates.append(node.attrs["checked"]?.boolValue ?? false) }
            return true
        }
        try expect(checkedStates.count >= 2, "expected >= 2 task items, got \(checkedStates.count)")
        // The original stays checked; the newly split item is unchecked.
        try expectEqual(checkedStates[0], true)
        try expectEqual(checkedStates[1], false, "a new task created by Enter must be unchecked")
    }

    test("toggleTaskList works inside a heading (converts to a task item)") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "Title")
        _ = editor.run("toggleHeading1") // make it a heading
        try expect(editor.isActive(node: "heading"))
        try expect(editor.run("toggleTaskList"), "toggleTaskList must apply inside a heading")
        try expect(editor.isActive(node: "taskItem"), "now inside a task item")
        // The heading became a paragraph inside the task item; text preserved.
        try expectEqual(editor.doc.textContent, "Title")
        var hasHeading = false
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "heading" { hasHeading = true }
            return true
        }
        try expect(!hasHeading, "the heading was converted to a paragraph")
    }

    test("toggleBulletList also works inside a heading") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "Title")
        _ = editor.run("toggleHeading1")
        try expect(editor.run("toggleBulletList"))
        try expect(editor.isActive(node: "listItem"))
        try expectEqual(editor.doc.textContent, "Title")
    }

    test("Enter mid-text in a checked task makes the lower item unchecked") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "abcdef")
        _ = editor.run("toggleTaskList")
        _ = editor.run("toggleTaskChecked")
        // Cursor in the middle of the text.
        var textStart = 0
        editor.doc.descendants { node, pos, _, _ in
            if node.isText { textStart = pos }
            return true
        }
        select(editor, textStart + 3, textStart + 3)
        for plugin in editor.state.plugins {
            if let h = plugin.props?.handleKeyDown, h("Enter", editor.state, { editor.dispatch($0) }) { break }
        }
        var checkedStates: [Bool] = []
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "taskItem" { checkedStates.append(node.attrs["checked"]?.boolValue ?? false) }
            return true
        }
        try expectEqual(checkedStates.count, 2)
        try expectEqual(checkedStates[0], true)
        try expectEqual(checkedStates[1], false, "the lower (new) item is unchecked")
    }
}
