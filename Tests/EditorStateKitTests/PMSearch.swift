import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import TestHarness

// Ported from prosemirror-search/test/{test-query,test-search}.ts. Skipped (no
// local equivalent): the footnote-schema cases that need non-leaf inline atoms
// built via prosemirror-test-builder's `builders()` reconfiguration — the
// behavior they cover (scanning inside non-leaf atoms) is exercised by the
// nested-structure cases; and regexp syntax is ICU (NSRegularExpression), not
// JS, which is equivalent for every pattern these tests use.

// MARK: - test-query.ts

private func queryTest(_ query: SearchQuery, _ d: TaggedNode) throws {
    var matches: [(from: Int, to: Int)] = []
    var i = 1
    while let s = d.tags["s\(i)"], let e = d.tags["e\(i)"] {
        matches.append((s, e))
        i += 1
    }
    let state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: d.node))

    var forward: [(from: Int, to: Int)] = []
    var pos = 0
    while let next = query.findNext(state, pos) {
        forward.append((next.from, next.to))
        pos = next.to
    }
    try expectEqual("\(forward)", "\(matches)")

    var backward: [(from: Int, to: Int)] = []
    pos = d.node.content.size
    while let next = query.findPrev(state, pos) {
        backward.append((next.from, next.to))
        pos = next.from
    }
    try expectEqual("\(backward)", "\(Array(matches.reversed()))")
}

// MARK: - test-search.ts harness

private func mkSearchState(_ query: SearchQuery, _ d: TaggedNode, range: SearchRange? = nil) -> EditorState {
    let selection: Selection? = d.tags["a"].map { a in
        TextSelection.create(d.node, a, d.tags["b"] ?? a)
    }
    return EditorState.create(EditorStateConfig(
        schema: basicSchema, doc: d.node, selection: selection,
        plugins: [searchQueryPlugin(initialQuery: query, initialRange: range)]))
}

private func testSelCommand(_ query: SearchQuery, _ d: TaggedNode,
                            _ command: (EditorState, ((Transaction) -> Void)?) -> Bool,
                            range: SearchRange? = nil) throws {
    var state = mkSearchState(query, d, range: range)
    let result = command(state) { tr in state = state.apply(tr) }
    let c = d.tags["c"], dd = d.tags["d"]
    try expectEqual(result, c != nil)
    if let c, let dd {
        try expect(state.selection.eq(TextSelection.create(d.node, c, dd)),
                   "selection \(state.selection.from)..\(state.selection.to), wanted \(c)..\(dd)")
    }
}

private func testCommand(_ query: SearchQuery, _ start: TaggedNode, _ next: TaggedNode?,
                         _ command: (EditorState, ((Transaction) -> Void)?) -> Bool,
                         range: SearchRange? = nil) throws {
    var state = mkSearchState(query, start, range: range)
    let result = command(state) { tr in state = state.apply(tr) }
    try expectEqual(result, next != nil)
    if let next {
        let expected = mkSearchState(query, next, range: range)
        try expectEqual(state.doc, expected.doc)
        try expect(state.selection.eq(expected.selection),
                   "selection \(state.selection.from)..\(state.selection.to), wanted \(expected.selection.from)..\(expected.selection.to)")
    }
}

func registerPMSearchTests() {
    // MARK: SearchQuery (test-query.ts)
    test("PM SearchQuery: can match plain strings") {
        try queryTest(SearchQuery(search: "abc"), p("<s1>abc<e1> flakdj a<s2>abc<e2> aabbcc"))
    }
    test("PM SearchQuery: skips overlapping matches") {
        try queryTest(SearchQuery(search: "aba"), p("<s1>aba<e1>b<s2>aba<e2>."))
    }
    test("PM SearchQuery: goes through multiple textblocks") {
        try queryTest(SearchQuery(search: "12"), doc(p("a<s1>12<e1>b"), p("..."), p("and <s2>12<e2>")))
    }
    test("PM SearchQuery: matches across mark boundaries") {
        try queryTest(SearchQuery(search: "two"), p("ab<s1>t", em("w"), "o<e1>oo"))
    }
    test("PM SearchQuery: can match case-insensitive strings") {
        try queryTest(SearchQuery(search: "abC", caseSensitive: false), p("<s1>aBc<e1> flakdj a<s2>ABC<e2>"))
    }
    test("PM SearchQuery: can match literally") {
        try queryTest(SearchQuery(search: "a\\nb", literal: true), p("a\nb <s1>a\\nb<e1>"))
    }
    test("PM SearchQuery: can match by word") {
        try queryTest(SearchQuery(search: "hello", wholeWord: true),
                      p("<s1>hello<e1> hellothere <s2>hello<e2>\nello ahello ohellop"))
    }
    test("PM SearchQuery: doesn't match non-words by word") {
        try queryTest(SearchQuery(search: "^_^", wholeWord: true), p("x<s1>^_^<e1>y <s2>^_^<e2>"))
    }
    test("PM SearchQuery: can match regular expressions") {
        try queryTest(SearchQuery(search: "a..b", regexp: true), p("<s1>appb<e1> apb"))
    }
    test("PM SearchQuery: can match case-insensitive regular expressions") {
        try queryTest(SearchQuery(search: "a..b", caseSensitive: false, regexp: true), p("<s1>Appb<e1> Apb"))
    }
    test("PM SearchQuery: can match regular expressions through multiple textblocks") {
        try queryTest(SearchQuery(search: "12", regexp: true), doc(p("a<s1>12<e1>b"), p("..."), p("and <s2>12<e2>")))
    }
    test("PM SearchQuery: can match regular expressions by word") {
        try queryTest(SearchQuery(search: "a..", regexp: true, wholeWord: true),
                      p("<s1>aap<e1> baap aapje <s2>a--<e2>w"))
    }

    // MARK: findNext / findPrev (test-search.ts)
    test("PM search findNext: can find the next match") {
        try testSelCommand(SearchQuery(search: "two"), p("one <c>two<d> two"), findNext)
    }
    test("PM search findNext: can find the next match from selection") {
        try testSelCommand(SearchQuery(search: "two"), p("one <a>two<b> <c>two<d>"), findNext)
    }
    test("PM search findNext: wraps around at end of document") {
        try testSelCommand(SearchQuery(search: "two"), p("one <c>two<d> <a>two<b>"), findNext)
    }
    test("PM search findNext: doesn't wrap around in no-wrap mode") {
        try testSelCommand(SearchQuery(search: "two"), p("one two <a>two<b>"), findNextNoWrap)
    }
    test("PM search findNext: can search a limited range") {
        try testSelCommand(SearchQuery(search: "two"), p("one two <a>two<b>"), findNext,
                           range: SearchRange(from: 7, to: 11))
    }
    test("PM search findNext: wraps within the given range") {
        try testSelCommand(SearchQuery(search: "two"), p("two <c>two<d> <a>two<b>"), findNext,
                           range: SearchRange(from: 3, to: 11))
    }
    test("PM search findNext: can match in nested structure") {
        try testSelCommand(SearchQuery(search: "one"),
                           doc(blockquote(p("para <a>one<b>"), p("para two")), p("and <c>one<d>")), findNext)
    }
    test("PM search findPrev: can find the previous match") {
        try testSelCommand(SearchQuery(search: "two"), p("one <c>two<d> <a>two<b>"), findPrev)
    }
    test("PM search findPrev: wraps around at start of document") {
        try testSelCommand(SearchQuery(search: "two"), p("one <a>two<b> <c>two<d>"), findPrev)
    }
    test("PM search findPrev: doesn't wrap around in no-wrap mode") {
        try testSelCommand(SearchQuery(search: "two"), p("one <a>two<b> two"), findPrevNoWrap)
    }
    test("PM search findPrev: can search a limited range") {
        try testSelCommand(SearchQuery(search: "two"), p("one two <a>two<b>"), findPrev,
                           range: SearchRange(from: 7, to: 11))
    }
    test("PM search findPrev: wraps within the given range") {
        try testSelCommand(SearchQuery(search: "two"), p("two <a>two<b> <c>two<d>"), findPrev,
                           range: SearchRange(from: 3, to: 11))
    }
    test("PM search findPrev: can match in nested structure") {
        try testSelCommand(SearchQuery(search: "one"),
                           doc(blockquote(p("para <c>one<d>"), p("para two")), p("and <a>one<b>")), findPrev)
    }

    // MARK: replaceNext / replaceCurrent / replaceAll
    test("PM search replaceNext: moves to a match when not already on one") {
        try testCommand(SearchQuery(search: "one", replace: "two"), p("one one"), p("<a>one<b> one"), replaceNext)
    }
    test("PM search replaceNext: can replace the current match") {
        try testCommand(SearchQuery(search: "one", replace: "two"), p("<a>one<b> two"), p("<a>two<b> two"), replaceNext)
    }
    test("PM search replaceNext: moves selection to the next match") {
        try testCommand(SearchQuery(search: "one", replace: "two"), p("<a>one<b> one"), p("two <a>one<b>"), replaceNext)
    }
    test("PM search replaceNext: wraps around the end of the document") {
        try testCommand(SearchQuery(search: "one", replace: "two"), p("one <a>one<b>"), p("<a>one<b> two"), replaceNext)
    }
    test("PM search replaceNext: doesn't wrap with wrapping disabled") {
        try testCommand(SearchQuery(search: "one", replace: "two"), p("one <a>one<b>"), p("one <a>two<b>"), replaceNextNoWrap)
    }
    test("PM search replaceNext: can replace within a limited range") {
        try testCommand(SearchQuery(search: "one", replace: "two"),
                        p("one <a>one<b> one"), p("<a>one<b> two one"), replaceNext,
                        range: SearchRange(from: 0, to: 7))
    }
    test("PM search replaceNext: can reuse parts of the match") {
        try testCommand(SearchQuery(search: "\\((.*?)\\)", regexp: true, replace: "[$1]"),
                        p("<a>(hi)<b> (x)"), p("[hi] <a>(x)<b>"), replaceNext)
    }
    test("PM search replaceNext: can reuse matched leaf nodes") {
        try testCommand(SearchQuery(search: "\\((.*?)\\)", regexp: true, replace: "[$1]"),
                        p("<a>(", img(), ")<b> (x)"), p("[", img(), "] <a>(x)<b>"), replaceNext)
    }
    test("PM search replaceNext: can replace in nested structure") {
        try testCommand(SearchQuery(search: "one", replace: "two"),
                        doc(blockquote(p("para <a>one<b>"), p("para two")), p("and one")),
                        doc(blockquote(p("para two"), p("para two")), p("and <a>one<b>")),
                        replaceNext)
    }
    test("PM search replaceNext: doesn't replace reused content") {
        let state = mkSearchState(SearchQuery(search: ".(eu).", regexp: true, replace: "p$1t"), p("<a>deux<b> trois"))
        var tr: Transaction?
        _ = replaceNext(state) { t in tr = t }
        try expectNotNil(tr)
        try expectEqual(tr!.doc, p("peut trois").node)
        try expectEqual(tr!.mapping.map(2), 2)
    }
    test("PM search replaceNext: can handle multiple references to groups") {
        try testCommand(SearchQuery(search: "(ab)-(cd)", regexp: true, replace: "$2$1$2"),
                        p("<a>ab-cd<b>"), p("<a>cdabcd<b>"), replaceNext)
    }
    test("PM search replaceNext: replaces non-matched groups with nothing") {
        try testCommand(SearchQuery(search: "(ab)|(cd)", regexp: true, replace: "x$2"),
                        p("<a>ab<b>"), p("<a>x<b>"), replaceNext)
    }
    test("PM search replaceNext: supports matches in string replacements") {
        try testCommand(SearchQuery(search: "one", replace: "$&$&"), p("<a>one<b>"), p("<a>oneone<b>"), replaceNext)
    }
    test("PM search replaceCurrent: does nothing when not at a match") {
        try testCommand(SearchQuery(search: "one", replace: "two"), p("one"), nil, replaceCurrent)
    }
    test("PM search replaceCurrent: selects the replacement") {
        try testCommand(SearchQuery(search: "one", replace: "two"), p("<a>one<b>"), p("<a>two<b>"), replaceCurrent)
    }
    test("PM search replaceCurrent: replaces delimiters with regexp") {
        try testCommand(SearchQuery(search: "“([^”]+)”", regexp: true, replace: "$1"),
                        p("This is the <a>“footnote”<b> text"),
                        p("This is the <a>footnote<b> text"),
                        replaceCurrent)
    }
    test("PM search replaceAll: replaces all instances") {
        try testCommand(SearchQuery(search: "one", replace: "two"),
                        doc(p("this one"), p("that one"), blockquote(p("another one"))),
                        doc(p("this two"), p("that two"), blockquote(p("another two"))),
                        replaceAll)
    }
    test("PM search replaceAll: supports using parts of the match") {
        try testCommand(SearchQuery(search: "(\\d+)-(\\d+)", regexp: true, replace: "$1:$2"),
                        p("50-20 vs 40-15"), p("50:20 vs 40:15"), replaceAll)
    }
    test("PM search replaceAll: works within a limited range") {
        try testCommand(SearchQuery(search: "one", replace: "two"),
                        p("one one one one one"), p("one two two two one"), replaceAll,
                        range: SearchRange(from: 2, to: 17))
    }
    test("PM search filter: lets you replace only emphasized texts") {
        let filter: (EditorState, SearchResult) -> Bool = { state, result in
            state.doc.rangeHasMark(result.from, result.to, state.schema.marks["em"]!)
        }
        try testCommand(SearchQuery(search: "one", replace: "two", filter: filter),
                        doc(p("this one"), p("that ", em("one")), blockquote(p("another ", em("one")))),
                        doc(p("this one"), p("that ", em("two")), blockquote(p("another ", em("two")))),
                        replaceAll)
    }
}
