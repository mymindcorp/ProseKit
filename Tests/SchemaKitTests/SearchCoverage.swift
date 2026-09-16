import DocumentModel
import EditorHistory
import EditorStateKit
import SchemaKit
import TestHarness

// Behavioral coverage through the public editor facade, including history and
// rich content. These run in normal CI, independently of the opt-in fuzzers.
func registerSearchCoverageTests() {
    test("search coverage: every bounded range agrees across navigation and highlighting") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", content: Fragment.from([
            try s.node("paragraph", content: Fragment.from(s.text("😀 cat cat"))),
            try s.node("paragraph", content: Fragment.from(s.text("cat 😀 cat")))
        ])))
        // Explicit document positions, independent of the search implementation.
        let occurrences = [[3, 6], [7, 10], [12, 15], [18, 21]]
        for regexp in [false, true] {
            for filtered in [false, true] {
                let query = SearchQuery(search: regexp ? "c.t" : "cat", regexp: regexp,
                    filter: { _, match in !filtered || match.from != 7 })
                for from in 0..<editor.doc.content.size {
                    for to in (from + 1)...editor.doc.content.size {
                        let expected = occurrences.filter {
                            $0[0] >= from && $0[1] <= to && (!filtered || $0[0] != 7)
                        }
                        let context = "range \(from)..\(to), regexp=\(regexp), filtered=\(filtered)"
                        try expectEqual(query.findAll(editor.state, from, to).map { [$0.from, $0.to] }, expected, context)
                        try expectEqual(query.findNext(editor.state, from, to).map { [$0.from, $0.to] }, expected.first, context)
                        try expectEqual(query.findPrev(editor.state, to, from).map { [$0.from, $0.to] }, expected.last, context)
                        editor.dispatch(setSearchState(editor.state.tr, query, SearchRange(from: from, to: to)))
                        try expectEqual(searchQueryKey.getState(editor.state)!.deco.find().map { [$0.from, $0.to] }, expected, context)
                    }
                }
            }
        }
    }

    test("search coverage: capture replacements round-trip through undo and redo") {
        let cases: [(input: String, pattern: String, regexp: Bool, replacement: String, expected: String)] = [
            ("cat", "cat", false, "[$&] $&", "[cat] cat"),
            ("abc", "(a(b)c)", true, "$1$2", "abcb"),
            ("abc", "(?<=(a))b", true, "$1", "aac"),
            ("abc", "b(?=(c))", true, "$1", "acc"),
            ("ab-cd", "(ab)-(cd)", true, "$2$1$2", "cdabcd"),
            ("b", "(a)?b", true, "$1x", "x"),
            ("b", "(a*)b", true, "$1x", "x"),
            ("cat", "cat", false, "$½ $٢ $$", "$½ $٢ $"),
            ("e\u{0301}", "e\u{0301}", true, "é🙂", "é🙂")
        ]
        for c in cases {
            let editor = try Editor(extensions: fullKit())
            let s = editor.schema
            func document(_ text: String) throws -> Node {
                try s.node("doc", content: Fragment.from([
                    try s.node("paragraph", content: Fragment.from(s.text("prefix " + text + " tail"))),
                    try s.node("paragraph", content: Fragment.from(s.text(text)))
                ]))
            }
            let original = try document(c.input)
            let expected = try document(c.expected)
            editor.setContent(original)
            select(editor, 2, 5)
            let selection = editor.state.selection
            editor.setSearch(c.pattern, regexp: c.regexp)
            let matches = editor.searchMatches.map { [$0.from, $0.to] }
            try expectEqual(matches.count, 2, c.pattern)
            editor.dispatch(EditorHistory.closeHistory(editor.state.tr))
            let depth = EditorHistory.undoDepth(editor.state)
            try expectEqual(editor.replaceAllMatches(with: c.replacement), 2, c.pattern)
            try expectEqual(editor.doc, expected, c.pattern)
            try editor.doc.check()
            try expectEqual(EditorHistory.undoDepth(editor.state), depth + 1)
            try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
            try expectEqual(editor.doc, original, c.pattern)
            try expect(editor.state.selection.eq(selection))
            try expectEqual(editor.searchMatches.map { [$0.from, $0.to] }, matches)
            try expectEqual(searchQueryKey.getState(editor.state)!.deco.find().map { [$0.from, $0.to] }, matches)
            try expect(EditorHistory.redo(editor.state, { editor.dispatch($0) }))
            try expectEqual(editor.doc, expected, c.pattern)
        }
    }

    test("search coverage: copied captures retain marks and inline node attributes") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let bold = s.marks["bold"]!.create()
        let link = try s.node("wikiLink", ["target": .string("Architecture"), "text": .string("Design")])
        let rich = [s.text("cat", [bold]), link]
        let original = try s.node("doc", content: Fragment.from(
            try s.node("paragraph", content: Fragment.from([s.text("before (")] + rich + [s.text(") after")]))))
        editor.setContent(original)
        editor.setSearch("\\((cat\u{FFFC})\\)", regexp: true)
        try expectEqual(editor.searchMatches.count, 1)
        try expect(editor.replaceCurrentMatch(with: "$1 / $1"))
        let expected = try s.node("doc", content: Fragment.from(
            try s.node("paragraph", content: Fragment.from([s.text("before ")] + rich + [s.text(" / ")] + rich + [s.text(" after")]))))
        try expectEqual(editor.doc, expected)
        try editor.doc.check()
    }

    test("search coverage: bounded replace-all maps the range and restores it on undo") {
        let editor = try editorWith("cat cat cat")
        editor.dispatch(setSearchState(editor.state.tr, SearchQuery(search: "cat"), SearchRange(from: 4, to: 9)))
        editor.dispatch(EditorHistory.closeHistory(editor.state.tr))
        try expectEqual(editor.replaceAllMatches(with: "elephant"), 1)
        try expectEqual(editor.doc.textContent, "cat elephant cat")
        let range = searchQueryKey.getState(editor.state)!.range
        try expectEqual(range, SearchRange(from: 4, to: 14))
        try expectEqual(editor.searchMatches.count, 0)
        try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
        try expectEqual(editor.doc.textContent, "cat cat cat")
        try expectEqual(searchQueryKey.getState(editor.state)!.range, SearchRange(from: 4, to: 9))
        try expectEqual(editor.searchMatches.map { [$0.from, $0.to] }, [[5, 8]])
    }
}
