import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestHarness

/// Best of `runs`, reported as a total and as the cost of one operation — the
/// per-operation number is the one a user feels.
private func report(_ label: String, _ best: Double, ops: Int) {
    unsafe print(String(format: "  %-44s %7.2f ms  %7.1f µs each",
                        (label as NSString).utf8String!, best * 1000, best * 1e6 / Double(ops)))
    unsafe fflush(stdout)
}

/// Time two variants against each other, alternating runs so a machine that
/// gets busier (or hotter) partway through moves both numbers, not one.
private func compare(ops: Int, runs: Int = 5,
                     _ a: (label: String, body: () throws -> Void),
                     _ b: (label: String, body: () throws -> Void)) throws {
    var bestA = Double.infinity, bestB = Double.infinity
    for _ in 0..<runs {
        var start = Date()
        try a.body()
        bestA = min(bestA, Date().timeIntervalSince(start))
        start = Date()
        try b.body()
        bestB = min(bestB, Date().timeIntervalSince(start))
    }
    report(a.label, bestA, ops: ops)
    report(b.label, bestB, ops: ops)
}

private func benchEditor(_ count: Int, sorting: Bool) throws -> Editor {
    let editor = try Editor(extensions: fullKit(
        taskListOptions: TaskListOptions(sortCompletedToBottom: sorting)))
    let lis = (0..<count).map { i in
        "<li data-type=\"taskItem\" data-checked=\"false\"><p>Task number \(i) — something to do</p></li>"
    }.joined()
    try editor.setContent(html: "<ul data-type=\"taskList\">\(lis)</ul>")
    return editor
}

// The list is the document's only block, so its items are found without walking
// anything — the timings below are the editor's work, not the harness's.
private func firstItemPos(_ editor: Editor) -> Int { 1 }
private func lastItemPos(_ editor: Editor) -> Int {
    let list = editor.doc.child(0)
    return 1 + list.content.size - list.child(list.childCount - 1).nodeSize
}

/// The tap path: the checkbox overlay's toggle, which folds any reorder into the
/// transaction that makes the check.
private func tapChecked(_ editor: Editor, _ pos: Int, _ checked: Bool) {
    if let tr = setTaskChecked(editor.state, pos: pos, checked: checked) { editor.dispatch(tr) }
}

/// The plugin path: a bare attribute step, as a collab step or a script would
/// produce, with the reorder appended as a second transaction.
private func stepChecked(_ editor: Editor, _ pos: Int, _ checked: Bool) throws {
    let tr = editor.state.tr
    _ = try tr.setNodeAttribute(pos, "checked", .bool(checked))
    editor.dispatch(tr)
}

/// What sorting costs, against what it costs to be switched off. Off by default:
///
///     PROSEKIT_BENCH=1 swift run -c release SchemaKitTests
///
/// The rows that matter: typing in a long task list is the common case and the
/// plugin must not show up in it, and a toggle is what a user waits on when they
/// tap a checkbox. Checking the top item is the worst case (it travels the whole
/// list); checking the bottom item is the cheap one, where nothing moves and the
/// only record of it is a note in plugin state.
func registerTaskSortBench() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_BENCH"] != nil else { return }
    test("task sort bench") {
        for count in [100, 1000] {
            print("\n  --- \(count) task items ---"); unsafe fflush(stdout)
            let off = try benchEditor(count, sorting: false)
            let on = try benchEditor(count, sorting: true)

            // A keystroke in the first item, which sorting must not touch.
            try compare(ops: 500,
                ("typing, sorting off (x500)", {
                    let pos = firstItemPos(off) + 2
                    for _ in 0..<500 {
                        let tr = off.state.tr
                        try tr.insertText("x", pos)
                        off.dispatch(tr)
                    }
                }),
                ("typing, sorting on (x500)", {
                    let pos = firstItemPos(on) + 2
                    for _ in 0..<500 {
                        let tr = on.state.tr
                        try tr.insertText("x", pos)
                        on.dispatch(tr)
                    }
                }))

            // Check the top item, then uncheck it — one round trip per iteration.
            try compare(ops: 200,
                ("check top + undo it, sorting off (x100)", {
                    for _ in 0..<100 {
                        tapChecked(off, firstItemPos(off), true)
                        tapChecked(off, firstItemPos(off), false)
                    }
                }),
                ("check top + undo it, sorting on (x100)", {
                    for _ in 0..<100 {
                        tapChecked(on, firstItemPos(on), true)
                        tapChecked(on, lastItemPos(on), false)
                    }
                }))

            // Nothing moves: the item is already at the bottom.
            try compare(ops: 200,
                ("check bottom + undo it, sorting off (x100)", {
                    for _ in 0..<100 {
                        tapChecked(off, lastItemPos(off), true)
                        tapChecked(off, lastItemPos(off), false)
                    }
                }),
                ("check bottom + undo it, sorting on (x100)", {
                    for _ in 0..<100 {
                        tapChecked(on, lastItemPos(on), true)
                        tapChecked(on, lastItemPos(on), false)
                    }
                }))

            // The same top-item move arriving as a bare attribute step, which
            // the plugin has to answer with a second transaction.
            try compare(ops: 200,
                ("check top + undo it, plain step, off (x100)", {
                    for _ in 0..<100 {
                        try stepChecked(off, firstItemPos(off), true)
                        try stepChecked(off, firstItemPos(off), false)
                    }
                }),
                ("check top + undo it, plain step, on (x100)", {
                    for _ in 0..<100 {
                        try stepChecked(on, firstItemPos(on), true)
                        try stepChecked(on, lastItemPos(on), false)
                    }
                }))
        }
    }
}
