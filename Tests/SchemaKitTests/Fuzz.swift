import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestHarness

/// A seeded, deterministic RNG so any failure reproduces from its seed.
private struct FuzzRNG: RandomNumberGenerator {
    private var s: UInt64
    init(seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s
    }
}

private let fuzzAlphabet = Array("ab cd\nef 🙂g.,#-*>`[]")
private let fuzzCommands = ["toggleBold", "toggleItalic", "toggleCode", "toggleStrike",
                            "toggleBulletList", "toggleOrderedList", "toggleTaskList",
                            "toggleHeading1", "toggleHeading2", "toggleBlockquote",
                            "toggleCodeBlock", "setHorizontalRule", "setParagraph",
                            // table commands (no-ops outside a table; exercise the
                            // spanning-aware TableMap/CellSelection machinery in one)
                            "addColumnBefore", "addColumnAfter", "deleteColumn",
                            "addRowBefore", "addRowAfter", "deleteRow",
                            "mergeCells", "splitCell", "toggleHeaderRow", "toggleHeaderColumn",
                            "goToNextCell", "goToPreviousCell", "deleteTable"]
private let fuzzKeys = ["Enter", "Backspace", "Delete", "Tab", "Shift-Tab", "Mod-z", "Mod-y", "Mod-Enter"]

private func randomString(_ rng: inout FuzzRNG) -> String {
    let n = Int.random(in: 0 ... 6, using: &rng)
    return String((0 ..< n).map { _ in fuzzAlphabet.randomElement(using: &rng)! })
}

/// A possibly-malformed slice JSON (random content + over-large open depths) to
/// exercise the replace Fitter / slice clamping.
private func randomSliceJSON(_ rng: inout FuzzRNG) -> [String: AttributeValue] {
    var nodes: [AttributeValue] = []
    for _ in 0 ..< Int.random(in: 0 ... 3, using: &rng) {
        switch Int.random(in: 0 ... 2, using: &rng) {
        case 0: nodes.append(.object(["type": .string("text"), "text": .string("xy")]))
        case 1: nodes.append(.object(["type": .string("paragraph"),
                                      "content": .array([.object(["type": .string("text"), "text": .string("p")])])]))
        default: nodes.append(.object(["type": .string("blockquote"),
                                       "content": .array([.object(["type": .string("paragraph"),
                                                                   "content": .array([.object(["type": .string("text"), "text": .string("q")])])])])]))
        }
    }
    return ["content": .array(nodes),
            "openStart": .int(Int.random(in: 0 ... 4, using: &rng)),
            "openEnd": .int(Int.random(in: 0 ... 4, using: &rng))]
}

private func runOneFuzz(seed: UInt64, ops: Int) throws {
    var rng = FuzzRNG(seed: seed)
    let editor = try Editor(extensions: fullKit())
    func pos() -> Int { Int.random(in: 0 ... max(0, editor.doc.content.size), using: &rng) }
    func cellPositions() -> [Int] {
        var result: [Int] = []
        editor.doc.descendants { node, p, _, _ in
            if node.type.name == "tableCell" || node.type.name == "tableHeader" { result.append(p) }
            return true
        }
        return result
    }

    for step in 0 ..< ops {
        switch Int.random(in: 0 ..< 14, using: &rng) {
        case 0:
            let tr = editor.state.tr
            _ = try? tr.insertText(randomString(&rng), min(pos(), editor.doc.content.size))
            editor.dispatch(tr)
        case 1:
            let a = pos(), b = pos(), tr = editor.state.tr
            _ = try? tr.delete(min(a, b), max(a, b))
            editor.dispatch(tr)
        case 2:
            let a = pos(), b = pos()
            editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, min(a, b), max(a, b))))
        case 3: // node selection at an arbitrary position (must never trap)
            editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, pos())))
        case 4:
            editor.dispatch(editor.state.tr.setSelection(AllSelection(editor.doc)))
        case 5:
            _ = editor.run(fuzzCommands.randomElement(using: &rng)!)
        case 6:
            _ = key(editor, fuzzKeys.randomElement(using: &rng)!)
        case 7: // split at an arbitrary depth (must throw, never trap)
            let tr = editor.state.tr
            _ = try? tr.split(min(pos(), editor.doc.content.size), Int.random(in: 1 ... 5, using: &rng))
            editor.dispatch(tr)
        case 8: // search + replace (incl. replace before find-next)
            editor.setSearch(randomString(&rng))
            _ = editor.replaceCurrentMatch(with: randomString(&rng))
            if Bool.random(using: &rng) { _ = editor.replaceAllMatches(with: randomString(&rng)) }
        case 9: // replace the selection with a (possibly malformed) slice
            if let slice = try? Slice.fromJSON(editor.schema, randomSliceJSON(&rng)) {
                let tr = editor.state.tr
                _ = tr.replaceSelection(slice)
                editor.dispatch(tr)
            }
        case 10:
            editor.findNext(); editor.findPrevious()
        case 11:
            _ = editor.run("lift")
        case 12: // insert a (possibly spanning, via later merges) table
            _ = editor.insertTable(rows: Int.random(in: 1 ... 3, using: &rng),
                                   cols: Int.random(in: 1 ... 3, using: &rng),
                                   withHeaderRow: Bool.random(using: &rng))
        case 13: // a random cell selection (exercises CellSelection.map/content)
            let cells = cellPositions()
            if cells.count >= 2 {
                let a = cells.randomElement(using: &rng)!, b = cells.randomElement(using: &rng)!
                editor.dispatch(editor.state.tr.setSelection(CellSelection.create(editor.doc, a, b)))
            }
        default: break
        }

        // Invariants that must hold after every operation.
        try editor.doc.check() // schema-valid document
        let size = editor.doc.content.size
        try expect(editor.state.selection.from >= 0 && editor.state.selection.to <= size,
                   "selection in range at seed \(seed) step \(step)")
        // Resolving any in-range position must not trap.
        _ = editor.doc.resolve(min(pos(), size))
        _ = editor.doc.textContent
    }
}

/// A table-biased fuzz: keep a table alive and hammer it with random cell
/// selections + spanning commands (merge/split/add/delete/toggle-header), which
/// the general fuzz only hits occasionally.
private func runTableFuzz(seed: UInt64, ops: Int) throws {
    var rng = FuzzRNG(seed: seed)
    let editor = try Editor(extensions: fullKit())
    let cmds = ["addColumnBefore", "addColumnAfter", "deleteColumn", "addRowBefore", "addRowAfter",
                "deleteRow", "mergeCells", "splitCell", "toggleHeaderRow", "toggleHeaderColumn"]
    func cells() -> [Int] {
        var r: [Int] = []
        editor.doc.descendants { node, p, _, _ in
            if node.type.name == "tableCell" || node.type.name == "tableHeader" { r.append(p) }
            return true
        }
        return r
    }
    _ = editor.insertTable(rows: Int.random(in: 2 ... 4, using: &rng), cols: Int.random(in: 2 ... 4, using: &rng),
                           withHeaderRow: Bool.random(using: &rng))
    for step in 0 ..< ops {
        let c = cells()
        if c.isEmpty { // table got deleted — make a new one
            _ = editor.insertTable(rows: Int.random(in: 2 ... 4, using: &rng), cols: Int.random(in: 2 ... 4, using: &rng))
        }
        var action = ""
        switch Int.random(in: 0 ..< 5, using: &rng) {
        case 0 where c.count >= 2: // rectangular cell selection
            editor.dispatch(editor.state.tr.setSelection(
                CellSelection.create(editor.doc, c.randomElement(using: &rng)!, c.randomElement(using: &rng)!)))
            action = "cellSelect"
        case 1: // cursor inside a cell
            if let cp = c.randomElement(using: &rng) {
                editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, min(cp + 2, editor.doc.content.size))))
            }
            action = "cursor"
        case 2: // type into the current cell
            let tr = editor.state.tr
            _ = try? tr.insertText(randomString(&rng), min(editor.state.selection.from, editor.doc.content.size))
            editor.dispatch(tr)
            action = "type"
        default: // run a table command
            let cmd = cmds.randomElement(using: &rng)!
            _ = editor.run(cmd)
            action = cmd
        }
        var checkErr: Error?
        do { try editor.doc.check() } catch { checkErr = error }
        try expect(checkErr == nil, "invalid doc — table seed \(seed) step \(step) after \(action): \(checkErr.map { "\($0)" } ?? "")")
        let size = editor.doc.content.size
        try expect(editor.state.selection.from >= 0 && editor.state.selection.to <= size,
                   "selection in range at table seed \(seed) step \(step)")
        if let cs = editor.state.selection as? CellSelection { cs.forEachCell { _, _ in } } // must not trap
    }
}

func registerFuzzTests() {
    test("fuzz: random edits/selections/commands never crash or corrupt the doc") {
        // Many seeds × many ops. A trap would abort with the reproducing seed.
        for seed in UInt64(1) ... 120 {
            try runOneFuzz(seed: seed, ops: 150)
        }
    }
    test("fuzz: table-biased cell selections + spanning commands stay valid") {
        for seed in UInt64(1) ... 120 {
            try runTableFuzz(seed: seed, ops: 150)
        }
    }
}
