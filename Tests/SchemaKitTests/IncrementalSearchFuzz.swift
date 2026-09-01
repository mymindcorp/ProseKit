import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for the incremental search highlighter.
//
// While a query is set, every edit used to search the whole document again.
// Now only the span the edit touched is searched, and the matches on either
// side are carried across by mapping. That is a cache, and a cache has exactly
// one promise: nobody can tell it is there. So after every edit, the highlights
// the plugin holds are compared with a search done from scratch on the same
// document — the same ranges, in the same order, with the same one active.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerIncrementalSearchFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("incremental search fuzz: the carried highlights always equal a fresh search") {
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 53 &+ 11)
            let editor = try Editor(extensions: fuzzKit())
            var gen = DocGen(schema: editor.schema, seed: seed)
            editor.setContent(gen.randomDoc(depth: 3, budget: 50))

            // A query cut from the text, or a regex, over the whole document or
            // a range — the range is the part that has to be mapped too.
            let text = editor.doc.textContent
            let chars = Array(text)
            let source: String
            if !chars.isEmpty, Bool.random(using: &rng) {
                let start = Int.random(in: 0 ..< chars.count, using: &rng)
                source = String(chars[start ..< Swift.min(chars.count, start + Int.random(in: 1 ... 3, using: &rng))])
            } else {
                source = ["a", " ", "[a-z]+", "\\d", "a|b", ".", "🙂", "é"].randomElement(using: &rng)!
            }
            let query = SearchQuery(search: source, caseSensitive: Bool.random(using: &rng),
                                    regexp: Bool.random(using: &rng), wholeWord: Bool.random(using: &rng))
            var range: SearchRange?
            if Bool.random(using: &rng), editor.doc.content.size > 4 {
                let a = Int.random(in: 0 ... editor.doc.content.size, using: &rng)
                let b = Int.random(in: 0 ... editor.doc.content.size, using: &rng)
                if a != b { range = SearchRange(from: Swift.min(a, b), to: Swift.max(a, b)) }
            }
            editor.dispatch(setSearchState(editor.state.tr, query, range))
            var log: [String] = []
            try checkHighlights(editor, "seed \(seed) after setting \(source.debugDescription)")

            for _ in 0 ..< fuzzOpCount {
                log.append(fuzzStep(editor, &rng))
                try checkHighlights(editor, "seed \(seed) query \(source.debugDescription)\(range.map { " in \($0.from)..\($0.to)" } ?? "") — \(log.suffix(4).joined(separator: " | "))")
            }
        }
    }
}

/// What the plugin holds against what a fresh search of the same document says.
private func checkHighlights(_ editor: Editor, _ ctx: @autoclosure () -> String) throws {
    guard let held = searchQueryKey.getState(editor.state) else { return }
    let state = editor.state
    let from = held.range?.from ?? 0, to = held.range?.to ?? state.doc.content.size
    let fresh = held.query.findAll(state, from, to)
    let got = held.deco.decorations.map { ($0.from, $0.to) }
    let want = fresh.map { ($0.from, $0.to) }
    try expect(got.count == want.count && zip(got, want).allSatisfy { $0 == $1 },
               "the carried highlights \(got) differ from a fresh search \(want) — \(ctx())")
    // The range itself survived mapping into the document.
    if let r = held.range {
        try expect(r.from >= 0 && r.from < r.to && r.to <= state.doc.content.size,
                   "the search range \(r.from)..\(r.to) is no longer inside the document — \(ctx())")
    }
    // Exactly the match under the selection is the active one, if any is.
    let sel = state.selection
    let active = held.deco.decorations.filter { $0.attributes["class"] == "ProseMirror-active-search-match" }
    let onSelection = fresh.filter { $0.from == sel.from && $0.to == sel.to }
    try expectEqual(active.count, onSelection.isEmpty ? 0 : 1, "wrong number of active highlights — \(ctx())")
    if let a = active.first, let m = onSelection.first {
        try expect(a.from == m.from && a.to == m.to, "the active highlight is not the match under the selection — \(ctx())")
    }
    for d in held.deco.decorations {
        try expect(d.from < d.to, "an empty highlight \(d.from)..\(d.to) — \(ctx())")
        let className = d.attributes["class"] ?? ""
        try expect(className == "ProseMirror-search-match" || className == "ProseMirror-active-search-match",
                   "a highlight with class \(className.debugDescription) — \(ctx())")
    }
}
