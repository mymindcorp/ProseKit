import Foundation
import DocumentModel
import DocumentTransform
import EditorChangeset
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for track changes, and for the changeset underneath it.
//
// `EditorChangeset` was the last module with no fuzz of any kind, and it is the
// one whose failure mode is quietest: a changeset that under-reports doesn't
// crash, it just leaves an edit unmarked, and the reviewer approves a document
// containing a change nobody showed them. Rejecting a suggestion then restores
// the wrong text, and there is nothing in the document to say so.
//
// Two levels, because they fail differently:
//
//   * the changeset's own shape — its changes are a sorted, non-overlapping
//     list of replacements, and *everything between them is identical in both
//     documents*. That last one is the whole contract; the rest is bookkeeping.
//   * track changes end to end — rejecting every suggestion has to give back
//     the document you started from, character for character, and accepting
//     them all has to leave the document exactly as it stands.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerSuggestionFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("suggestion fuzz: rejecting every suggestion restores the document") {
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 29 &+ 7)
            let editor = try suggestionFuzzEditor()
            let base = editor.doc
            var log: [String] = []
            editor.dispatch(setSuggestionMode(editor.state.tr, enabled: true))

            for _ in 0 ..< fuzzSuggestionOps {
                log.append(fuzzStep(editor, &rng))
                try checkSuggestionState(editor, base, "seed \(seed) — \(log.suffix(3).joined(separator: " | "))")
            }

            try expect(editor.run("rejectAllSuggestions") || suggestionChanges(editor).isEmpty,
                       "rejectAll declined with \(suggestionChanges(editor).count) changes at seed \(seed)")
            try expect(editor.doc == base,
                       "rejecting every suggestion didn't restore the document at seed \(seed) — \(log.joined(separator: " | "))")
            try expect(suggestionChanges(editor).isEmpty, "changes remained after rejecting them all at seed \(seed)")
        }
    }

    test("suggestion fuzz: accepting every suggestion leaves the document alone") {
        // The mirror of the property above, and the one a reviewer relies on:
        // "accept all" is a decision about the *record*, not about the text.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 31 &+ 13)
            let editor = try suggestionFuzzEditor()
            editor.dispatch(setSuggestionMode(editor.state.tr, enabled: true))
            for _ in 0 ..< fuzzSuggestionOps { _ = fuzzStep(editor, &rng) }
            let edited = editor.doc

            _ = editor.run("acceptAllSuggestions")
            try expect(editor.doc == edited, "accepting every suggestion changed the document at seed \(seed)")
            try expect(suggestionChanges(editor).isEmpty, "changes remained after accepting them all at seed \(seed)")
            // And the base is now what the document says it is, so a second
            // pass has nothing left to do.
            try expect(!editor.run("rejectAllSuggestions"), "there was still something to reject at seed \(seed)")
            try expect(editor.doc == edited, "a no-op reject changed the document at seed \(seed)")
        }
    }

    test("suggestion fuzz: resolving suggestions one at a time ends in the same place") {
        // Not all at once: a reviewer works through them, and each decision
        // re-indexes the ones that are left.
        //
        // A single reject is allowed to decline — one change's range can sit
        // inside structure another pending change created, and restoring it
        // alone is not something the schema permits. What it may not do is
        // half-restore, or leave the record describing a document that no
        // longer exists, which is what the invariant check after each one is
        // for. Whatever is left when nothing can be rejected individually,
        // `rejectAll` still has to take back to the base.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 37 &+ 17)
            let editor = try suggestionFuzzEditor()
            let base = editor.doc
            editor.dispatch(setSuggestionMode(editor.state.tr, enabled: true))
            for _ in 0 ..< fuzzSuggestionOps { _ = fuzzStep(editor, &rng) }

            var declined = Set<Int>()
            var guardCount = 0
            while suggestionChanges(editor).count > declined.count {
                guardCount += 1
                try expect(guardCount <= fuzzSuggestionOps * 8, "rejecting one at a time isn't terminating at seed \(seed)")
                let count = suggestionChanges(editor).count
                guard let index = (0 ..< count).shuffled(using: &rng).first(where: { !declined.contains($0) })
                else { break }
                let before = editor.doc
                if editor.run(rejectSuggestion(index)) {
                    try expect(editor.doc != before, "a reject that reported success changed nothing at seed \(seed)")
                    declined = [] // the indices all moved
                } else {
                    declined.insert(index)
                    try expect(editor.doc == before, "a reject that declined still changed the document at seed \(seed)")
                }
                try checkSuggestionState(editor, base, "seed \(seed) after rejecting \(index)")
            }

            _ = editor.run("rejectAllSuggestions")
            try expect(editor.doc == base,
                       "rejecting the suggestions one at a time didn't restore the document at seed \(seed)")
            try expect(suggestionChanges(editor).isEmpty, "changes remained at seed \(seed)")
        }
    }

    test("suggestion fuzz: accepting some and rejecting the rest stays valid") {
        // The realistic pass, and the one that mixes the two coordinate spaces:
        // accepting moves the *base* under the remaining changes, rejecting
        // moves the *document* under them. Doing both interleaved is where an
        // index that was only shifted on one side shows up.
        //
        // Either decision may decline on a change entangled with another one.
        // What neither may do is report a success that didn't happen — a
        // suggestion that stays on screen however often it is accepted — so a
        // command that returns true has to have resolved something.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 41 &+ 19)
            let editor = try suggestionFuzzEditor()
            editor.dispatch(setSuggestionMode(editor.state.tr, enabled: true))
            for _ in 0 ..< fuzzSuggestionOps { _ = fuzzStep(editor, &rng) }

            var stuck = Set<Int>()
            var guardCount = 0
            while suggestionChanges(editor).count > stuck.count {
                guardCount += 1
                try expect(guardCount <= fuzzSuggestionOps * 8, "resolving isn't terminating at seed \(seed)")
                let count = suggestionChanges(editor).count
                guard let index = (0 ..< count).shuffled(using: &rng).first(where: { !stuck.contains($0) })
                else { break }
                let before = (doc: editor.doc, count: count)
                let first = Bool.random(using: &rng)
                let resolved = editor.run(first ? acceptSuggestion(index) : rejectSuggestion(index))
                    || editor.run(first ? rejectSuggestion(index) : acceptSuggestion(index))
                if resolved {
                    try expect(suggestionChanges(editor).count < before.count,
                               "a decision that reported success left every suggestion in place at seed \(seed)")
                    stuck = [] // the indices all moved
                } else {
                    stuck.insert(index)
                    try expect(editor.doc == before.doc, "a declined decision still changed the document at seed \(seed)")
                }
                try checkSuggestionState(editor, nil, "seed \(seed) after resolving \(index)")
            }

            // Whatever wouldn't resolve one at a time, accepting the lot does.
            _ = editor.run("acceptAllSuggestions")
            try expect(suggestionChanges(editor).isEmpty, "changes remained at seed \(seed)")
        }
    }
}

/// Shorter than the other live-editor sweeps: every operation here costs a
/// changeset re-diff, and every check walks both documents.
let fuzzSuggestionOps = 25

private func suggestionFuzzEditor() throws -> Editor {
    // History off: an undo is just another edit to the changeset, and its
    // appended transactions only make the op log harder to read back.
    try Editor(extensions: fuzzKit() + [SuggestionModeExtension(author: "alice")], history: false)
}

private func suggestionChanges(_ editor: Editor) -> [Change<String>] {
    suggestionModeKey.getState(editor.state)?.changes ?? []
}

// MARK: - What a changeset has to be

/// Everything that must hold of the recorded changes, plus the document itself.
///
/// `base` is the document tracking started from, when the caller still knows it
/// — accepting a suggestion deliberately moves the base, so the sweeps that do
/// that pass nil.
private func checkSuggestionState(_ editor: Editor, _ base: Node?, _ ctx: @autoclosure () -> String) throws {
    var invalid: (any Error)?
    do { try editor.doc.check() } catch { invalid = error }
    try expect(invalid == nil, "suggesting produced an invalid document — \(ctx()): \(invalid.map { "\($0)" } ?? "")")
    try checkSelectionValid(editor.state.selection, in: editor.doc, ctx())

    guard let set = suggestionModeKey.getState(editor.state)?.changeSet else { return }
    let startDoc = set.startDoc, newDoc = editor.doc
    if let base { try expect(startDoc == base, "the base document moved on its own — \(ctx())") }
    // Every message below needs the same picture: which ranges the set claims,
    // and how big the two documents are.
    let shape = "base \(startDoc.content.size), doc \(newDoc.content.size), changes "
        + set.changes.map { "[\($0.fromA)..\($0.toA)→\($0.fromB)..\($0.toB)]" }.joined(separator: " ")

    var previousA = 0, previousB = 0
    for (i, change) in set.changes.enumerated() {
        let what = "change \(i) — \(ctx())\n  \(shape)"
        try expect(change.fromA <= change.toA && change.fromB <= change.toB, "inverted range: \(what)")
        try expect(change.toA <= startDoc.content.size, "range past the end of the base: \(what)")
        try expect(change.toB <= newDoc.content.size, "range past the end of the document: \(what)")
        try expect(change.fromA >= previousA && change.fromB >= previousB, "changes out of order or overlapping: \(what)")

        // The spans say what was deleted and inserted; their lengths have to
        // add up to the ranges they describe, or a decoration is drawn over
        // content that isn't there.
        try expectEqual(change.deleted.reduce(0) { $0 + $1.length }, change.toA - change.fromA,
                        "deleted spans don't cover the range: \(what)")
        try expectEqual(change.inserted.reduce(0) { $0 + $1.length }, change.toB - change.fromB,
                        "inserted spans don't cover the range: \(what)")

        // The contract: what lies between two changes is untouched, so it has
        // to be the same length and the same content in both documents.
        try expectEqual(change.fromA - previousA, change.fromB - previousB,
                        "the gap before this change is a different size in the two documents: \(what)")
        try expect(sameContent(startDoc, previousA, change.fromA, newDoc, previousB, change.fromB),
                   "the changeset calls a range unchanged that isn't: \(what)")

        previousA = change.toA
        previousB = change.toB
    }
    // And the tail after the last change.
    try expectEqual(startDoc.content.size - previousA, newDoc.content.size - previousB,
                    "the documents differ in length after the last change — \(ctx())\n  \(shape)")
    try expect(sameContent(startDoc, previousA, startDoc.content.size, newDoc, previousB, newDoc.content.size),
               "the changeset calls the tail unchanged when it isn't — \(ctx())\n  \(shape)\n  base:\n\(fuzzOutline(startDoc))  doc:\n\(fuzzOutline(newDoc))")
}

/// Whether two ranges of two documents hold the same content.
///
/// Compared as slices rather than as text: a heading that became a paragraph,
/// a link that lost its href and a checkbox that got ticked are all changes a
/// reviewer has to see, and none of them moves a single character.
private func sameContent(_ a: Node, _ fromA: Int, _ toA: Int,
                         _ b: Node, _ fromB: Int, _ toB: Int) -> Bool {
    if toA - fromA != toB - fromB { return false }
    if toA == fromA { return true }
    return a.slice(fromA, toA).content == b.slice(fromB, toB).content
}
