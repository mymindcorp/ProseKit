import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for "completed tasks sink to the bottom".
//
// Checking an item moves it to the end of its list; unchecking it sends it
// back to where it was, which the plugin remembers per item. Generated
// documents give it lists nested in blockquotes, table cells and other items'
// sublists, and the driver's other edits move everything around between the
// checks — where a remembered home that wasn't mapped shows itself as an item
// sent back to the wrong place, or into a sibling list.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerTaskSortFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("task sort fuzz: a check sinks the item, an uncheck sends it home, and nothing is lost") {
        var moved = 0
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 61 &+ 29)
            let editor = try Editor(extensions: fuzzKit(sorting: true))
            var gen = DocGen(schema: editor.schema, seed: seed)
            gen.focus = typePath(to: editor.schema.nodes["taskItem"]!, in: editor.schema) ?? []
            editor.setContent(gen.randomDoc(depth: 4, budget: 60))
            var log: [String] = []

            for _ in 0 ..< fuzzOpCount {
                let items = taskItemPositions(editor.doc)
                if items.isEmpty || Int.random(in: 0 ..< 3, using: &rng) == 0 {
                    log.append(fuzzStep(editor, &rng))
                } else {
                    let pos = items.randomElement(using: &rng)!
                    let node = editor.doc.nodeAt(pos)!
                    let wasChecked = node.attrs["checked"]?.boolValue ?? false
                    let before = editor.doc
                    // "Home" is a promise about a list that was sorted to begin
                    // with. An item checked *before* the option was on can sit
                    // above unchecked ones; the plugin tolerates that, and on
                    // the way back an unchecked item lands above every checked
                    // one — which is not where it was, and not wrong.
                    let listBefore = before.resolve(pos + 1).node(-1)
                    var seenChecked = false, sortedBefore = true
                    for i in 0 ..< listBefore.childCount {
                        let c = listBefore.child(i).attrs["checked"]?.boolValue ?? false
                        if c { seenChecked = true } else if seenChecked { sortedBefore = false }
                    }
                    let itemsBefore = taskItems(in: before)
                    let tr = editor.state.tr
                    _ = try? tr.setNodeAttribute(pos, "checked", .bool(!wasChecked))
                    editor.dispatch(tr)
                    log.append("\(wasChecked ? "uncheck" : "check")(\(pos))")
                    let ctx = "seed \(seed) — \(log.suffix(4).joined(separator: " | "))"

                    // Nothing lost, nothing invented: the same items, with one
                    // flag flipped.
                    var expected = itemsBefore
                    if let i = expected.firstIndex(of: "\(wasChecked)|\(node.textContent)") {
                        expected[i] = "\(!wasChecked)|\(node.textContent)"
                    }
                    try expectEqual(taskItems(in: editor.doc).sorted(), expected.sorted(), "the set of items changed — \(ctx)")
                    try expectEqual(editor.doc.content.size, before.content.size, "the document changed size — \(ctx)")

                    if !wasChecked {
                        // Where the item is now. The sort rides in an appended
                        // transaction, so the root transaction's mapping does
                        // not know where the item went; its content does —
                        // sorting moves items, it never edits them.
                        // In the same list, and the *last* such item: a just-checked
                        // item sinks below everything, and a list can hold
                        // twins — two empty items are the same node, and the
                        // first twin would be the wrong one to uncheck.
                        let listPos = before.resolve(pos + 1).before(-1)
                        guard let mine = taskItemPositions(editor.doc).last(where: { p in
                            let n = editor.doc.nodeAt(p)!
                            return n.attrs["checked"]?.boolValue == true && n.content == node.content
                                && editor.doc.resolve(p + 1).before(-1) == listPos
                        }) else {
                            try expect(false, "the checked item is nowhere in the document — \(ctx)")
                            continue
                        }
                        if editor.doc != before { moved += 1 }
                        // A checked item sits at the end of its list — among
                        // the items checked before it, which stay put.
                        let parent = editor.doc.resolve(mine + 1).node(-1)
                        let itsIndex = editor.doc.resolve(mine + 1).index(-1)
                        try expect((itsIndex + 1 ..< parent.childCount).allSatisfy { parent.child($0).attrs["checked"]?.boolValue == true },
                                   "a checked item is above an unchecked one — \(ctx)\n\(fuzzOutline(parent))")
                        // Unchecking straight away sends it home: the document
                        // before the check comes back exactly.
                        let back = editor.state.tr
                        _ = try? back.setNodeAttribute(mine, "checked", .bool(false))
                        editor.dispatch(back)
                        log.append("uncheck-back")
                        if sortedBefore {
                            try expect(editor.doc == before, "check then uncheck didn't restore the document — \(ctx)\n  before:\n\(fuzzOutline(before))  after:\n\(fuzzOutline(editor.doc))")
                        } else {
                            try expectEqual(taskItems(in: editor.doc).sorted(), itemsBefore.sorted(), "check then uncheck changed the set of items — \(ctx)")
                        }
                    }
                }
                var invalid: (any Error)?
                do { try editor.doc.check() } catch { invalid = error }
                try expect(invalid == nil, "an invalid document at seed \(seed) — \(log.suffix(4).joined(separator: " | ")): \(invalid.map { "\($0)" } ?? "")")
                try checkSelectionValid(editor.state.selection, in: editor.doc, "seed \(seed) — \(log.suffix(4).joined(separator: " | "))")
            }
        }
        // A sweep in which no check ever moved an item asserts nothing about
        // sorting; the corpus is steered at task items.
        try expect(moved > 0, "no check ever moved an item across \(fuzzOpSeeds) sessions")
    }

    test("task sort fuzz: writing the flag an item already has moves nothing") {
        // The sweep above only ever *flips* a checkbox, because that is what a
        // person does. Nothing else that writes the attribute is under that
        // constraint: a collab peer replays whatever its author sent, a paste
        // re-states the item it carried, a script sets `checked = true` on a
        // list to tick the lot. Every one of those can write a flag onto an
        // item that already has it — and the plugin's own comment names them as
        // the case its `appendTransaction` exists for.
        //
        // A write that changes no attribute value has to change no order.
        // Anything else is a completed task jumping down its list because a
        // peer echoed a checkbox nobody touched, which the user sees as the app
        // shuffling their list on its own.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 67 &+ 31)
            let editor = try Editor(extensions: fuzzKit(sorting: true))
            var gen = DocGen(schema: editor.schema, seed: seed)
            gen.focus = typePath(to: editor.schema.nodes["taskItem"]!, in: editor.schema) ?? []
            editor.setContent(gen.randomDoc(depth: 4, budget: 60))
            var log: [String] = []

            for _ in 0 ..< fuzzOpCount {
                let items = taskItemPositions(editor.doc)
                if items.isEmpty || Int.random(in: 0 ..< 3, using: &rng) == 0 {
                    log.append(fuzzStep(editor, &rng))
                    continue
                }
                let pos = items.randomElement(using: &rng)!
                let node = editor.doc.nodeAt(pos)!
                let checked = node.attrs["checked"]?.boolValue ?? false
                let before = editor.doc
                let tr = editor.state.tr
                _ = try? tr.setNodeAttribute(pos, "checked", .bool(checked))
                editor.dispatch(tr)
                log.append("rewrite(\(pos), checked: \(checked))")
                try expect(editor.doc == before, """
                    re-writing the flag an item already had moved something — seed \(seed) — \(log.suffix(4).joined(separator: " | "))
                      before:
                    \(fuzzOutline(before))  after:
                    \(fuzzOutline(editor.doc))
                    """)
            }
        }
    }
}

/// The kit with completed-task sorting switched on.
func fuzzKit(sorting: Bool) -> [any Extension] {
    fullKit(taskListOptions: TaskListOptions(sortCompletedToBottom: sorting)) + figureExtensions() + footnoteExtensions()
}

private func taskItemPositions(_ doc: Node) -> [Int] {
    var out: [Int] = []
    doc.descendants { node, pos, _, _ in if node.type.name == "taskItem" { out.append(pos) }; return true }
    return out
}

/// Every task item as "checked|text", so a sort can be checked as a permutation.
private func taskItems(in doc: Node) -> [String] {
    var out: [String] = []
    doc.descendants { node, _, _, _ in
        if node.type.name == "taskItem" { out.append("\(node.attrs["checked"]?.boolValue ?? false)|\(node.textContent)") }
        return true
    }
    return out
}
