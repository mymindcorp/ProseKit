import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

/// Opt-in, like the benchmarks: the sweeps are exhaustive over every position
/// in every generated document, which is far more work than the rest of the
/// suite put together. Run them with
///
///     PROSEKIT_FUZZ=1 swift run SchemaKitTests
///
/// and narrow to one case with `PROSEKIT_TEST_FILTER=<substring>`.
func registerSelectionFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    // MARK: coverage

    test("selection fuzz: the corpus contains every node type the schema allows") {
        let schema = try fuzzSchema()
        var seen: Set<String> = []
        for (_, doc) in fuzzCorpus(schema, count: 60) { seen.formUnion(nodeTypeNames(in: doc)) }
        let missing = reachableTypes(in: schema).map(\.name).filter { !seen.contains($0) }
        try expect(missing.isEmpty, "never generated: \(missing.sorted())")
        // And every generated document is a document the schema would accept.
        for (seed, doc) in fuzzCorpus(schema, count: 60) {
            var invalid: (any Error)?
            do { try doc.check() } catch { invalid = error }
            try expect(invalid == nil, "the generator produced an invalid doc at \(seed): \(invalid.map { "\($0)" } ?? "")")
        }
    }

    // MARK: every position in every document

    test("selection fuzz: near/findFrom land on valid, correctly-directed positions") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 40) {
            let pristine = doc
            let atStart = Selection.atStart(doc), atEnd = Selection.atEnd(doc)
            try checkSelectionValid(atStart, in: doc, "atStart at \(seed)")
            try checkSelectionValid(atEnd, in: doc, "atEnd at \(seed)")

            for pos in 0 ... doc.content.size {
                let resolved = doc.resolve(pos)
                let ctx = "\(seed) pos \(pos) (in \(resolved.parent.type.name))"

                for bias in [1, -1] {
                    let near = Selection.near(resolved, bias)
                    // `near` is defined as "the biased search, or the other way,
                    // or the whole document" — so when the biased search finds
                    // something, that is exactly what `near` must return.
                    if let biased = Selection.findFrom(resolved, bias) {
                        try expect(near.eq(biased),
                                   "near(\(bias)) returned \(describeSelection(near)) but findFrom(\(bias)) found \(describeSelection(biased)) at \(ctx)")
                    }
                    try checkSelectionValid(near, in: doc, "near(bias: \(bias)) at \(ctx)")
                    // A position that already takes a caret is the answer.
                    if resolved.parent.inlineContent {
                        try expectEqual(near.anchor, pos, "near moved a caret that was already valid at \(ctx)")
                        try expectEqual(near.head, pos, "near moved a caret that was already valid at \(ctx)")
                    }
                    // Nothing can be found before the start, or after the end.
                    try expect(near.from >= atStart.from, "near(\(bias)) landed before atStart at \(ctx)")
                    try expect(near.to <= atEnd.to, "near(\(bias)) landed after atEnd at \(ctx)")
                }

                // A directional search only ever moves that way.
                for textOnly in [false, true] {
                    if let forward = Selection.findFrom(resolved, 1, textOnly: textOnly) {
                        try checkSelectionValid(forward, in: doc, "findFrom(+1, textOnly: \(textOnly)) at \(ctx)")
                        try expect(forward.from >= pos, "a forward search moved backwards to \(forward.from) at \(ctx)")
                        if textOnly { try expect(forward is TextSelection, "textOnly search returned \(type(of: forward)) at \(ctx)") }
                    }
                    if let back = Selection.findFrom(resolved, -1, textOnly: textOnly) {
                        try checkSelectionValid(back, in: doc, "findFrom(-1, textOnly: \(textOnly)) at \(ctx)")
                        try expect(back.to <= pos, "a backward search moved forwards to \(back.to) at \(ctx)")
                        if textOnly { try expect(back is TextSelection, "textOnly search returned \(type(of: back)) at \(ctx)") }
                    }
                }
            }
            try expect(doc == pristine, "the document changed while selections were being placed in it at \(seed)")
        }
    }

    test("selection fuzz: TextSelection.between keeps endpoints that are already valid") {
        let schema = try fuzzSchema()
        var rng = SelRNG(7)
        for (seed, doc) in fuzzCorpus(schema, count: 40) {
            let size = doc.content.size
            for anchorPos in 0 ... size {
                // Every position pairs with a handful of others rather than all
                // of them — the sweep is already quadratic in document size.
                var partners = [anchorPos, 0, size]
                for _ in 0 ..< 3 { partners.append(Int.random(in: 0 ... size, using: &rng)) }
                for headPos in partners {
                    let anchor = doc.resolve(anchorPos), head = doc.resolve(headPos)
                    let ctx = "\(seed) between \(anchorPos) and \(headPos)"
                    let sel = TextSelection.between(anchor, head)
                    try checkSelectionValid(sel, in: doc, ctx)
                    if anchor.parent.inlineContent, head.parent.inlineContent {
                        try expectEqual(sel.anchor, anchorPos, "between moved a valid anchor at \(ctx)")
                        try expectEqual(sel.head, headPos, "between moved a valid head at \(ctx)")
                    }
                    if let text = sel as? TextSelection, text.anchor != text.head, anchorPos != headPos {
                        try expectEqual(text.anchor < text.head, anchorPos < headPos,
                                        "between flipped the selection's direction at \(ctx)")
                    }
                }
            }
        }
    }

    test("selection fuzz: node selections, gap cursors and cell selections stay valid") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 40) {
            let pristine = doc
            for pos in 0 ... doc.content.size {
                let resolved = doc.resolve(pos)
                let ctx = "\(seed) pos \(pos)"

                let node = NodeSelection.create(doc, pos)
                try checkSelectionValid(node, in: doc, "NodeSelection.create at \(ctx)")
                // Where there *is* a selectable node, that is what you get.
                if let after = resolved.nodeAfter, NodeSelection.isSelectable(after) {
                    try expect(node is NodeSelection, "no node selection where one is possible at \(ctx)")
                    try expectEqual(node.anchor, pos, "node selection moved off its node at \(ctx)")
                    try expectEqual(node.head, pos + after.nodeSize, "node selection doesn't span its node at \(ctx)")
                }

                if GapCursor.valid(resolved) {
                    try checkSelectionValid(GapCursor(resolved), in: doc, "GapCursor at \(ctx)")
                }
                if let moved = GapCursor.findGapCursorFrom(resolved, 1, true) {
                    try expect(moved.pos > pos, "findGapCursorFrom(+1, mustMove) stayed at \(moved.pos) at \(ctx)")
                    try expect(GapCursor.valid(moved), "findGapCursorFrom(+1, mustMove) returned an invalid gap at \(ctx)")
                }
                if let moved = GapCursor.findGapCursorFrom(resolved, -1, true) {
                    try expect(moved.pos < pos, "findGapCursorFrom(-1, mustMove) stayed at \(moved.pos) at \(ctx)")
                    try expect(GapCursor.valid(moved), "findGapCursorFrom(-1, mustMove) returned an invalid gap at \(ctx)")
                }
                for dir in [1, -1] {
                    guard let found = GapCursor.findGapCursorFrom(resolved, dir) else { continue }
                    try expect(GapCursor.valid(found), "findGapCursorFrom(\(dir)) returned an invalid gap at \(ctx)")
                    try expect(dir > 0 ? found.pos >= pos : found.pos <= pos,
                               "findGapCursorFrom(\(dir)) moved the wrong way, to \(found.pos), at \(ctx)")
                    try checkSelectionValid(GapCursor(found), in: doc, "gap found from \(ctx)")
                }
            }

            try checkSelectionValid(AllSelection(doc), in: doc, "AllSelection at \(seed)")

            // Cell selections over every pair of cells in every table.
            var cells: [Int] = []
            doc.descendants { node, pos, _, _ in
                if fuzzCellTypeNames.contains(node.type.name) { cells.append(pos) }
                return true
            }
            for a in cells {
                for b in cells {
                    let sel = CellSelection.create(doc, a, b)
                    try checkSelectionValid(sel, in: doc, "CellSelection \(a)..\(b) at \(seed)")
                }
            }
            try expect(doc == pristine, "the document changed while selections were being placed in it at \(seed)")
        }
    }

    // MARK: round-trips and immutability

    test("selection fuzz: selections round-trip through JSON, bookmarks and an empty mapping") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 40) {
            for sel in everySelection(in: doc) {
                try checkSelectionRoundTrips(sel, in: doc, "\(seed)")
            }
        }
    }

    test("selection fuzz: placing a selection never modifies the document") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 40) {
            let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc))
            for sel in everySelection(in: doc) {
                try checkSelectionDoesNotModify(sel, state, "\(seed)")
            }
            try expect(state.doc == doc, "the state's document changed at \(seed)")
        }
    }

    // MARK: mapping through edits

    test("selection fuzz: selections survive mapping through random edits") {
        let schema = try fuzzSchema()
        var rng = SelRNG(31)
        for (seed, doc) in fuzzCorpus(schema, count: 40) {
            let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc))
            let selections = everySelection(in: doc)
            guard !selections.isEmpty else { continue }
            for _ in 0 ..< 12 {
                let sel = selections[Int.random(in: 0 ..< selections.count, using: &rng)]
                let tr = state.tr.setSelection(sel)
                let size = doc.content.size
                let a = Int.random(in: 0 ... size, using: &rng), b = Int.random(in: 0 ... size, using: &rng)
                let what: String
                switch Int.random(in: 0 ..< 4, using: &rng) {
                case 0:
                    what = "insertText at \(a)"
                    _ = try? tr.insertText("xy", a)
                case 1:
                    what = "delete \(Swift.min(a, b))..\(Swift.max(a, b))"
                    _ = try? tr.delete(Swift.min(a, b), Swift.max(a, b))
                case 2:
                    what = "deleteSelection"
                    tr.deleteSelection()
                default:
                    what = "replaceSelection with a paragraph"
                    guard let p = schema.nodes["paragraph"]?.createAndFill([:], content: Fragment.from(schema.text("z")))
                    else { continue }
                    _ = tr.replaceSelection(Slice(content: Fragment.from(p), openStart: 0, openEnd: 0))
                }
                let ctx = "\(seed): \(describeSelection(sel)) through \(what)"
                var invalid: (any Error)?
                do { try tr.doc.check() } catch { invalid = error }
                try expect(invalid == nil,
                           "an edit under a selection made the doc invalid — \(ctx): \(invalid.map { "\($0)" } ?? "")")

                // The selection maps onto the new document, and mapping is a
                // read: it can't have changed the document it maps onto.
                let before = tr.doc
                let mapped = sel.map(tr.doc, tr.mapping)
                try checkSelectionValid(mapped, in: tr.doc, "mapped — \(ctx)")
                try expect(tr.doc == before, "mapping a selection changed the document — \(ctx)")
                try checkSelectionRoundTrips(mapped, in: tr.doc, "mapped — \(ctx)")

                // A bookmark maps to the same place the selection does when the
                // selection stays the same kind (that is the point of bookmarks:
                // to survive an edit the selection itself might not).
                let viaBookmark = sel.getBookmark().map(tr.mapping).resolve(tr.doc)
                try checkSelectionValid(viaBookmark, in: tr.doc, "bookmark mapped — \(ctx)")

                // The state agrees: the applied selection is valid in the doc
                // the transaction produced.
                let applied = state.apply(tr)
                try expect(applied.doc == tr.doc, "apply disagreed with the transaction's document — \(ctx)")
                try checkSelectionValid(applied.selection, in: applied.doc, "state selection after \(ctx)")
            }
        }
    }

    // MARK: hostile input

    // Selection JSON arrives from stored documents, peers and the clipboard, so
    // it can name positions this document doesn't have — or no position at all.
    // None of that may trap, and whatever comes back has to be a usable
    // selection that round-trips like any other.
    test("selection fuzz: out-of-range and malformed selection JSON never traps") {
        let schema = try fuzzSchema()
        var rng = SelRNG(101)
        let types = ["text", "node", "all", "gapcursor", "cell", "", "Text", "bogus"]
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            let size = doc.content.size
            for _ in 0 ..< 400 {
                let type = types.randomElement(using: &rng)!
                // Positions well outside the document, negative, and in range.
                func wild() -> Int { Int.random(in: -8 ... (size + 8), using: &rng) }
                var json: [String: AttributeValue] = ["type": .string(type)]
                for key in ["anchor", "head", "pos"] where Bool.random(using: &rng) { json[key] = .int(wild()) }
                let ctx = "\(seed) json \(json)"
                // A missing field or an unknown type is a thrown error, not a
                // trap and not a broken selection.
                let decoded = type == "cell" ? CellSelection.fromCellJSON(doc, json)
                                             : (try? Selection.fromJSON(doc, json))
                guard let decoded else { continue }
                try checkSelectionValid(decoded, in: doc, ctx)
                try checkSelectionRoundTrips(decoded, in: doc, ctx)
            }
            try expect(fuzzState(doc, schema).doc == doc, "decoding selection JSON changed the document at \(seed)")
        }
    }

    // MARK: putting back what the selection already holds

    test("selection fuzz: a selection's content is a faithful cut of the document") {
        // The model-level round-trip: the slice a selection hands out, put back
        // over the range it came from, has to rebuild the document exactly.
        // Deliberately `Node.replace` and not `Transform.replace` — the latter
        // goes through the fitter, which is allowed to reshape an open slice to
        // fit its surroundings. That path is the next test.
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 30) {
            for sel in everySelection(in: doc) {
                // A cell selection's content is a rectangle of table rows, not
                // the span between its endpoints — it isn't a cut, and putting
                // it back isn't meant to reproduce anything.
                if sel is CellSelection { continue }
                let ctx = "\(describeSelection(sel)) at \(seed)"
                do {
                    let back = try doc.replace(sel.from, sel.to, sel.content())
                    try expect(back == doc, "a selection's content doesn't reproduce the range it came from — \(ctx)")
                } catch let error as ModelError {
                    try expect(false, "putting a selection's own content back was rejected — \(ctx): \(error)")
                }
            }
        }
    }

    test("selection fuzz: replacing a selection with its own content stays valid") {
        // Deliberately weaker than the cut above: `replaceSelection` goes
        // through `replaceRange`, which is allowed to expand the range and
        // re-wrap the content, so it is not an identity. What it may never do
        // is produce a document the schema rejects, or a selection that doesn't
        // resolve in it.
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 30) {
            let base = fuzzState(doc, schema)
            for sel in everySelection(in: doc) {
                let tr = base.tr.setSelection(sel)
                _ = tr.replaceSelection(sel.content())
                let ctx = "\(describeSelection(sel)) at \(seed)"
                var invalid: (any Error)?
                do { try tr.doc.check() } catch { invalid = error }
                try expect(invalid == nil,
                           "re-inserting a selection's own content made the doc invalid — \(ctx): \(invalid.map { "\($0)" } ?? "")")
                try checkSelectionValid(tr.selection, in: tr.doc, "after re-inserting its own content — \(ctx)")
            }
        }
    }

    // MARK: edits outside the selection

    test("selection fuzz: an edit outside a selection moves it by exactly the edit's size") {
        let schema = try fuzzSchema()
        var rng = SelRNG(53)
        for (seed, doc) in fuzzCorpus(schema, count: 30) {
            let base = fuzzState(doc, schema)
            // Positions text can actually be typed at.
            let typable = (0 ... doc.content.size).filter { doc.resolve($0).parent.inlineContent }
            guard !typable.isEmpty else { continue }
            for sel in everySelection(in: doc) {
                // Four probes per selection: the nearest typable position on
                // each side, plus a random one on each side.
                let before = typable.filter { $0 < sel.from }
                let after = typable.filter { $0 > sel.to }
                var probes: [Int] = []
                if let x = before.last { probes.append(x) }
                if let x = after.first { probes.append(x) }
                if let x = before.randomElement(using: &rng) { probes.append(x) }
                if let x = after.randomElement(using: &rng) { probes.append(x) }

                for at in probes {
                    let tr = base.tr
                    guard (try? tr.insertText("xy", at)) != nil, tr.docChanged else { continue }
                    let shift = tr.doc.content.size - doc.content.size
                    let ctx = "\(describeSelection(sel)) with \(shift) inserted at \(at) in \(seed)"
                    let mapped = sel.map(tr.doc, tr.mapping)
                    try checkSelectionValid(mapped, in: tr.doc, ctx)

                    // The whole-document selection is the one that legitimately
                    // grows: it always covers whatever the document now is.
                    if sel is AllSelection {
                        try expectEqual(mapped.from, 0, "AllSelection left the start after \(ctx)")
                        try expectEqual(mapped.to, tr.doc.content.size, "AllSelection didn't follow the end after \(ctx)")
                        continue
                    }

                    let delta = at < sel.from ? shift : 0
                    try expect(type(of: mapped) == type(of: sel),
                               "an edit outside the selection turned a \(type(of: sel)) into a \(type(of: mapped)) — \(ctx)")
                    try expectEqual(mapped.anchor, sel.anchor + delta, "anchor moved wrong — \(ctx)")
                    try expectEqual(mapped.head, sel.head + delta, "head moved wrong — \(ctx)")

                    // And a bookmark, which exists to survive exactly this,
                    // has to land in the same place.
                    let viaBookmark = sel.getBookmark().map(tr.mapping).resolve(tr.doc)
                    try expect(viaBookmark.eq(mapped),
                               "a bookmark landed at \(describeSelection(viaBookmark)) where the selection landed at \(describeSelection(mapped)) — \(ctx)")
                }
            }
        }
    }

    // MARK: deleting what a bookmark points at

    test("selection fuzz: a bookmark for a deleted node doesn't select whatever slides into its place") {
        // That is the whole job of `deletedAfter` in `NodeBookmark.map`: the
        // node the bookmark named is gone, so the selection has to become a
        // caret rather than grab the next node along.
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 30) {
            let base = fuzzState(doc, schema)
            for case let sel as NodeSelection in everySelection(in: doc) {
                let tr = base.tr
                guard (try? tr.delete(sel.from, sel.to)) != nil, tr.docChanged else { continue }
                // Only where the delete really was the clean removal it was
                // asked for. Deleting a structural node (a table cell) gets
                // reshaped by the fitter into something else entirely, and then
                // the bookmark isn't being asked about a node that vanished.
                guard sel.node.isAtom, tr.doc.content.size == doc.content.size - sel.node.nodeSize else { continue }
                let back = sel.getBookmark().map(tr.mapping).resolve(tr.doc)
                let ctx = "\(describeSelection(sel)) on a \(sel.node.type.name) at \(seed)"
                try checkSelectionValid(back, in: tr.doc, "bookmark after deleting the node — \(ctx)")
                // Only when there is somewhere for a caret to go. A document
                // with nothing but atoms left has no better answer than a node
                // selection, and that fallback is the right one.
                let landing = tr.doc.resolve(tr.mapping.map(sel.anchor))
                guard Selection.findFrom(landing, 1, textOnly: true) != nil
                        || Selection.findFrom(landing, -1, textOnly: true) != nil else { continue }
                try expect(!(back is NodeSelection),
                           "after deleting it, the bookmark selects a \((back as? NodeSelection)?.node.type.name ?? "?") — \(ctx)")
            }
        }
    }

    // MARK: the search helpers agree with each other

    test("selection fuzz: near, atStart and atEnd are the searches they are defined as") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 30) {
            // `atStart`/`atEnd` are the first and last places a selection can go.
            let atStart = Selection.atStart(doc), atEnd = Selection.atEnd(doc)
            if let fromStart = Selection.findFrom(doc.resolve(0), 1) {
                try expect(atStart.eq(fromStart),
                           "atStart (\(describeSelection(atStart))) isn't the forward search from 0 (\(describeSelection(fromStart))) at \(seed)")
            }
            if let fromEnd = Selection.findFrom(doc.resolve(doc.content.size), -1) {
                try expect(atEnd.eq(fromEnd),
                           "atEnd (\(describeSelection(atEnd))) isn't the backward search from the end (\(describeSelection(fromEnd))) at \(seed)")
            }

            for pos in 0 ... doc.content.size {
                let resolved = doc.resolve(pos)
                let ctx = "\(seed) pos \(pos)"
                for bias in [1, -1] {
                    // `near` is "search this way, then the other way, then give
                    // up and take the whole document".
                    let expected = Selection.findFrom(resolved, bias) ?? Selection.findFrom(resolved, -bias)
                    let near = Selection.near(resolved, bias)
                    if let expected {
                        try expect(near.eq(expected),
                                   "near(\(bias)) gave \(describeSelection(near)), the searches gave \(describeSelection(expected)), at \(ctx)")
                    } else {
                        try expect(near is AllSelection,
                                   "near(\(bias)) found \(describeSelection(near)) where no search could at \(ctx)")
                    }
                }
                // A gap-cursor search asked to move really does move.
                for dir in [1, -1] {
                    guard let moved = GapCursor.findGapCursorFrom(resolved, dir, true) else { continue }
                    try expect(dir > 0 ? moved.pos > pos : moved.pos < pos,
                               "findGapCursorFrom(\(dir), mustMove) stayed at \(moved.pos) from \(ctx)")
                    try expect(GapCursor.valid(moved), "findGapCursorFrom(\(dir), mustMove) returned an invalid gap at \(ctx)")
                }
            }
        }
    }
}

