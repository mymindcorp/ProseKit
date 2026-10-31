import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorHistory
import SchemaKit
import TestHarness

/// Best of `runs`, timing only `body`: `setup` builds what it works on fresh
/// each run, outside the clock.
private func time<T>(_ label: String, ops: Int, runs: Int = 3,
                     setup: () throws -> T, _ body: (T) throws -> Void) rethrows {
    var best = Double.infinity
    for _ in 0..<runs {
        let value = try setup()
        let start = Date()
        try body(value)
        best = min(best, Date().timeIntervalSince(start))
    }
    unsafe print(String(format: "  %-44s %7.2f ms  %7.1f µs each",
                        (label as NSString).utf8String!, best * 1000, best * 1e6 / Double(ops)))
    unsafe fflush(stdout)
}

/// Type `text` at the cursor the way the view does: offered to every plugin's
/// text-input handler (the input rules) first, inserted plainly otherwise.
private func typeInput(_ editor: Editor, _ text: String) throws {
    let from = editor.state.selection.from, to = editor.state.selection.to
    for plugin in editor.state.plugins {
        if let handler = plugin.props?.handleTextInput,
           handler(from, to, text, editor.state, { editor.dispatch($0) }) { return }
    }
    let tr = editor.state.tr
    try tr.insertText(text)
    editor.dispatch(tr)
}

private func benchEditor() throws -> Editor {
    let editor = try Editor(extensions: fullKit())
    var html = ""
    for i in 0..<1000 {
        html += "<p>Paragraph \(i): the quick brown fox jumps over the lazy dog.</p>"
        if i % 50 == 0 {
            html += "<table>" + String(repeating: "<tr><td>a</td><td>b</td><td>c</td></tr>", count: 3) + "</table>"
        }
    }
    try editor.setContent(html: html)
    return editor
}

/// What a keystroke costs across a whole typing session in the full kit, and
/// what a cursor move costs. Off by default:
///
///     PROSEKIT_BENCH=1 swift run -c release SchemaKitTests
///
/// The session is one long undo event, so anything that grows with it — the
/// history branch was one — shows up as a per-keystroke cost that climbs.
func registerTypingBench() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_BENCH"] != nil else { return }
    test("typing bench") {
        print("\n  --- 1000 paragraphs, 20 tables, full kit ---"); unsafe fflush(stdout)
        for count in [500, 2000] {
            try time("typing a session of \(count) characters", ops: count, setup: {
                let editor = try benchEditor()
                editor.dispatch(editor.state.tr.setSelection(Selection.atEnd(editor.doc)))
                return editor
            }) { editor in
                for i in 0..<count { try typeInput(editor, i % 6 == 5 ? " " : "x") }
            }
        }
        let editor = try benchEditor()
        let mid = editor.doc.content.size / 2
        time("cursor moves (x1000)", ops: 1000, setup: { editor }) { editor in
            for i in 0..<1000 {
                editor.dispatch(editor.state.tr.setSelection(Selection.near(editor.doc.resolve(mid + i % 2))))
            }
        }
        print("\n  --- end of one long paragraph, full kit ---"); unsafe fflush(stdout)
        for reps in [150, 600, 2400] {
            let long = String(repeating: "lorem ipsum dolor ", count: reps)
            try time("typing, \(long.count)-character paragraph", ops: 200, setup: {
                let editor = try Editor(extensions: fullKit())
                try editor.setContent(html: "<p>\(long)</p>")
                editor.dispatch(editor.state.tr.setSelection(Selection.atEnd(editor.doc)))
                return editor
            }) { editor in
                for i in 0..<200 { try typeInput(editor, i % 6 == 5 ? " " : "x") }
            }
        }
        // Undo that session must still be one step back to the start.
        editor.dispatch(editor.state.tr.setSelection(Selection.atEnd(editor.doc)))
        let before = editor.doc
        for _ in 0..<200 { try typeInput(editor, "y") }
        try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }), "undo runs")
        try expectEqual(editor.doc, before, "one undo reverts the whole typing session")
    }
}
