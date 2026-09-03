import Foundation
import DocumentModel
import DocumentTransform
import EditorChangeset
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for the changeset layer.
//
// `ChangeSet` is the only thing in the package that answers "what did this edit
// actually change?" — track changes renders from it, and the renderer asks it
// which range to repaint. It had a full port of the upstream unit suite and no
// property test at all, so every case it was held to was one somebody wrote out
// by hand against the three-node test schema.
//
// A changeset makes one promise, and everything built on it depends on that one
// promise being exact: the ranges it reports are the only places the two
// documents differ. Everything outside them holds the same content, in the same
// order, inside the same structure. (Not the same marks or attributes — a
// changeset is built from step maps, and the steps that write those move
// nothing, so it cannot see them. The property below says so at length.) If the
// promise holds loosely — a change reported one character short, a deletion
// whose span lengths don't add up — track changes draws its strike-through over
// the wrong text and the renderer skips a line it needed to repaint, and
// neither failure says anything about a changeset.
//
// So: run a real editing session, feed the maps in, and hold the set to the
// promise. Steps come from the shared driver, so the changesets here are built
// from list lifts, table merges and paste fits rather than from typing.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerChangeSetFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("changeset fuzz: the ranges are well formed and in order") {
        try eachFuzzChangeSet(checkChangesWellFormed)
    }

    test("changeset fuzz: each change sits where the ones before it left it") {
        // `fromB - fromA` is not free: it is the running total of what every
        // earlier change added or removed. A consumer that walks the list
        // converting old positions to new ones — which is what a rebase of
        // decorations over a changeset does — gets a position wrong the moment
        // this drifts, and nothing else it can check would notice.
        try eachFuzzChangeSet { set, _, _, ctx in try checkChangesOffsetsAccumulate(set, ctx) }
    }

    test("changeset fuzz: everything outside the changes is untouched") {
        // The promise itself, and the reason the other two matter. Between two
        // reported changes the old document and the new one have to hold the
        // same content — same nodes, same nesting, same marks, same text.
        //
        // Attributes and marks are the exceptions, and by design rather than
        // by omission. A changeset is built from *step maps*, and the steps
        // that write an attribute or a mark move nothing — `AttrStep.getMap`
        // and `AddMarkStep.getMap` both return the empty map — so those edits
        // are invisible to it, here and upstream. Comparing them would report
        // the design as a bug on every run and drown the finding this property
        // is for. What is left is what a map can express, which is what this
        // asserts: the same text, in the same order, inside the same structure.
        try eachFuzzChangeSet(checkNothingOutsideTheChangesMoved)
    }

    test("changeset fuzz: no change is reported where nothing changed") {
        // The converse, and the one that keeps the property above from being
        // satisfied by a set that just calls the whole document changed. A set
        // built over a document that was never edited has to be empty, and one
        // built over a run of edits that cancelled out has to be empty too —
        // the diffing pass exists precisely to notice that.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 29 &+ 7)
            let editor = try Editor(extensions: fuzzKit())
            var log: [String] = []

            // Warm the document up so the no-op runs against real content
            // rather than the empty starting paragraph.
            for _ in 0 ..< 8 { log.append(fuzzStep(editor, &rng)) }

            let doc = editor.doc
            var set = ChangeSet<Int>.create(doc)
            // A transaction that changes nothing still carries maps, and they
            // still get added: a selection move, a command that declined.
            for _ in 0 ..< 6 {
                let tr = editor.state.tr
                _ = try? tr.insertText("q", Swift.min(1, tr.doc.content.size))
                _ = try? tr.delete(Swift.min(1, tr.doc.content.size), Swift.min(2, tr.doc.content.size))
                guard tr.doc == doc else { continue } // the pair didn't cancel; skip
                set = set.addSteps(tr.doc, tr.mapping.maps, 0)
            }
            try expect(set.changes.isEmpty,
                       "a changeset over edits that cancelled out reports \(set.changes.count) change(s) at seed \(seed) — \(log.suffix(3).joined(separator: " | "))")
        }
    }

    test("changeset fuzz: adding every map at once is as sound as adding them one at a time") {
        // The two are not required to produce the *same* change list — upstream
        // says so, because the simplification pass runs after each add and sees
        // a different neighbourhood each way. What they are both required to be
        // is correct: a batch add is the path a document rebuilt from a saved
        // step log takes, and nothing was holding it to the invariants the
        // incremental path is held to above.
        try eachFuzzChangeSetBatch { batch, docA, docB, ctx in
            try checkChangesWellFormed(batch, docA, docB, ctx)
            try checkChangesOffsetsAccumulate(batch, ctx)
            try checkNothingOutsideTheChangesMoved(batch, docA, docB, ctx)
        }
    }
}

// MARK: - The invariants

/// Ranges in bounds, in order, non-overlapping, with span lists that add up.
private func checkChangesWellFormed(_ set: ChangeSet<Int>, _ docA: Node, _ docB: Node,
                                    _ ctx: () -> String) throws {
    var previousA = 0, previousB = 0
    for (i, change) in set.changes.enumerated() {
        let what = "change \(i) [\(change.fromA),\(change.toA) -> \(change.fromB),\(change.toB)] — \(ctx())"
        try expect(change.fromA <= change.toA, "the old range runs backwards: \(what)")
        try expect(change.fromB <= change.toB, "the new range runs backwards: \(what)")
        try expect(change.fromA >= 0 && change.toA <= docA.content.size,
                   "the old range leaves a document of \(docA.content.size): \(what)")
        try expect(change.fromB >= 0 && change.toB <= docB.content.size,
                   "the new range leaves a document of \(docB.content.size): \(what)")
        try expect(change.fromA >= previousA, "the old ranges overlap or run out of order: \(what)")
        try expect(change.fromB >= previousB, "the new ranges overlap or run out of order: \(what)")
        // The span lists are the metadata track changes colours by, and they
        // are addressed by offset into the range. A list whose lengths don't
        // add up to the range paints the wrong text.
        try expectEqual(spanLength(change.deleted), change.toA - change.fromA,
                        "the deleted spans don't add up to the old range: \(what)")
        try expectEqual(spanLength(change.inserted), change.toB - change.fromB,
                        "the inserted spans don't add up to the new range: \(what)")
        // A change that neither deletes nor inserts is not a change, and it is
        // the shape that makes a consumer draw an empty highlight at a position
        // it then can't explain.
        try expect(change.toA > change.fromA || change.toB > change.fromB, "an empty change: \(what)")
        previousA = change.toA
        previousB = change.toB
    }
}

/// `fromB - fromA` is the running total of what the earlier changes moved.
private func checkChangesOffsetsAccumulate(_ set: ChangeSet<Int>, _ ctx: () -> String) throws {
    var offset = 0
    for (i, change) in set.changes.enumerated() {
        try expectEqual(change.fromB - change.fromA, offset,
                        "change \(i) starts \(change.fromB - change.fromA) along when the changes before it moved things by \(offset) — \(ctx())")
        offset += (change.toB - change.fromB) - (change.toA - change.fromA)
    }
}

/// Between two reported changes the two documents hold the same content.
private func checkNothingOutsideTheChangesMoved(_ set: ChangeSet<Int>, _ docA: Node, _ docB: Node,
                                                _ ctx: () -> String) throws {
    var previousA = 0, previousB = 0
    for (i, change) in set.changes.enumerated() {
        try compareGap(docA, previousA, change.fromA, docB, previousB, change.fromB,
                       "before change \(i) — \(ctx())")
        previousA = change.toA
        previousB = change.toB
    }
    try compareGap(docA, previousA, docA.content.size, docB, previousB, docB.content.size,
                   "after the last change — \(ctx())")
}

// MARK: - The comparison

/// Whether two stretches of document hold the same content.
///
/// Compared through a signature of what lies *inside* the range rather than
/// through `Fragment.cut`, and the difference matters. `cut` keeps the whole
/// wrapper of any node the range only partly covers — cut two units out of the
/// middle of a table cell and you get back a table, a row and a cell around
/// them — so comparing cuts asks the two documents to agree about structure
/// that begins outside the range being compared. A changeset never claimed
/// that: the tokens opening those wrappers sit outside the gap, inside ranges
/// it has already reported as changed. Asking anyway turns "a paragraph moved
/// into a table" into a failure about the paragraph's own untouched text.
///
/// So the signature carries only what the range actually contains: text,
/// clipped to the range, and the nodes whose opening token falls inside it. It
/// stays sensitive to everything a step map can express — text, order, and
/// structure introduced within the range — and is blind to the wrappers the
/// changeset never spoke for, and to the marks and attributes no step map
/// carries (see the property that uses this).
private func compareGap(_ docA: Node, _ fromA: Int, _ toA: Int,
                        _ docB: Node, _ fromB: Int, _ toB: Int,
                        _ ctx: @autoclosure () -> String) throws {
    guard toA >= fromA, toB >= fromB else { return } // reported elsewhere
    try expectEqual(toA - fromA, toB - fromB,
                    "the untouched stretch \(fromA)..\(toA) is \(toB - fromB) long in the new document — \(ctx())")
    let a = contentSignature(docA, fromA, toA)
    let b = contentSignature(docB, fromB, toB)
    try expect(a == b, """
        the changeset says \(fromA)..\(toA) was untouched, but \(fromB)..\(toB) doesn't match it — \(ctx())
          old: \(a)
          new: \(b)
        """)
}

/// What a range holds: the text in it with its marks, and the nodes that open
/// inside it. A wrapper that merely spans the range is not part of it.
private func contentSignature(_ doc: Node, _ from: Int, _ to: Int) -> String {
    guard from < to, to <= doc.content.size else { return "" }
    var out: [String] = []
    var text = ""
    doc.nodesBetween(from, to) { node, pos, _, _ in
        if let nodeText = node.text {
            // Clipped: a text node straddling an edge contributes only the
            // characters actually inside the range. Accumulated across nodes
            // rather than listed per node, because a mark applied to half a run
            // splits one text node into two without moving a character, and the
            // changeset — which sees only step maps — is right to call that
            // range untouched.
            let chars = Array(nodeText)
            let lo = Swift.max(0, from - pos)
            let hi = Swift.min(chars.count, to - pos)
            if lo < hi { text += String(chars[lo ..< hi]) }
        } else {
            if !text.isEmpty { out.append(text.debugDescription); text = "" }
            if pos >= from, pos < to { out.append("<\(node.type.name)>") }
        }
        return true
    }
    if !text.isEmpty { out.append(text.debugDescription) }
    return out.joined(separator: " ")
}

private func spanLength<Data>(_ spans: [Span<Data>]) -> Int {
    spans.reduce(0) { $0 + $1.length }
}

// MARK: - Driving the sweeps

/// Run `check` over the changeset built from a growing run of random edits.
///
/// The set is checked after every operation rather than once at the end, so a
/// change list that only goes wrong at the fortieth edit is reported at the
/// edit that broke it rather than as a mismatch between two finished documents.
///
/// The bookkeeping around `expected` is what makes that safe. Plugins append
/// transactions of their own behind the user's back — table fixing squares up a
/// ragged table, the unique-id plugin stamps a fresh node — and `Editor`
/// reports only the root transaction, so those edits reach the document without
/// their maps ever reaching the set. Checking against the editor's document
/// then would report the plugin's own work as content the changeset lost. So
/// the sweep tracks the document the set was actually told about, and starts a
/// fresh set from wherever a plugin left things whenever the two part company.
private func eachFuzzChangeSet(_ check: (ChangeSet<Int>, Node, Node, () -> String) throws -> Void) throws {
    for seed in 1 ... fuzzOpSeeds {
        var rng = SelRNG(seed &* 17 &+ 9)
        let recorder = try FuzzRecorder()
        var log: [String] = []
        var base = recorder.editor.doc
        var expected = base
        var set = ChangeSet<Int>.create(base)
        for i in 0 ..< fuzzOpChangeSetCount {
            let (what, trs) = recorder.step(&rng)
            log.append(what)
            for tr in trs where tr.docChanged {
                guard tr.docs.first == expected else { break }
                set = set.addSteps(tr.doc, tr.mapping.maps, i)
                expected = tr.doc
            }
            guard recorder.editor.doc == expected else {
                base = recorder.editor.doc
                expected = base
                set = ChangeSet<Int>.create(base)
                continue
            }
            try check(set, base, expected) {
                "seed \(seed) op \(i) — \(log.suffix(4).joined(separator: " | "))"
            }
        }
    }
}

/// The set built from every map at once, against the same run of edits the
/// incremental sweep drives. The incremental set is built alongside it — not to
/// compare the two (upstream says they may simplify differently) but because
/// building it is what keeps the two sweeps driving the same sessions.
private func eachFuzzChangeSetBatch(_ check: (ChangeSet<Int>, Node, Node, () -> String) throws -> Void) throws {
    for seed in 1 ... fuzzOpSeeds {
        var rng = SelRNG(seed &* 19 &+ 11)
        let recorder = try FuzzRecorder()
        var log: [String] = []
        var base = recorder.editor.doc
        var expected = base
        var incremental = ChangeSet<Int>.create(base)
        var allMaps: [StepMap] = []
        for i in 0 ..< fuzzOpChangeSetCount {
            let (what, trs) = recorder.step(&rng)
            log.append(what)
            for tr in trs where tr.docChanged {
                guard tr.docs.first == expected else { break }
                incremental = incremental.addSteps(tr.doc, tr.mapping.maps, 0)
                allMaps.append(contentsOf: tr.mapping.maps)
                expected = tr.doc
            }
            // Same resync as above; the batch has to be rebuilt from the new
            // base too, or its maps describe an edit that never happened.
            guard recorder.editor.doc == expected else {
                base = recorder.editor.doc
                expected = base
                incremental = ChangeSet<Int>.create(base)
                allMaps = []
                continue
            }
            guard !allMaps.isEmpty else { continue }
            let batch = ChangeSet<Int>.create(base).addSteps(expected, allMaps, 0)
            try check(batch, base, expected) {
                "seed \(seed) op \(i) — \(log.suffix(4).joined(separator: " | "))"
            }
        }
    }
}

/// Shorter runs than the step sweeps: each op re-walks the whole change list,
/// which makes a session quadratic in its own length.
let fuzzOpChangeSetCount = 25
