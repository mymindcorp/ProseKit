import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// Registered into the shared `collector` from main.swift.

func registerTaskTests() {
    test("task toggle: a selected task item is the target, including nested items") {
        for nested in [false, true] {
            let editor = try Editor(extensions: fullKit())
            let s = editor.schema
            let paragraph = try s.node("paragraph", content: Fragment.from(s.text("task")))
            let item = try s.node("taskItem", content: Fragment.from(paragraph))
            let innerList = try s.node("taskList", content: Fragment.from(item))
            let list = nested ? try s.node("taskList", content: Fragment.from(s.node("taskItem", content: Fragment.from([paragraph, innerList])))) : innerList
            editor.setContent(try s.node("doc", content: Fragment.from(list)))
            var positions: [Int] = []
            editor.doc.descendants { node, pos, _, _ in
                if node.type.name == "taskItem" { positions.append(pos) }
                return true
            }
            editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, positions.last!)))
            try expect(editor.run("toggleTaskChecked"))
            try expectEqual(editor.doc.nodeAt(positions.last!)?.attrs["checked"], .bool(true))
            if nested { try expectEqual(editor.doc.nodeAt(positions[0])?.attrs["checked"], .bool(false)) }
            try expect(editor.run("toggleTaskChecked"))
            try expectEqual(editor.doc.nodeAt(positions.last!)?.attrs["checked"], .bool(false))
            try editor.doc.check()
        }
    }

    test("task input rule: checked markers create checked items") {
        for marker in ["[x]", "[X]"] {
            let editor = try Editor(extensions: fullKit())
            try type(editor, marker)
            try expect(textInput(editor, at: marker.count + 1, " "))
            try expectEqual(editor.attributes(ofNode: "taskItem")?["checked"], .bool(true))
        }
    }

    test("task input rule: joining a checked item preserves its state and can be undone") {
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: "<ul data-type=\"taskList\"><li data-type=\"taskItem\" data-checked=\"false\"><p>old</p></li></ul><p>[x]</p>")
        let end = editor.doc.content.size - 1
        select(editor, end, end)
        try expect(textInput(editor, at: end, " "))
        try expectEqual(editor.doc.childCount, 1)
        let list = editor.doc.firstChild!
        try expectEqual(list.childCount, 2)
        try expectEqual(list.child(0).attrs["checked"], .bool(false))
        try expectEqual(list.child(1).attrs["checked"], .bool(true))
        try expect(key(editor, "Backspace"))
        try expectEqual(editor.doc.childCount, 2)
        try expectEqual(editor.doc.lastChild?.textContent, "[x] ")
        try expectEqual(editor.doc.firstChild?.childCount, 1)
        try editor.doc.check()
    }

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
