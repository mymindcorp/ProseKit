import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for the step layer.
//
// Everything above `DocumentTransform` — undo, collaboration, changesets, the
// incremental renderer — rests on four promises a `Step` makes: that inverting
// it undoes it, that its map describes the edit it made, that merging two of
// them changes nothing, and that mapping one through another leaves something
// that still applies. None of those was checked against the steps the *editor*
// produces. The hand-written suites drive steps they built themselves; the
// commands build far stranger ones — a `ReplaceAroundStep` from a list lift, a
// `RemoveMarkStep` split across a table row — and those are the ones that
// actually get inverted and rebased in the field.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerTransformFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    // MARK: invert

    test("transform fuzz: inverting a step undoes it exactly") {
        // The promise undo is built on. `invert` is handed the document the step
        // ran *on*, and its result applied to the document the step *produced*
        // has to give that document back — not an equivalent one, the same one.
        try eachFuzzStep("invert") { step, docBefore, _, ctx in
            guard let docAfter = step.apply(docBefore).doc else { return }
            let inverted = step.invert(docBefore)
            let result = inverted.apply(docAfter)
            try expect(result.doc != nil,
                       "the inverse of a step that applied cleanly failed — \(ctx()): \(result.failed ?? "")")
            try expect(result.doc == docBefore, "inverting a step didn't restore the document — \(ctx())")
        }
    }

    // MARK: JSON

    test("transform fuzz: steps survive the round-trip a peer would put them through") {
        // Collaboration sends steps as JSON. A step that decodes into something
        // that edits differently is a silent divergence between two clients,
        // which is the worst shape a bug in this layer can take.
        // The editor's own schema, not an equivalent one: a step decoded
        // against a second `Schema` instance carries node types that aren't
        // identical to the document's, and the comparison would fail on that
        // rather than on anything the round-trip did.
        try eachFuzzStep("json") { step, docBefore, schema, ctx in
            let decoded = try decodeStep(schema, step.toJSON())
            try expectEqual(decoded.jsonID, step.jsonID, "the step decoded as a different kind — \(ctx())")
            try expect(decoded.apply(docBefore).doc == step.apply(docBefore).doc,
                       "a step and its JSON round-trip edit differently — \(ctx())")
            // The map has to survive too, or every position a peer rebases
            // through the decoded step lands somewhere else.
            let a = step.getMap(), b = decoded.getMap()
            for pos in 0 ... docBefore.content.size {
                for bias in [1, -1] {
                    try expectEqual(a.map(pos, bias), b.map(pos, bias),
                                    "the decoded step maps \(pos) elsewhere — \(ctx())")
                }
            }
        }
    }

    // MARK: the map matches the edit

    test("transform fuzz: a step's map agrees with the document it produced") {
        // `getMap` is the only thing ever asked where a position went —
        // selections, decorations, cursors and collab all trust it without
        // looking at the documents. So it has to describe the edit that actually
        // happened: every position lands inside the new document, and the two
        // biases don't cross over each other.
        try eachFuzzStep("map") { step, docBefore, _, ctx in
            guard let docAfter = step.apply(docBefore).doc else { return }
            let map = step.getMap()
            let newSize = docAfter.content.size
            var previous = 0
            for pos in 0 ... docBefore.content.size {
                let forward = map.map(pos, 1), back = map.map(pos, -1)
                try expect(forward >= 0 && forward <= newSize,
                           "mapping \(pos) forward left the document, at \(forward) in a doc of \(newSize) — \(ctx())")
                try expect(back >= 0 && back <= newSize,
                           "mapping \(pos) backward left the document, at \(back) in a doc of \(newSize) — \(ctx())")
                try expect(back <= forward,
                           "the two biases crossed at \(pos): backward \(back) is past forward \(forward) — \(ctx())")
                // Order is what makes a map usable for a range: the start of a
                // range can never map past its end.
                try expect(forward >= previous,
                           "mapping is not monotonic: \(pos) went to \(forward), behind \(previous) — \(ctx())")
                previous = forward
                let result = map.mapResult(pos, 1)
                if !result.deleted { try expectEqual(result.pos, forward, "mapResult disagrees with map — \(ctx())") }
            }
            // And the inverted map takes everything back where it came from.
            let inverse = map.invert()
            for pos in 0 ... newSize {
                let there = inverse.map(pos, 1)
                try expect(there >= 0 && there <= docBefore.content.size,
                           "the inverse map sent \(pos) to \(there), outside a doc of \(docBefore.content.size) — \(ctx())")
            }
        }
    }

    // MARK: merge

    test("transform fuzz: merging two steps edits exactly as running both does") {
        // `merge` is an optimization — history compression and the collab send
        // queue both lean on it. An optimization that changes the result is a
        // corruption, so the merged step has to produce the very document the
        // pair produced.
        try eachConsecutiveFuzzPair("merge") { first, second, docBefore, ctx in
            guard let merged = first.merge(second) else { return }
            let separately = first.apply(docBefore).doc.flatMap { second.apply($0).doc }
            guard separately != nil else { return } // the pair itself didn't apply
            let together = merged.apply(docBefore).doc
            try expect(together != nil, "a merged step failed where the pair applied — \(ctx())")
            try expect(together == separately, "merging two steps changed what they do — \(ctx())")
        }
    }

    // MARK: rebase

    test("transform fuzz: a rebased step either fails or produces a real document") {
        // The rebase primitive. A mapped step is allowed to *fail* — the
        // concurrent edit may have taken away the ground it stood on, and
        // `rebaseSteps` drops it — and it is allowed to be dropped outright by
        // `map` returning nil. What it may not do is succeed into a document
        // the schema rejects: that one is not reported anywhere, it just
        // arrives, and it arrives identically on every peer.
        try eachFuzzFork("rebase") { mine, theirs, shared, ctx in
            // `mine` and `theirs` were both written against `shared`; theirs
            // landed first, so mine has to be mapped over it.
            guard let overDoc = theirs.apply(shared).doc else { return }
            guard let rebased = mine.map(theirs.getMap()) else { return }
            guard let doc = rebased.apply(overDoc).doc else { return }
            var invalid: (any Error)?
            do { try doc.check() } catch { invalid = error }
            try expect(invalid == nil,
                       "a rebased step produced an invalid document — \(ctx()): \(invalid.map { "\($0)" } ?? "")")
            // And the step's own map has to describe what it did, or the next
            // rebase over it puts everything in the wrong place.
            let map = rebased.getMap()
            for pos in 0 ... overDoc.content.size {
                let there = map.map(pos, 1)
                try expect(there >= 0 && there <= doc.content.size,
                           "a rebased step's map sent \(pos) to \(there), outside a doc of \(doc.content.size) — \(ctx())")
            }
        }
    }
}

// MARK: - Driving the sweeps

/// How many random editing sessions each sweep runs, and how long each one is.
///
/// Shared by the step, history and collaboration sweeps, which all drive a live
/// editor rather than inspecting a static document — `PROSEKIT_FUZZ_DOCS` sizes
/// the corpus and does nothing for them. Sized so the whole opt-in suite still
/// finishes in a coffee break; `PROSEKIT_FUZZ_OPS=200` is the ad-hoc hunt.
let fuzzOpSeeds = UInt64(ProcessInfo.processInfo.environment["PROSEKIT_FUZZ_OPS"].flatMap(Int.init) ?? 40)
let fuzzOpCount = 60

/// Run `check` over every step the editor produces across every seed.
///
/// The recent operation log goes into the context: a property that fails 40 ops
/// into a seed is unreadable without knowing what got it there, and re-deriving
/// that from the seed means replaying the RNG by hand.
private func eachFuzzStep(_ label: String,
                          _ check: (any Step, Node, Schema, () -> String) throws -> Void) throws {
    for seed in 1 ... fuzzOpSeeds {
        var rng = SelRNG(seed)
        let recorder = try FuzzRecorder()
        var log: [String] = []
        for _ in 0 ..< fuzzOpCount {
            let (what, trs) = recorder.step(&rng)
            log.append(what)
            for (step, doc) in fuzzSteps(trs) {
                try check(step, doc, recorder.editor.schema) {
                    "\(label) seed \(seed) on \(step.jsonID) — \(log.suffix(4).joined(separator: " | "))"
                }
            }
        }
    }
}

/// The same, over consecutive pairs of steps — the shape `merge` is defined on:
/// `second` runs on the document `first` produced.
private func eachConsecutiveFuzzPair(_ label: String,
                          _ check: (any Step, any Step, Node, () -> String) throws -> Void) throws {
    for seed in 1 ... fuzzOpSeeds {
        var rng = SelRNG(seed)
        let recorder = try FuzzRecorder()
        var log: [String] = []
        var previous: (step: any Step, doc: Node)?
        for _ in 0 ..< fuzzOpCount {
            let (what, trs) = recorder.step(&rng)
            log.append(what)
            for (step, doc) in fuzzSteps(trs) {
                defer { previous = (step, doc) }
                // Consecutive means the older step's own result is this step's
                // document — steps from two different transactions have an
                // applied plugin transaction between them and don't compose.
                guard let older = previous, older.step.apply(older.doc).doc == doc else { continue }
                try check(older.step, step, older.doc) {
                    "\(label) seed \(seed) on \(older.step.jsonID) + \(step.jsonID) — \(log.suffix(4).joined(separator: " | "))"
                }
            }
        }
    }
}

/// Two steps written against the *same* document — the shape a rebase is
/// defined on, and one a sequential edit stream never produces on its own. So
/// fork: run the same document into two editors and give each a different
/// random operation, exactly as two peers editing at the same version would.
private func eachFuzzFork(_ label: String,
                          _ check: (any Step, any Step, Node, () -> String) throws -> Void) throws {
    for seed in 1 ... fuzzOpSeeds {
        var rng = SelRNG(seed)
        let recorder = try FuzzRecorder()
        var log: [String] = []
        for _ in 0 ..< fuzzOpCount {
            log.append(recorder.step(&rng).what)
            let shared = recorder.editor.doc
            // Two independent editors over the same document. Their RNGs are
            // seeded apart so they pick different operations.
            var mineRNG = SelRNG(seed &* 31 &+ UInt64(log.count))
            var theirsRNG = SelRNG(seed &* 131 &+ UInt64(log.count))
            guard let mine = try forkedStep(shared, &mineRNG),
                  let theirs = try forkedStep(shared, &theirsRNG) else { continue }
            for (a, _) in mine {
                for (b, _) in theirs {
                    try check(a, b, shared) {
                        "\(label) seed \(seed) on \(a.jsonID) over \(b.jsonID) — \(log.suffix(3).joined(separator: " | "))"
                    }
                }
            }
        }
    }
}

/// One random operation applied to a fresh editor loaded with `doc`, returning
/// the steps it produced against that very document.
private func forkedStep(_ doc: Node, _ rng: inout SelRNG) throws -> [(step: any Step, doc: Node)]? {
    let fork = try FuzzRecorder(fuzzKit(), content: doc)
    // Loading content can itself normalize the document (fixing a table, adding
    // a missing ID); a step written against something other than `doc` isn't the
    // concurrent edit this property is about.
    guard fork.editor.doc == doc else { return nil }
    // Only the steps still written against `doc` itself: a transaction's later
    // steps run on the documents its earlier ones produced.
    return fuzzSteps(fork.step(&rng).transactions).filter { $0.doc == doc }
}
