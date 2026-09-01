import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for find and replace.
//
// Search is the one feature whose output the user can check against the page:
// "3 of 7" had better be seven, and replace-all had better leave zero. The
// matcher walks text nodes across block boundaries, marks and atoms, and the
// replacer edits from the back so its positions stay valid — every place a
// count can drift by one. Queries here are cut from the document's own text,
// so most of them match, plus a few that are regex specials, so the ones that
// can't be a pattern are rejected rather than trapped on.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerSearchFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("search fuzz: every match is the query, in order, and replace-all leaves none") {
        let schema = try fuzzSchema()
        var rng = SelRNG(97)
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            let text = doc.textContent
            guard !text.isEmpty else { continue }
            var queries: [String] = ["a", " ", "🙂", "é", "漢"]
            let chars = Array(text)
            for _ in 0 ..< 6 {
                let start = Int.random(in: 0 ..< chars.count, using: &rng)
                let length = Int.random(in: 1 ... 4, using: &rng)
                queries.append(String(chars[start ..< Swift.min(chars.count, start + length)]))
            }
            for query in queries where !query.isEmpty {
                for caseSensitive in [false, true] {
                    let editor = try Editor(extensions: fuzzKit(), content: doc)
                    editor.setSearch(query, caseSensitive: caseSensitive)
                    let matches = editor.searchMatches
                    let ctx = "\(query.debugDescription)\(caseSensitive ? " (case-sensitive)" : "") in \(seed)"

                    var previousTo = 0
                    for (from, to) in matches {
                        try expect(from >= previousTo, "matches out of order or overlapping at \(from)..\(to) — \(ctx)")
                        try expect(to <= editor.doc.content.size, "a match past the end of the document — \(ctx)")
                        let found = editor.doc.textBetween(from, to)
                        try expect(caseSensitive ? found == query : found.lowercased() == query.lowercased(),
                                   "a match reads \(found.debugDescription), not the query — \(ctx)")
                        previousTo = to
                    }
                    // Every occurrence in the plain text that doesn't cross a
                    // block is found. (One that does cross a boundary is
                    // legitimately not a match, so this is a lower bound.)
                    let occurrences = countWithinBlocks(editor.doc, query, caseSensitive: caseSensitive)
                    try expect(matches.count >= occurrences,
                               "found \(matches.count) matches but the text holds \(occurrences) — \(ctx)")

                    // Stepping through them never traps and lands on a match.
                    editor.findNext()
                    if !matches.isEmpty {
                        let sel = editor.state.selection
                        try expect(matches.contains { $0.from == sel.from && $0.to == sel.to },
                                   "findNext selected \(sel.from)..\(sel.to), which is not a match — \(ctx)")
                    }
                    editor.findPrevious()
                    try checkSelectionValid(editor.state.selection, in: editor.doc, "after findPrevious — \(ctx)")

                    // Replace them all with something the query can't match.
                    let replacement = query.lowercased().contains("q") ? "z" : "q"
                    let replaced = editor.replaceAllMatches(with: replacement)
                    try expectEqual(replaced, matches.count, "replaceAll replaced a different number than it found — \(ctx)")
                    var invalid: (any Error)?
                    do { try editor.doc.check() } catch { invalid = error }
                    try expect(invalid == nil, "replaceAll produced an invalid document — \(ctx): \(invalid.map { "\($0)" } ?? "")")
                    try checkSelectionValid(editor.state.selection, in: editor.doc, "after replaceAll — \(ctx)")
                    try expect(editor.searchMatches.isEmpty,
                               "\(editor.searchMatches.count) matches remained after replacing them all — \(ctx)")
                }
            }

            // Regex specials: a query that isn't a pattern is invalid, not fatal.
            for pattern in ["(", "[", "*", "a{", "\\", "(?<", "a|", ".*", "[a-]", "\\p{L}+"] {
                let editor = try Editor(extensions: fuzzKit(), content: doc)
                editor.setSearch(pattern, regexp: true)
                for (from, to) in editor.searchMatches {
                    try expect(from <= to && to <= editor.doc.content.size, "a regex match out of range — \(pattern) in \(seed)")
                }
                editor.findNext()
                _ = editor.replaceAllMatches(with: "r")
                var invalid: (any Error)?
                do { try editor.doc.check() } catch { invalid = error }
                try expect(invalid == nil, "a regex replace produced an invalid document — \(pattern) in \(seed)")
            }
        }
    }
}

/// How many non-overlapping occurrences of `query` the document's textblocks
/// hold, counted block by block so a match can't be expected across a boundary.
private func countWithinBlocks(_ doc: Node, _ query: String, caseSensitive: Bool) -> Int {
    var count = 0
    let q = caseSensitive ? query : query.lowercased()
    doc.descendants { node, _, _, _ in
        guard node.isTextblock else { return true }
        // Text nodes only: `textContent` also reads an atom's stand-in text —
        // a formula's `$…$`, a wiki link's title — which is not text the
        // search can land a caret in.
        var text = ""
        for i in 0 ..< node.childCount { if let t = node.child(i).text { text += t } }
        if !caseSensitive { text = text.lowercased() }
        var searchFrom = text.startIndex
        while let range = text.range(of: q, range: searchFrom ..< text.endIndex) {
            count += 1
            searchFrom = range.upperBound
        }
        return false
    }
    return count
}
