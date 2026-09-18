import TestDocGen
import EditorSerialization
import Foundation
import DocumentModel
import EditorStateKit
import EditorHistory
import SchemaKit
import TestHarness

private struct SeededEditFailure: Error, CustomStringConvertible {
    let description: String
}

// Keep this small enough for normal CI. Larger sweeps and a single failing seed
// use the same runner; no separate fuzz-only implementation can drift from it.
func registerSeededEditTests() {
    let env = ProcessInfo.processInfo.environment
    let steps = max(1, Int(env["PROSEKIT_EDIT_STEPS"] ?? "") ?? 60)
    let seeds = env["PROSEKIT_EDIT_SEED"].flatMap(UInt64.init).map { [$0] }
        ?? Array(1...UInt64(max(1, Int(env["PROSEKIT_EDIT_SEEDS"] ?? "") ?? 12)))
    for seed in seeds {
        test("seeded edits: seed \(seed)") {
            let first = try runSeededEdits(seed, steps, trace: env["PROSEKIT_EDIT_TRACE"] == "1")
            let second = try runSeededEdits(seed, steps, trace: false)
            try expectEqual(first, second, "seed \(seed) did not replay deterministically")
        }
    }
}

private func runSeededEdits(_ seed: UInt64, _ steps: Int, trace: Bool) throws -> String {
    var rng = SelRNG(seed)
    func pick(_ count: Int) -> Int { Int(rng.next() % UInt64(count)) }
    let editor = try Editor(extensions: fuzzKit())
    try editor.setContent(html: "<p>alpha 🙂 é</p><ul><li><p>outer</p><ol><li><p>inner</p></li></ol></li><li><p>next</p></li></ul><table><tr><td>A</td><td>B</td></tr><tr><td>C</td><td>D</td></tr></table><p>end<br>tail</p>")
    var log: [String] = []
    for step in 0..<steps {
        do {
            // History boundaries make the inverse assertion independent of the
            // machine's speed and of whether the preceding edit was typing.
            editor.dispatch(closeHistory(editor.state.tr))
            let before = editor.doc
            let kind = pick(9)
            let commands = fuzzOpCommands
            let keys = ["Enter", "Tab", "Shift-Tab", "Backspace", "Delete", "Shift-Enter"]
            let command = commands[pick(commands.count)]
            let keyName = keys[pick(keys.count)]
            let text = ["x", "🙂", "é", " ", "ab", "\n"][pick(6)]
            let a = pick(editor.doc.content.size + 1)
            let b = pick(editor.doc.content.size + 1)
            let description: String
            switch kind {
            case 0: description = "select near \(a)"
            case 1: description = "select range \(a)..\(b)"
            case 2: description = "insert \(text.debugDescription)"
            case 3: description = "delete selection"
            case 4: description = "command \(command)"
            case 5: description = "key \(keyName)"
            case 6: description = "undo"
            case 7: description = "redo"
            default: description = "select node near \(a)"
            }
            log.append("\(step): \(description)")
            if trace {
                // Write before execution so a Swift trap still leaves its seed
                // and last operation in the captured stderr log.
                FileHandle.standardError.write(Data("seed \(seed) \(log.last!)\n".utf8))
            }
            switch kind {
            case 0:
                editor.dispatch(editor.state.tr.setSelection(Selection.near(editor.doc.resolve(a))))
            case 1:
                editor.dispatch(editor.state.tr.setSelection(TextSelection.between(editor.doc.resolve(a), editor.doc.resolve(b))))
            case 2:
                let tr = editor.state.tr
                try tr.insertText(text)
                editor.dispatch(tr)
            case 3: editor.dispatch(editor.state.tr.deleteSelection())
            case 4:
                let handled = editor.run(command)
                if !handled { try expect(editor.doc == before, "declined command changed document") }
            case 5:
                let handled = key(editor, keyName)
                if !handled { try expect(editor.doc == before, "declined key changed document") }
            case 6: _ = key(editor, "Mod-z")
            case 7: _ = key(editor, "Mod-y")
            default:
                var candidates: [Int] = []
                editor.doc.descendants { node, pos, _, _ in
                    if NodeSelection.isSelectable(node) { candidates.append(pos) }
                    return true
                }
                if !candidates.isEmpty {
                    editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, candidates[a % candidates.count])))
                }
            }
            try editor.doc.check()
            try checkSelectionValid(editor.state.selection, in: editor.doc, "seed \(seed), step \(step)")
            try expect(try editor.schema.nodeFromJSON(editor.doc.toJSON()) == editor.doc, "JSON round trip changed document")
            var tables: [Node] = []
            editor.doc.descendants { node, _, _, _ in
                if node.type.name == "table" { tables.append(node) }; return true
            }
            for table in tables { try checkTableMap(table, "seed \(seed), step \(step)") }
            try expect(fixTables(editor.state, nil) == nil, "table repair is not idempotent")
            let after = editor.doc
            if kind != 6 && kind != 7 && after != before {
                editor.dispatch(closeHistory(editor.state.tr))
                try expect(key(editor, "Mod-z"), "edit cannot undo")
                try expect(editor.doc == before, "undo did not restore pre-edit document")
                try expect(key(editor, "Mod-y"), "edit cannot redo")
                try expect(editor.doc == after, "redo did not restore edited document")
                try checkSelectionValid(editor.state.selection, in: editor.doc, "after redo")
            }
        } catch {
            throw SeededEditFailure(description: "\(error)\nReplay: PROSEKIT_EDIT_SEED=\(seed) PROSEKIT_EDIT_STEPS=\(steps) PROSEKIT_EDIT_TRACE=1 PROSEKIT_TEST_FILTER='seeded edits:' swift run SchemaKitTests\n\(log.joined(separator: "\n"))")
        }
    }
    return try DocumentJSON.string(editor.doc) + "\n" + describeSelection(editor.state.selection) + "\n" + log.joined(separator: "\n")
}
