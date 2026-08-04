import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import TestHarness

// Ported from prosemirror-search/test/{test-query,test-search}.ts, including the
// footnote-schema cases: upstream builds those with prosemirror-test-builder's
// `builders()` reconfiguration, which has no local equivalent, so the documents
// are assembled by hand below instead.
//
// Skipped (no local equivalent): nothing else, except that regexp syntax here is
// ICU (NSRegularExpression) rather than JS — equivalent for every pattern these
// tests use.

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

private func mkSearchState(_ query: SearchQuery, _ d: TaggedNode, range: SearchRange? = nil,
                           schema: Schema = basicSchema) -> EditorState {
    let selection: Selection? = d.tags["a"].map { a in
        TextSelection.create(d.node, a, d.tags["b"] ?? a)
    }
    return EditorState.create(EditorStateConfig(
        schema: schema, doc: d.node, selection: selection,
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
                         range: SearchRange? = nil, schema: Schema = basicSchema) throws {
    var state = mkSearchState(query, start, range: range, schema: schema)
    let result = command(state) { tr in state = state.apply(tr) }
    try expectEqual(result, next != nil)
    if let next {
        let expected = mkSearchState(query, next, range: range, schema: schema)
        try expectEqual(state.doc, expected.doc)
        try expect(state.selection.eq(expected.selection),
                   "selection \(state.selection.from)..\(state.selection.to), wanted \(expected.selection.from)..\(expected.selection.to)")
    }
}

// MARK: - The footnote schema (test-search.ts `footnoteSchema`)

/// `basicSchema` plus a `footnote` node: inline, with content, and `atom`.
///
/// Upstream adds it before `image` and comments that atom "makes the view treat
/// the node as a leaf, even though it technically has content" — which is the
/// point of these cases. Search still has to look inside it, so `blockText`
/// pads a non-leaf inline child rather than standing it in with U+FFFC.
private let footnoteSchema: Schema = {
    var nodes: [(String, NodeSpec)] = [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
        ("horizontal_rule", NodeSpec(group: "block")),
        ("heading", NodeSpec(content: "inline*", group: "block",
                             attrs: ["level": AttributeSpec(default: .int(1))], defining: true)),
        ("code_block", NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true)),
        ("text", NodeSpec(group: "inline")),
        ("footnote", NodeSpec(content: "text*", group: "inline", inline: true, atom: true)),
        ("image", NodeSpec(group: "inline", inline: true,
                           attrs: ["src": AttributeSpec(), "alt": AttributeSpec(default: .null),
                                   "title": AttributeSpec(default: .null)])),
        ("hard_break", NodeSpec(group: "inline", inline: true)),
    ]
    let marks: [(String, MarkSpec)] = [
        ("link", MarkSpec(attrs: ["href": AttributeSpec(), "title": AttributeSpec(default: .null)], inclusive: false)),
        ("em", MarkSpec()), ("strong", MarkSpec()), ("code", MarkSpec()),
    ]
    return try! Schema(nodes: nodes, marks: marks, topNode: "doc")
}()

/// `p("text", footnote("…"))`, with `<a>`/`<b>` in the footnote's text marking
/// the selection — the shape all four upstream footnote cases take.
///
/// Hand-built because the builders in PMBuilder are bound to `basicSchema`.
/// The footnote's text begins at position 6: 1 into the paragraph, 4 for the
/// word "text", 1 into the footnote.
private func footnoteCase(_ inner: String) -> TaggedNode {
    var text = ""
    var tags: [String: Int] = [:]
    var rest = Substring(inner)
    while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
        text += rest[rest.startIndex..<open]
        tags[String(rest[rest.index(after: open)..<close])] = 6 + text.count
        rest = rest[rest.index(after: close)...]
    }
    text += rest
    let s = footnoteSchema
    let note = try! s.node("footnote", [:], content: Fragment.from([s.text(text)]))
    let paragraph = try! s.node("paragraph", [:],
                                content: Fragment.from([s.text("text"), note]))
    return TaggedNode(node: try! s.node("doc", [:], content: Fragment.from([paragraph])), tags: tags)
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
    // Case-insensitive literal search asks `range(of:options:)` to fold rather
    // than lowercasing every block first. These pin the cases where the two
    // spellings could disagree.
    test("PM SearchQuery: case-insensitive search is symmetric in either direction") {
        try queryTest(SearchQuery(search: "ABC", caseSensitive: false), p("<s1>abc<e1> x <s2>AbC<e2>"))
        try queryTest(SearchQuery(search: "abc", caseSensitive: false), p("<s1>ABC<e1> x <s2>aBc<e2>"))
    }
    test("PM SearchQuery: case-sensitive search still distinguishes case") {
        try queryTest(SearchQuery(search: "abc", caseSensitive: true), p("ABC x <s1>abc<e1>"))
    }
    test("PM SearchQuery: case-insensitive search folds non-ASCII") {
        try queryTest(SearchQuery(search: "STRASSE", caseSensitive: false), p("die <s1>strasse<e1>"))
        try queryTest(SearchQuery(search: "café", caseSensitive: false), p("un <s1>CAFÉ<e1>"))
        try queryTest(SearchQuery(search: "İSTANBUL", caseSensitive: false), p("in <s1>İstanbul<e1>"))
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

    // MARK: replaceCurrent inside a non-leaf atom (test-search.ts footnote cases)
    test("PM search replaceCurrent: replaces inside non-leaf atoms") {
        try testCommand(SearchQuery(search: "footnote", replace: "NOTE"),
                        footnoteCase("This is the <a>footnote<b> text"),
                        footnoteCase("This is the <a>NOTE<b> text"),
                        replaceCurrent, schema: footnoteSchema)
    }
    test("PM search replaceCurrent: replaces delimiters with regexp inside non-leaf atoms") {
        try testCommand(SearchQuery(search: "“([^”]+)”", regexp: true, replace: "$1"),
                        footnoteCase("This is the <a>“footnote”<b> text"),
                        footnoteCase("This is the <a>footnote<b> text"),
                        replaceCurrent, schema: footnoteSchema)
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
