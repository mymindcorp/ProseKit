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
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("history fuzz: undoing everything returns to the document you started from") {
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 7 &+ 1)
            let editor = try Editor(extensions: fullKit())
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
            let editor = try Editor(extensions: fullKit())
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

    test("history fuzz: the selection undo restores is one the document can hold") {
        // Undo puts back the selection the event was made at, mapped through
        // everything since. That selection is resolved against a document that
        // has been rewritten underneath it, which is exactly where a stale
        // position turns into a trap.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 13 &+ 5)
            let editor = try Editor(extensions: fullKit())
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
