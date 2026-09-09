import Foundation
import DocumentModel
import DocumentTransform
import EditorHistory
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for undo and redo.
//
// The hand-written history tests drive short, tidy sequences — type, undo,
// redo — through a small schema. What undo actually has to survive is a long
// run of *structural* edits: lifts and wraps that emit `ReplaceAroundStep`s,
// table commands that rewrite whole rows, plugin transactions appended behind
// the user's back. Undo is defined as the inverse of all of that, so the
// property is the sharpest one in the package: undoing everything has to give
// back the document you started from, character for character.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerHistoryFuzzTests() {
    // Pinned out of the sweep below, and run whether or not the sweep is. The
    // shape it needs — a table repair inserting a cell at exactly the position
    // of the cell whose attribute the user just changed — took thirty-six
    // generated edits to reach, and the seed that reached it is deterministic.
    // `PMHistory` has the same bug written out by hand; this is the one that
    // found it.
    test("history: a generated session of table edits undoes back to the start") {
        var rng = SelRNG(80 &* 7 &+ 1)
        let editor = try Editor(extensions: fuzzKit())
        let original = editor.doc
        for _ in 0 ..< 36 {
            _ = fuzzStep(editor, &rng)
            editor.dispatch(closeHistory(editor.state.tr))
        }
        var undos = 0
        while undoDepth(editor.state) > 0, undos <= fuzzOpHistoryCount * 4 {
            try expect(key(editor, "Mod-z"), "undo declined with \(undoDepth(editor.state)) events left")
            undos += 1
        }
        try expect(editor.doc == original, "undoing everything didn't restore the document")
    }

    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("history fuzz: undoing everything returns to the document you started from") {
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 7 &+ 1)
            let editor = try Editor(extensions: fuzzKit())
            let original = editor.doc
            var log: [String] = []

            // Each op is its own history event, so a run of `n` ops is `n`
            // undos. Grouping by timestamp would make the count depend on how
            // fast the machine is, which is not something a test should race.
            for _ in 0 ..< fuzzOpHistoryCount {
                log.append(fuzzStep(editor, &rng))
                editor.dispatch(closeHistory(editor.state.tr))
            }
            let edited = editor.doc

            var undos = 0
            while undoDepth(editor.state) > 0 {
                try expect(undos <= fuzzOpHistoryCount * 4,
                           "undo isn't terminating at seed \(seed) — \(undoDepth(editor.state)) events left")
                try expect(key(editor, "Mod-z"), "undo declined with \(undoDepth(editor.state)) events left at seed \(seed)")
                undos += 1
            }
            try expect(editor.doc == original,
                       "undoing everything didn't restore the document at seed \(seed) after \(undos) undos — \(log.joined(separator: " | "))")

            // And redo is undo's own inverse: every event goes back on.
            var redos = 0
            while redoDepth(editor.state) > 0 {
                try expect(redos <= undos, "redo isn't terminating at seed \(seed)")
                try expect(key(editor, "Mod-y"), "redo declined with \(redoDepth(editor.state)) events left at seed \(seed)")
                redos += 1
            }
            try expect(editor.doc == edited,
                       "redoing everything didn't get back to the edited document at seed \(seed) — \(log.joined(separator: " | "))")
        }
    }

    test("history fuzz: one undo then one redo is a no-op on the document") {
        // The whole-run property above says the *ends* line up. This one says
        // every step of the way does, which is what localizes a failure: the op
        // named in the message is the one whose inverse is wrong, rather than
        // whichever of forty came first.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 11 &+ 3)
            let editor = try Editor(extensions: fuzzKit())
            for _ in 0 ..< fuzzOpHistoryCount {
                let before = editor.doc
                let what = fuzzStep(editor, &rng)
                editor.dispatch(closeHistory(editor.state.tr))
                let after = editor.doc
                guard after != before, undoDepth(editor.state) > 0 else { continue }

                try expect(key(editor, "Mod-z"), "undo declined right after \(what) at seed \(seed)")
                try expect(editor.doc == before,
                           "undoing \(what) landed somewhere other than where it started, at seed \(seed)")
                var invalid: (any Error)?
                do { try editor.doc.check() } catch { invalid = error }
                try expect(invalid == nil,
                           "undoing \(what) produced an invalid document at seed \(seed): \(invalid.map { "\($0)" } ?? "")")

                try expect(key(editor, "Mod-y"), "redo declined right after undoing \(what) at seed \(seed)")
                try expect(editor.doc == after,
                           "redoing \(what) didn't reproduce what it did, at seed \(seed)")
            }
        }
    }

    test("history fuzz: compressing the undo branch doesn't change what undo does") {
        // Compression is a *rewrite* of the undo branch: it drops the map-only
        // items remote changes leave behind, remaps the steps through them, and
        // merges whatever ends up adjacent. All of that is supposed to be
        // invisible — the same undos, giving back the same documents.
        //
        // It wasn't. `Branch.compress` merged adjacent items in forward order
        // when a branch replays its steps newest-first, so a merged run came
        // back scrambled: three deletes at one spot undid "abcde" to "abdce".
        // Every history property above still held, because they all ran on
        // *uncompressed* branches — nothing compared the two.
        //
        // Compression isn't opt-in in production either: `Branch.rebased` runs
        // it once 500 remote changes have piled up, so this is a long
        // collaborative session plus a held Delete key.
        //
        // Both walks start from one saved `EditorState`, rather than replaying
        // the session twice: undo builds a fresh `HistoryState` instead of
        // touching the one it read, so the saved state can be undone, then
        // compressed, then undone again.
        //
        // And no `closeHistory` here, unlike the sweeps above — this one wants
        // ops to *group*, because items within one event are what merge.
        var collapsed = 0
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 17 &+ 9)
            let editor = try Editor(extensions: fuzzKit())
            var log: [String] = []
            for _ in 0 ..< fuzzOpHistoryCount { log.append(fuzzStep(editor, &rng)) }
            let saved = editor.state
            let ctx = "seed \(seed) — \(log.suffix(4).joined(separator: " | "))"

            let plainItems = _undoItemCount(saved)
            let plain = try undoAll(saved, ctx)

            _compressHistory(saved)
            collapsed += plainItems - _undoItemCount(saved)
            let packed = try undoAll(saved, ctx)

            try expect(plain.last == packed.last,
                       "undoing everything landed somewhere else after compression — \(ctx)")
            let a = squashed(plain), b = squashed(packed)
            try expect(a.count == b.count,
                       "compression changed how many documents the undos walk through: \(a.count) became \(b.count) — \(ctx)")
            for (i, (x, y)) in zip(a, b).enumerated() {
                try expect(x == y, "undo landed on a different document at position \(i) after compression — \(ctx)")
            }
        }
        // An invariant nothing can break asserts nothing: had compression never
        // merged an item, every comparison above would be between two branches
        // that were already identical.
        try expect(collapsed > 0,
                   "compression didn't collapse a single item across \(fuzzOpSeeds) sessions — the property never ran")
    }

    test("history fuzz: the selection undo restores is one the document can hold") {
        // Undo puts back the selection the event was made at, mapped through
        // everything since. That selection is resolved against a document that
        // has been rewritten underneath it, which is exactly where a stale
        // position turns into a trap.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 13 &+ 5)
            let editor = try Editor(extensions: fuzzKit())
            var log: [String] = []
            for _ in 0 ..< fuzzOpHistoryCount {
                log.append(fuzzStep(editor, &rng))
                editor.dispatch(closeHistory(editor.state.tr))
            }
            // A bounded walk, not "until the stacks are empty": undo refills
            // the redo stack and redo refills the undo stack, so wandering
            // between them has no end of its own.
            for _ in 0 ..< fuzzOpHistoryCount * 2 {
                let canUndo = undoDepth(editor.state) > 0, canRedo = redoDepth(editor.state) > 0
                guard canUndo || canRedo else { break }
                let goBack = canUndo && (!canRedo || Bool.random(using: &rng))
                guard key(editor, goBack ? "Mod-z" : "Mod-y") else { break }
                let ctx = "seed \(seed) after \(goBack ? "undo" : "redo") — \(log.suffix(3).joined(separator: " | "))"
                try checkSelectionValid(editor.state.selection, in: editor.doc, ctx)
                var invalid: (any Error)?
                do { try editor.doc.check() } catch { invalid = error }
                try expect(invalid == nil, "history left an invalid document — \(ctx): \(invalid.map { "\($0)" } ?? "")")
            }
        }
    }
}

/// Shorter runs than the step sweeps: each op here costs a close, an undo and a
/// redo, and the default history depth is 100 events — a longer run would start
/// dropping the oldest ones and the round-trip would stop being a round-trip.
let fuzzOpHistoryCount = 40

/// Undo `state` to the bottom of its branch, returning the document at the
/// start and after every undo.
private func undoAll(_ state: EditorState, _ ctx: String) throws -> [Node] {
    var s = state
    var docs = [s.doc]
    while undoDepth(s) > 0 {
        try expect(docs.count <= fuzzOpHistoryCount * 4, "undo isn't terminating at \(ctx)")
        var next: EditorState?
        guard undo(s, { tr in next = s.apply(tr) }), let n = next else { break }
        s = n
        docs.append(s.doc)
    }
    return docs
}

/// A document trail with consecutive repeats removed.
///
/// The counts themselves are allowed to differ, and legitimately do: an item
/// whose step no longer maps onto the document is dropped by compression along
/// with the event it started, while an uncompressed branch keeps that event and
/// spends an undo on it. That undo moves nothing — it only restores a
/// selection — so it shows up here as a repeated document rather than as a
/// different one. What may not differ is the sequence of documents the user
/// actually sees, which is what this compares. (That asymmetry is upstream's
/// and predates the merge-order fix; it is not what this property is hunting.)
private func squashed(_ docs: [Node]) -> [Node] {
    var out: [Node] = []
    for d in docs where out.last != d { out.append(d) }
    return out
}
