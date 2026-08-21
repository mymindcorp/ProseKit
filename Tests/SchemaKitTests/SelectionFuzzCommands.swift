import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorHistory
import SchemaKit
import TestDocGen
import TestHarness

// The second half of the selection fuzzer: the things that *move* a selection
// rather than construct one — commands, history, caret navigation — plus the
// algebraic laws the selection types are supposed to obey. Same corpus, same
// opt-in switch as `registerSelectionFuzzTests`.

/// The base commands, by name so a failure says which one. Every one of these
/// either moves the selection or acts on it.
private func fuzzCommands(_ schema: Schema) -> [(String, Command)] {
    var out: [(String, Command)] = [
        ("deleteSelection", deleteSelection),
        ("joinBackward", joinBackward),
        ("joinForward", joinForward),
        ("joinTextblockBackward", joinTextblockBackward),
        ("joinTextblockForward", joinTextblockForward),
        ("selectNodeBackward", selectNodeBackward),
        ("selectNodeForward", selectNodeForward),
        ("joinUp", joinUp),
        ("joinDown", joinDown),
        ("lift", lift),
        ("newlineInCode", newlineInCode),
        ("exitCode", exitCode),
        ("createParagraphNear", createParagraphNear),
        ("liftEmptyBlock", liftEmptyBlock),
        ("splitBlock", splitBlock),
        ("splitBlockKeepMarks", splitBlockKeepMarks),
        ("selectParentNode", selectParentNode),
        ("selectAll", selectAll),
        ("selectTextblockStart", selectTextblockStart),
        ("selectTextblockEnd", selectTextblockEnd),
    ]
    if let bold = schema.marks["bold"] { out.append(("toggleMark(bold)", toggleMark(bold))) }
    if let quote = schema.nodes["blockquote"] { out.append(("wrapIn(blockquote)", wrapIn(quote))) }
    if let heading = schema.nodes["heading"] {
        out.append(("setBlockType(heading)", setBlockType(heading, ["level": .int(2)])))
    }
    if let para = schema.nodes["paragraph"] { out.append(("setBlockType(paragraph)", setBlockType(para))) }
    return out
}

func registerSelectionCommandFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    // MARK: commands

    test("selection fuzz: a command's dry run agrees with its real run and changes nothing") {
        // Two contracts every ProseMirror-style command owes its caller:
        // asked without a `dispatch` it is a pure question, and the answer it
        // gives is the same one it would give while doing the work. A command
        // that says no must not have dispatched anything on the way to saying it.
        let schema = try fuzzSchema()
        let commands = fuzzCommands(schema)
        var rng = SelRNG(11)
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            let base = fuzzState(doc, schema)
            let selections = everySelection(in: doc)
            for _ in 0 ..< 24 {
                let sel = selections[Int.random(in: 0 ..< selections.count, using: &rng)]
                let state = base.apply(base.tr.setSelection(sel))
                for (name, command) in commands {
                    let ctx = "\(name) on \(describeSelection(sel)) at \(seed)"

                    let asked = command(state, nil, nil)
                    try expect(state.doc == doc, "a dry run of \(ctx) changed the document")
                    try expect(state.selection.eq(sel), "a dry run of \(ctx) changed the selection")

                    var dispatched: [Transaction] = []
                    let did = command(state, { dispatched.append($0) }, nil)
                    try expectEqual(did, asked, "the dry run and the real run disagree — \(ctx)")
                    if !did {
                        try expect(dispatched.isEmpty, "\(ctx) returned false but dispatched \(dispatched.count)")
                        continue
                    }
                    try expect(state.doc == doc, "running \(ctx) mutated the state it was given")
                    guard let tr = dispatched.first else { continue }

                    let after = state.apply(tr)
                    var invalid: (any Error)?
                    do { try after.doc.check() } catch { invalid = error }
                    try expect(invalid == nil, "\(ctx) produced an invalid document: \(invalid.map { "\($0)" } ?? "")")
                    try checkSelectionValid(after.selection, in: after.doc, "after \(ctx)")
                    try checkSelectionRoundTrips(after.selection, in: after.doc, "after \(ctx)")
                }
            }
        }
    }

    test("selection fuzz: every step a command produces inverts back to the document it started from") {
        // The property undo is built on. Checked per step rather than per
        // transaction, so a command that emits several says which one broke.
        let schema = try fuzzSchema()
        let commands = fuzzCommands(schema)
        var rng = SelRNG(13)
        var checked = 0
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            let base = fuzzState(doc, schema)
            let selections = everySelection(in: doc)
            for _ in 0 ..< 40 {
                let sel = selections[Int.random(in: 0 ..< selections.count, using: &rng)]
                let state = base.apply(base.tr.setSelection(sel))
                let (name, command) = commands[Int.random(in: 0 ..< commands.count, using: &rng)]
                var dispatched: Transaction?
                guard command(state, { dispatched = $0 }, nil), let tr = dispatched, tr.docChanged else { continue }

                // Walk forwards recording each step's input, then invert back.
                var forward: [Node] = [doc]
                for step in tr.steps {
                    guard let next = step.apply(forward.last!).doc else { break }
                    forward.append(next)
                }
                guard forward.count == tr.steps.count + 1 else { continue }
                var back = forward.last!
                for (i, step) in tr.steps.enumerated().reversed() {
                    let ctx = "step \(i) of \(name) on \(describeSelection(sel)) at \(seed)"
                    let result = step.invert(forward[i]).apply(back)
                    try expect(result.failed == nil, "an inverted step wouldn't apply — \(ctx): \(result.failed ?? "")")
                    guard let undone = result.doc else { break }
                    back = undone
                    checked += 1
                }
                try expect(back == doc, "inverting every step of \(name) didn't restore the document at \(seed)")
            }
        }
        try expect(checked > 200, "only \(checked) steps were inverted")
    }

    // MARK: history

    test("selection fuzz: undo puts the document and the selection back") {
        let schema = try fuzzSchema()
        let commands = fuzzCommands(schema)
        var rng = SelRNG(17)
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            let selections = everySelection(in: doc)
            for _ in 0 ..< 12 {
                let sel = selections[Int.random(in: 0 ..< selections.count, using: &rng)]
                let (name, command) = commands[Int.random(in: 0 ..< commands.count, using: &rng)]

                // A fresh state per attempt, so the history holds exactly one event.
                var state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, plugins: [history()]))
                state = state.apply(state.tr.setSelection(sel))
                let before = state
                guard command(state, { state = state.apply($0) }, nil), state.doc != before.doc else { continue }
                let ctx = "\(name) on \(describeSelection(sel)) at \(seed)"
                let edited = state

                guard undo(state, { state = state.apply($0) }) else {
                    try expect(false, "nothing to undo after \(ctx)")
                    continue
                }
                try expect(state.doc == doc, "undo didn't restore the document after \(ctx)")
                try checkSelectionValid(state.selection, in: state.doc, "after undoing \(ctx)")
                // A bookmark for a node the change removed degrades to a caret
                // on the way back — that is what bookmarks are for. A text
                // cursor has no such excuse: undo has to put it back.
                if before.selection is TextSelection {
                    try expect(state.selection.eq(before.selection),
                               "undo left the cursor at \(describeSelection(state.selection)) instead of \(describeSelection(before.selection)) — \(ctx)")
                }

                guard redo(state, { state = state.apply($0) }) else {
                    try expect(false, "nothing to redo after \(ctx)")
                    continue
                }
                try expect(state.doc == edited.doc, "redo didn't reproduce the edit after \(ctx)")
                try checkSelectionValid(state.selection, in: state.doc, "after redoing \(ctx)")
            }
        }
    }

    // MARK: mapping algebra

    test("selection fuzz: mapping a bookmark in two hops matches mapping it in one") {
        // `Mapping` composition has to be associative from the bookmark's point
        // of view, or a selection restored after a multi-step transaction (a
        // command, a paste, a rebased collab step) lands somewhere else than
        // the same edits applied one at a time.
        let schema = try fuzzSchema()
        var rng = SelRNG(23)
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            let base = fuzzState(doc, schema)
            let typable = (0 ... doc.content.size).filter { doc.resolve($0).parent.inlineContent }
            guard typable.count >= 2 else { continue }
            let selections = everySelection(in: doc)
            for _ in 0 ..< 8 {
                let tr = base.tr
                let first = typable.randomElement(using: &rng)!
                guard (try? tr.insertText("ab", first)) != nil else { continue }
                let size = tr.doc.content.size
                let second = Int.random(in: 0 ... size, using: &rng)
                _ = try? tr.delete(Swift.min(second, size), Swift.min(second + 2, size))
                guard tr.steps.count >= 2 else { continue }

                let whole = tr.mapping
                let firstHalf = whole.slice(0, 1)
                let rest = whole.slice(1)
                for sel in selections {
                    let ctx = "\(describeSelection(sel)) at \(seed) through \(tr.steps.count) steps"
                    let oneHop = sel.getBookmark().map(whole).resolve(tr.doc)
                    let twoHops = sel.getBookmark().map(firstHalf).map(rest).resolve(tr.doc)
                    try expect(oneHop.eq(twoHops),
                               "one hop gave \(describeSelection(oneHop)), two hops gave \(describeSelection(twoHops)) — \(ctx)")
                    try checkSelectionValid(oneHop, in: tr.doc, "bookmark mapped in one hop — \(ctx)")
                }
            }
        }
    }

    // MARK: caret navigation

    test("selection fuzz: caret moves stay in the document and travel the way they were asked to") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            let size = doc.content.size
            for pos in 0 ... size {
                let resolved = doc.resolve(pos)
                for granularity in [TextGranularity.character, .word, .lineBoundary] {
                    for direction in [TextDirection.forward, .backward] {
                        let to = TextNavigation.position(in: doc, from: pos, moving: direction, by: granularity)
                        let ctx = "\(granularity) \(direction) from \(pos) at \(seed)"
                        try expect(to >= 0 && to <= size, "a caret move left the document, to \(to) — \(ctx)")
                        // Direction only means anything from somewhere a caret
                        // can be. Asked to move from a structural position the
                        // navigator snaps to the nearest real one first, which
                        // can be on either side.
                        if resolved.parent.inlineContent {
                            if direction == .forward {
                                try expect(to >= pos, "a forward move went backwards, to \(to) — \(ctx)")
                            } else {
                                try expect(to <= pos, "a backward move went forwards, to \(to) — \(ctx)")
                            }
                        }
                        // The result is a *step target*, not necessarily a
                        // caret spot: stepping forward out of the last
                        // paragraph of `doc(p, figure(image))` lands after the
                        // image, and it is `Selection.near` — which every
                        // caller runs — that turns that into a node selection
                        // on the image. So what has to hold is that the target
                        // is somewhere a selection can be placed at all.
                        let placed = Selection.near(doc.resolve(to), direction.sign)
                        try checkSelectionValid(placed, in: doc, "placing a caret move at \(to) — \(ctx)")
                    }
                }

                // The edges of a line are fixed points, and they bracket the block.
                guard resolved.parent.inlineContent else { continue }
                let start = TextNavigation.position(in: doc, from: pos, moving: .backward, by: .lineBoundary)
                let end = TextNavigation.position(in: doc, from: pos, moving: .forward, by: .lineBoundary)
                let ctx = "line edges of \(pos) at \(seed)"
                try expectEqual(start, resolved.start(), "the line start isn't the textblock start — \(ctx)")
                try expectEqual(end, resolved.end(), "the line end isn't the textblock end — \(ctx)")
                try expectEqual(TextNavigation.position(in: doc, from: start, moving: .backward, by: .lineBoundary),
                                start, "moving to the line start twice moved again — \(ctx)")
                try expectEqual(TextNavigation.position(in: doc, from: end, moving: .forward, by: .lineBoundary),
                                end, "moving to the line end twice moved again — \(ctx)")
            }
        }
    }

    test("selection fuzz: a character forward and back returns to where it started") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            for pos in 0 ... doc.content.size where doc.resolve(pos).parent.inlineContent {
                let forward = TextNavigation.position(in: doc, from: pos, moving: .forward, by: .character)
                guard forward != pos else { continue }
                let back = TextNavigation.position(in: doc, from: forward, moving: .backward, by: .character)
                try expectEqual(back, pos, "a character out and back from \(pos) landed at \(back) (via \(forward)) at \(seed)")
            }
        }
    }

    // MARK: the laws the types are supposed to obey

    test("selection fuzz: equality is reflexive and symmetric across every pair") {
        let schema = try fuzzSchema()
        var rng = SelRNG(41)
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            var pool = everySelection(in: doc)
            // A sample, since this is quadratic.
            if pool.count > 60 { pool = (0 ..< 60).map { _ in pool.randomElement(using: &rng)! } }
            for a in pool {
                try expect(a.eq(a), "\(describeSelection(a)) isn't equal to itself at \(seed)")
                for b in pool {
                    try expectEqual(a.eq(b), b.eq(a),
                                    "equality isn't symmetric between \(describeSelection(a)) and \(describeSelection(b)) at \(seed)")
                }
            }
        }
    }

    test("selection fuzz: near and between are fixed points on their own results") {
        // Placing a selection is a search for the nearest valid spot. Searching
        // again from the spot it found has to stop there — otherwise a caret
        // could be walked across the document one no-op placement at a time.
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            for pos in 0 ... doc.content.size {
                let resolved = doc.resolve(pos)
                for bias in [1, -1] {
                    let near = Selection.near(resolved, bias)
                    let ctx = "near(\(bias)) at \(pos) in \(seed)"
                    // From the edge the search came to rest against: a forward
                    // search reports where its find *starts*, a backward one
                    // where it ends, so those are the positions that must be
                    // stable. (`head` is past a node selection's node, and
                    // searching forward from there rightly finds the next one.)
                    let again = Selection.near(bias > 0 ? near.resolvedFrom : near.resolvedTo, bias)
                    try expect(again.eq(near),
                               "near settled on \(describeSelection(near)) then moved to \(describeSelection(again)) — \(ctx)")
                    if let text = near as? TextSelection {
                        let between = TextSelection.between(text.resolvedAnchor, text.resolvedHead)
                        try expect(between.eq(text),
                                   "between moved a selection near had already settled: \(describeSelection(between)) — \(ctx)")
                    }
                }
            }
        }
    }
}
