import Foundation
import DocumentModel
import DocumentTransform
import EditorSerialization
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for copy and paste.
//
// This is the path a user takes more than any other, and it is the one place
// where all three layers meet: a selection hands out a slice, a serializer
// writes it, a parser reads someone else's markup back, and the fitter has to
// put the result somewhere it doesn't belong. Each of those was fuzzed on its
// own. The seam between them was not, and the seam is where the fitter has to
// reconcile a slice cut out of a table cell with a caret sitting in a heading.
//
// The pipeline here is exactly the one `EditorTextView` runs — cut the
// selection's content, serialize the fragment, parse it back, and drop it in
// with `Slice.maxOpen` — so a failure is a paste a user could perform, not an
// arrangement only a test could reach.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerPasteFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("paste fuzz: anything copied out of a document can be pasted back into it") {
        let schema = try fuzzSchema()
        var rng = SelRNG(61)
        for (seed, doc) in fuzzCorpus(schema, count: 25) {
            let state = fuzzState(doc, schema)
            let sources = pasteSources(doc, &rng)
            let targets = pasteTargets(doc, &rng)
            guard !sources.isEmpty, !targets.isEmpty else { continue }

            for source in sources {
                // What the clipboard would hold, by both routes the editor
                // writes: the markup, and the plain text beside it.
                let fragment = source.content().content
                guard !fragment.isEmpty else { continue }
                let html = HTMLSerializer.serialize(fragment: fragment)

                for target in targets {
                    let ctx = "\(seed): \(describeSelection(source)) → \(describeSelection(target))"

                    // 1. The model-level paste: the slice the selection handed
                    //    out, straight back in. No serializer involved, so a
                    //    failure here is the fitter's.
                    try checkPaste(state, target, source.content(), "slice — \(ctx)")

                    // 2. The clipboard paste: through HTML and back, opened the
                    //    way `insertContent` opens it.
                    guard let parsed = try? HTMLParser.parse(html, schema: schema) else {
                        try expect(false, "the parser rejected our own clipboard HTML — \(ctx)\n  \(html.debugDescription)")
                        continue
                    }
                    try checkPaste(state, target, Slice.maxOpen(parsed.content), "HTML — \(ctx)")
                }
            }
        }
    }

    test("paste fuzz: pasting at every position of a document leaves a valid document") {
        // The sweep above samples positions so it can afford a big corpus. This
        // one is exhaustive over a small one: a fitter bug that only shows up
        // at one depth — the last position inside a table cell, the gap between
        // two list items — is exactly what a sampled target set misses.
        let schema = try fuzzSchema()
        var rng = SelRNG(67)
        for (seed, doc) in fuzzCorpus(schema, count: 6) {
            let state = fuzzState(doc, schema)
            guard let source = pasteSources(doc, &rng).first else { continue }
            let slice = source.content()
            guard !slice.content.isEmpty else { continue }
            let html = HTMLSerializer.serialize(fragment: slice.content)
            let parsed = (try? HTMLParser.parse(html, schema: schema)).map { Slice.maxOpen($0.content) }

            for pos in 0 ... doc.content.size {
                let target = Selection.near(doc.resolve(pos), 1)
                let ctx = "\(seed) at \(pos)"
                try checkPaste(state, target, slice, "slice — \(ctx)")
                if let parsed { try checkPaste(state, target, parsed, "HTML — \(ctx)") }
            }
        }
    }

    test("paste fuzz: pasting foreign markup never builds a document the schema rejects") {
        // Not our own clipboard this time — another document's, which is what
        // arrives from another app. The markup is well-formed but describes
        // structure that has no place where it lands: a table pasted into a
        // heading, a footnote definition into a table cell.
        let schema = try fuzzSchema()
        var rng = SelRNG(71)
        let corpus = fuzzCorpus(schema, count: 20)
        for (seed, doc) in corpus {
            let state = fuzzState(doc, schema)
            let targets = pasteTargets(doc, &rng)
            guard !targets.isEmpty else { continue }
            // Markup from three other documents in the corpus.
            for _ in 0 ..< 3 {
                let (otherSeed, other) = corpus[Int.random(in: 0 ..< corpus.count, using: &rng)]
                for (what, text) in [("HTML", HTMLSerializer.serialize(other)),
                                     ("Markdown", MarkdownSerializer.serialize(other))] {
                    let parsed = what == "HTML" ? try? HTMLParser.parse(text, schema: schema)
                                                : try? MarkdownParser.parse(text, schema: schema)
                    guard let parsed, !parsed.content.isEmpty else { continue }
                    for target in targets {
                        let ctx = "\(what) from \(otherSeed) into \(seed) at \(describeSelection(target))"
                        try checkPaste(state, target, Slice.maxOpen(parsed.content), ctx)
                        // And the public API's own opening, which is not
                        // `maxOpen` — `insertContent(html:)` pastes the parse
                        // closed, so it is a second shape the fitter must take.
                        try checkPaste(state, target,
                                       Slice(content: parsed.content, openStart: 0, openEnd: 0),
                                       "closed \(ctx)")
                    }
                }
            }
        }
    }

    test("paste fuzz: pasting plain text puts every line in the document") {
        // The fallback path, and the one with the least structure to hide
        // behind: whatever the clipboard's text was, the words have to be in
        // the document afterwards.
        let schema = try fuzzSchema()
        var rng = SelRNG(73)
        let samples = ["a", "one\ntwo", "  leading", "trailing  ", "a\n\nb", "🙂\n漢字",
                       "- item\n- item", "# heading", "```\ncode\n```", "\n", "x\ty"]
        for (seed, doc) in fuzzCorpus(schema, count: 12) {
            let state = fuzzState(doc, schema)
            for target in pasteTargets(doc, &rng) {
                for sample in samples {
                    let ctx = "\(seed): \(sample.debugDescription) at \(describeSelection(target))"
                    let tr = state.tr.setSelection(target)
                    guard (try? tr.insertText(sample)) != nil else { continue }
                    try checkDocument(tr.doc, tr.selection, ctx)
                    // Every non-blank line's characters survive, allowing for
                    // the whitespace a block boundary eats.
                    let want = sample.split(whereSeparator: \.isWhitespace).joined()
                    guard !want.isEmpty else { continue }
                    let got = tr.doc.textContent.split(whereSeparator: \.isWhitespace).joined()
                    try expect(got.contains(want) || want.split(separator: "\n").allSatisfy { got.contains($0) },
                               "pasted text didn't reach the document — \(ctx)")
                }
            }
        }
    }
}

// MARK: - The paste itself

/// Paste `slice` over `target` and check what came out.
///
/// A paste is allowed to *refuse* — there are slices that genuinely have no
/// place at a given position, and `replaceSelection` leaving the document alone
/// is a legitimate answer. What it may not do is produce a document the schema
/// rejects, or leave a selection that doesn't resolve in it.
private func checkPaste(_ state: EditorState, _ target: Selection, _ slice: Slice,
                        _ ctx: @autoclosure () -> String) throws {
    let tr = state.tr.setSelection(target)
    _ = tr.replaceSelection(slice)
    try checkDocument(tr.doc, tr.selection, ctx())

    // And through `apply`, which is where a plugin (table fixing, unique IDs)
    // gets to append to what the paste did — the document the user actually
    // ends up looking at.
    let applied = state.apply(tr)
    try checkDocument(applied.doc, applied.selection, "after plugins — \(ctx())")
}

private func checkDocument(_ doc: Node, _ selection: Selection, _ ctx: @autoclosure () -> String) throws {
    var invalid: (any Error)?
    do { try doc.check() } catch { invalid = error }
    try expect(invalid == nil,
               "the paste produced an invalid document — \(ctx()): \(invalid.map { "\($0)" } ?? "")\n\(fuzzOutline(doc))")
    try checkSelectionValid(selection, in: doc, "after the paste — \(ctx())")
    // Every position still resolves, which `check` does not cover.
    for pos in 0 ... doc.content.size { _ = doc.resolve(pos) }
}

// MARK: - What to copy, and where to put it

/// A handful of ranges worth copying: whole blocks, parts of blocks, and
/// whatever a table in the document offers.
private func pasteSources(_ doc: Node, _ rng: inout SelRNG) -> [Selection] {
    var out: [Selection] = [AllSelection(doc)]
    let size = doc.content.size
    guard size > 0 else { return out }
    // Two random ranges and one that covers most of the document — a wide cut
    // is where a slice ends up open at both ends and hardest to place.
    for _ in 0 ..< 2 {
        let a = Int.random(in: 0 ... size, using: &rng), b = Int.random(in: 0 ... size, using: &rng)
        out.append(TextSelection.between(doc.resolve(Swift.min(a, b)), doc.resolve(Swift.max(a, b))))
    }
    if size > 2 {
        out.append(TextSelection.between(doc.resolve(1), doc.resolve(size - 1)))
    }
    // A node selection, and a cell selection, where the document has one.
    for pos in 0 ... size where doc.resolve(pos).nodeAfter.map(NodeSelection.isSelectable) == true {
        out.append(NodeSelection.create(doc, pos))
        break
    }
    let cells = fuzzCellPositions(doc)
    if let a = cells.first, let b = cells.last, a != b { out.append(CellSelection.create(doc, a, b)) }
    return out
}

/// A handful of places to paste into: the two ends, and a few positions in
/// between that a caret can actually reach.
private func pasteTargets(_ doc: Node, _ rng: inout SelRNG) -> [Selection] {
    var out: [Selection] = [Selection.atStart(doc), Selection.atEnd(doc), AllSelection(doc)]
    let size = doc.content.size
    for _ in 0 ..< 4 {
        let pos = Int.random(in: 0 ... size, using: &rng)
        out.append(Selection.near(doc.resolve(pos), 1))
    }
    // A cell selection, where the document has a table: pasting *into* a
    // rectangle of cells is its own path in the table layer.
    let cells = fuzzCellPositions(doc)
    if cells.count >= 2 {
        out.append(CellSelection.create(doc, cells.randomElement(using: &rng)!, cells.randomElement(using: &rng)!))
    }
    // A non-empty range, so the paste has something to replace.
    if size > 1 {
        let a = Int.random(in: 0 ... size, using: &rng), b = Int.random(in: 0 ... size, using: &rng)
        if a != b { out.append(TextSelection.between(doc.resolve(Swift.min(a, b)), doc.resolve(Swift.max(a, b)))) }
    }
    return out
}
