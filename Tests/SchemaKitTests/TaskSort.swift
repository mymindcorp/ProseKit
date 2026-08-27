import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorHistory
import SchemaKit
import TestHarness

// Checking a task drops it to the bottom of its list; unchecking it puts it
// back where it came from. Off unless asked for.

private func sortingEditor(_ items: [(String, Bool)], sorting: Bool = true) throws -> Editor {
    let editor = try Editor(extensions: fullKit(
        taskListOptions: TaskListOptions(sortCompletedToBottom: sorting)))
    let lis = items.map { text, checked in
        "<li data-type=\"taskItem\" data-checked=\"\(checked)\"><p>\(text)</p></li>"
    }.joined()
    try editor.setContent(html: "<ul data-type=\"taskList\">\(lis)</ul>")
    return editor
}

/// The list as (text, checked) pairs, in document order.
private func tasks(_ editor: Editor) -> [(String, Bool)] {
    var out: [(String, Bool)] = []
    editor.doc.descendants { node, _, _, _ in
        if node.type.name == "taskItem" {
            out.append((node.textContent, node.attrs["checked"]?.boolValue ?? false))
        }
        return true
    }
    return out
}

private func texts(_ editor: Editor) -> [String] { tasks(editor).map(\.0) }
private func checks(_ editor: Editor) -> [Bool] { tasks(editor).map(\.1) }

/// The document position of the nth task item.
private func itemPos(_ editor: Editor, _ index: Int) -> Int {
    var positions: [Int] = []
    editor.doc.descendants { node, pos, _, _ in
        if node.type.name == "taskItem" { positions.append(pos) }
        return true
    }
    return positions[index]
}

/// Check or uncheck the nth item the way the checkbox overlay does.
private func setChecked(_ editor: Editor, _ index: Int, _ checked: Bool) {
    let tr = editor.state.tr
    _ = try? tr.setNodeAttribute(itemPos(editor, index), "checked", .bool(checked))
    editor.dispatch(tr)
}

/// Check several items the way one paste or one collab step would: a single
/// transaction carrying more than one `checked` attr step.
private func setCheckedTogether(_ editor: Editor, _ changes: [(Int, Bool)]) {
    let tr = editor.state.tr
    for (index, checked) in changes {
        _ = try? tr.setNodeAttribute(itemPos(editor, index), "checked", .bool(checked))
    }
    editor.dispatch(tr)
}

/// Two outer items, each holding a nested list of two.
private func nestedEditor() throws -> Editor {
    let editor = try Editor(extensions: fullKit(
        taskListOptions: TaskListOptions(sortCompletedToBottom: true)))
    func outer(_ name: String, _ a: String, _ b: String) -> String {
        """
        <li data-type="taskItem" data-checked="false"><p>\(name)</p>\
        <ul data-type="taskList">\
        <li data-type="taskItem" data-checked="false"><p>\(a)</p></li>\
        <li data-type="taskItem" data-checked="false"><p>\(b)</p></li>\
        </ul></li>
        """
    }
    try editor.setContent(html: "<ul data-type=\"taskList\">"
        + outer("A", "a1", "a2") + outer("B", "b1", "b2") + "</ul>")
    return editor
}

func registerTaskSortTests() {
    test("task sort: off by default — checking leaves the item where it is") {
        let editor = try sortingEditor([("a", false), ("b", false), ("c", false)], sorting: false)
        setChecked(editor, 1, true)
        try expectEqual(texts(editor), ["a", "b", "c"])
        try expectEqual(checks(editor), [false, true, false])
        // And the schema carries nothing extra either way.
        try expectEqual(editor.schema.nodes["taskItem"]?.defaultAttrs.count, 1)
    }

    test("task sort: a checked item drops to the bottom") {
        let editor = try sortingEditor([("a", false), ("b", false), ("c", false)])
        setChecked(editor, 0, true)
        try expectEqual(texts(editor), ["b", "c", "a"])
        try expectEqual(checks(editor), [false, false, true])
    }

    test("task sort: unchecking sends it back where it was") {
        let editor = try sortingEditor([("a", false), ("b", false), ("c", false)])
        setChecked(editor, 0, true)
        try expectEqual(texts(editor), ["b", "c", "a"])
        setChecked(editor, 2, false)
        try expectEqual(texts(editor), ["a", "b", "c"])
        try expectEqual(checks(editor), [false, false, false])
    }

    test("task sort: the last item checked sits below the ones checked before it") {
        let editor = try sortingEditor([("a", false), ("b", false), ("c", false), ("d", false)])
        setChecked(editor, 1, true)                 // b down
        try expectEqual(texts(editor), ["a", "c", "d", "b"])
        setChecked(editor, 0, true)                 // a down, below b
        try expectEqual(texts(editor), ["c", "d", "b", "a"])
        // Each comes home to its own place.
        setChecked(editor, 3, false)                // a
        try expectEqual(texts(editor), ["a", "c", "d", "b"])
        setChecked(editor, 3, false)                // b
        try expectEqual(texts(editor), ["a", "b", "c", "d"])
    }

    test("task sort: an item checked at the bottom doesn't move") {
        let editor = try sortingEditor([("a", false), ("b", false)])
        setChecked(editor, 1, true)
        try expectEqual(texts(editor), ["a", "b"])
        try expectEqual(checks(editor), [false, true])
        setChecked(editor, 1, false)
        try expectEqual(texts(editor), ["a", "b"])
    }

    test("task sort: items checked before the option was on are treated as sorted") {
        let editor = try sortingEditor([("a", false), ("b", false), ("c", true)])
        setChecked(editor, 0, true)
        try expectEqual(texts(editor), ["b", "c", "a"])
        setChecked(editor, 2, false)
        try expectEqual(texts(editor), ["a", "b", "c"])
    }

    test("task sort: home is remembered across the items that moved before it") {
        // Checking b then c and unchecking c must leave c above b, not below.
        let editor = try sortingEditor([("a", false), ("b", false), ("c", false)])
        setChecked(editor, 1, true)                 // a c b
        setChecked(editor, 1, true)                 // a b c  (c checked, below b)
        try expectEqual(texts(editor), ["a", "b", "c"])
        try expectEqual(checks(editor), [false, true, true])
        setChecked(editor, 2, false)                // c comes home: above the checked b
        try expectEqual(texts(editor), ["a", "c", "b"])
        try expectEqual(checks(editor), [false, false, true])
    }

    test("task sort: undo takes back the check and the move together") {
        let editor = try sortingEditor([("a", false), ("b", false), ("c", false)])
        setChecked(editor, 0, true)
        try expectEqual(texts(editor), ["b", "c", "a"])
        try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
        try expectEqual(texts(editor), ["a", "b", "c"])
        try expectEqual(checks(editor), [false, false, false])
        try expect(EditorHistory.redo(editor.state, { editor.dispatch($0) }))
        try expectEqual(texts(editor), ["b", "c", "a"])
        try expectEqual(checks(editor), [false, false, true])
    }

    test("task sort: the caret stays in the text it was in") {
        let editor = try sortingEditor([("aaa", false), ("bbb", false), ("ccc", false)])
        // Put the caret inside "aaa", two characters in.
        let textPos = itemPos(editor, 0) + 2      // item + paragraph opening
        select(editor, textPos + 2, textPos + 2)
        try expectEqual(editor.state.selection.resolvedFrom.parent.textContent, "aaa")
        setChecked(editor, 0, true)
        try expectEqual(texts(editor), ["bbb", "ccc", "aaa"])
        let head = editor.state.selection.resolvedFrom
        try expectEqual(head.parent.textContent, "aaa", "the caret rode along with its item")
        try expectEqual(head.parentOffset, 2)
    }

    test("task sort: nested task lists sort on their own") {
        let editor = try Editor(extensions: fullKit(
            taskListOptions: TaskListOptions(sortCompletedToBottom: true)))
        try editor.setContent(html: """
        <ul data-type="taskList">\
        <li data-type="taskItem" data-checked="false"><p>outer</p>\
        <ul data-type="taskList">\
        <li data-type="taskItem" data-checked="false"><p>inner1</p></li>\
        <li data-type="taskItem" data-checked="false"><p>inner2</p></li>\
        </ul></li>\
        <li data-type="taskItem" data-checked="false"><p>last</p></li>\
        </ul>
        """)
        try expectEqual(texts(editor), ["outerinner1inner2", "inner1", "inner2", "last"])
        setChecked(editor, 1, true)   // inner1
        try expectEqual(texts(editor).filter { $0 == "inner1" || $0 == "inner2" || $0 == "last" },
                        ["inner2", "inner1", "last"])
        try expectEqual(checks(editor)[0], false, "the outer item is untouched")
    }


    test("task sort: one batch checking an item and its own child keeps every item") {
        let editor = try nestedEditor()
        // A (index 0) and its own child a1 (index 1), in one transaction.
        setCheckedTogether(editor, [(0, true), (1, true)])
        let leaves = texts(editor).filter { $0.count == 2 }
        try expectEqual(leaves.sorted(), ["a1", "a2", "b1", "b2"],
                        "no item is lost, and none is duplicated")
        // A drops below B; inside A, the checked a1 drops below a2.
        try expectEqual(leaves, ["b1", "b2", "a2", "a1"])
        try expectEqual(checks(editor).filter { $0 }.count, 2, "only A and a1 are checked")
    }

    test("task sort: sorting an outer list carries the inner sort with it") {
        let editor = try nestedEditor()
        setChecked(editor, 1, true)     // a1, inside A
        try expectEqual(texts(editor).filter { $0.count == 2 }, ["a2", "a1", "b1", "b2"])
        setChecked(editor, 0, true)     // now A itself
        try expectEqual(texts(editor).filter { $0.count == 2 }, ["b1", "b2", "a2", "a1"],
                        "A moves below B and keeps a2/a1 in the order it had")
    }

    test("task sort: a nested item still remembers its home after its parent moves") {
        let editor = try nestedEditor()
        setChecked(editor, 1, true)     // a1 -> bottom of its list
        try expectEqual(texts(editor).filter { $0.count == 2 }, ["a2", "a1", "b1", "b2"])
        setChecked(editor, 0, true)     // A moves; a1's home must travel with it
        setChecked(editor, 5, false)    // uncheck a1 where it now stands
        try expectEqual(texts(editor).filter { $0.count == 2 }, ["b1", "b2", "a1", "a2"],
                        "a1 goes back above a2, where it started")
    }

    test("task sort: an ordinary edit appends nothing") {
        let editor = try sortingEditor([("a", false), ("b", true)])
        var appended = 0
        editor.onTransaction = { tr in if tr.getMeta("appendedTransaction") != nil { appended += 1 } }
        let tr = editor.state.tr
        try tr.insertText("x", itemPos(editor, 0) + 2)
        editor.dispatch(tr)
        try expectEqual(appended, 0, "typing must not cost a reorder")
        try expectEqual(texts(editor), ["xa", "b"])
    }

    test("task sort: the remembered index never reaches the document") {
        let editor = try sortingEditor([("a", false), ("b", false)])
        setChecked(editor, 0, true)
        // The document says what it always said; the home lives in plugin state.
        try expectEqual(editor.getHTML(), "<ul data-type=\"taskList\">"
            + "<li data-type=\"taskItem\" data-checked=\"false\"><input type=\"checkbox\"><p>b</p></li>"
            + "<li data-type=\"taskItem\" data-checked=\"true\"><input type=\"checkbox\" checked=\"checked\">"
            + "<p>a</p></li></ul>")
        try expectEqual(editor.schema.nodes["taskItem"]?.defaultAttrs.count, 1)
        try expectEqual(taskSortKey.getState(editor.state)?.count, 1, "one item away from home")
    }

    test("task sort: a home that no longer exists lands at the end of the unchecked items") {
        let editor = try sortingEditor([("a", false), ("b", false), ("c", false)])
        setChecked(editor, 2, true)                 // c down (it was already last)
        setChecked(editor, 1, true)                 // b down, below c
        try expectEqual(texts(editor), ["a", "c", "b"])
        // Delete "a", so b's remembered index (1) is past the end of what's left.
        let a = itemPos(editor, 0)
        let tr = editor.state.tr
        try tr.delete(a, a + editor.doc.nodeAt(a)!.nodeSize)
        editor.dispatch(tr)
        setChecked(editor, 1, false)                // b comes home
        try expectEqual(texts(editor), ["b", "c"])
        try expectEqual(checks(editor), [false, true])
    }

    test("task sort: a checkbox tap sorts inside its own transaction") {
        let editor = try sortingEditor([("a", false), ("b", false), ("c", false)])
        var dispatched = 0
        editor.onTransaction = { _ in dispatched += 1 }
        // `setTaskChecked` is what the checkbox overlay dispatches.
        let tr = setTaskChecked(editor.state, pos: itemPos(editor, 0), checked: true)
        try expectNotNil(tr)
        editor.dispatch(tr!)
        try expectEqual(texts(editor), ["b", "c", "a"])
        try expectEqual(dispatched, 1, "the move rides along, it doesn't cost a second transaction")
        // And it's one undo, not two.
        try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
        try expectEqual(texts(editor), ["a", "b", "c"])
        try expectEqual(checks(editor), [false, false, false])
    }

    test("task sort: the toggleTaskChecked command sorts too") {
        let editor = try sortingEditor([("a", false), ("b", false), ("c", false)])
        select(editor, itemPos(editor, 0) + 2, itemPos(editor, 0) + 2)
        try expect(editor.run("toggleTaskChecked"))
        try expectEqual(texts(editor), ["b", "c", "a"])
        try expect(editor.run("toggleTaskChecked"), "the caret rode down with it")
        try expectEqual(texts(editor), ["a", "b", "c"])
    }

    test("task sort: homes are the session's, not the document's") {
        let editor = try sortingEditor([("a", false), ("b", false), ("c", false)])
        setChecked(editor, 0, true)
        try expectEqual(texts(editor), ["b", "c", "a"])
        // Reload the same content: the homes go with the old document.
        try editor.setContent(html: editor.getHTML())
        try expectEqual(taskSortKey.getState(editor.state)?.isEmpty, true)
        setChecked(editor, 2, false)
        try expectEqual(texts(editor), ["b", "c", "a"], "nothing remembers where it came from")
        try expectEqual(checks(editor), [false, false, false])
    }

    test("task sort: a list left alone by a check elsewhere isn't rewritten") {
        let editor = try Editor(extensions: fullKit(
            taskListOptions: TaskListOptions(sortCompletedToBottom: true)))
        try editor.setContent(html: """
        <ul data-type="taskList">\
        <li data-type="taskItem" data-checked="false"><p>a</p></li>\
        <li data-type="taskItem" data-checked="false"><p>b</p></li>\
        </ul>\
        <ul data-type="taskList">\
        <li data-type="taskItem" data-checked="false"><p>c</p></li>\
        <li data-type="taskItem" data-checked="false"><p>d</p></li>\
        </ul>
        """)
        setChecked(editor, 2, true)   // c, in the second list
        try expectEqual(texts(editor), ["a", "b", "d", "c"])
    }
}
