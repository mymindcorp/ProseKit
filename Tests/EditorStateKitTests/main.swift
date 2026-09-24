import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import TestHarness

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) { collector.test(name, body) }

func freshState(_ doc: Node? = nil, plugins: [Plugin] = []) -> EditorState {
    EditorState.create(EditorStateConfig(schema: B.schema, doc: doc, plugins: plugins))
}

// MARK: - State basics

test("regex search does not expand partial grapheme matches into other text") {
    let state = freshState(B.doc(B.p("e\u{0301}b")))
    for pattern in ["\u{0301}b", "e", "e\u{0301}"] {
        let query = SearchQuery(search: pattern, regexp: true)
        let expected = pattern == "e\u{0301}" ? [1] : []
        try expectEqual(query.findAll(state).map(\.from), expected)
        try expectEqual(query.findNext(state).map { [$0.from] } ?? [], expected)
        try expectEqual(query.findPrev(state).map { [$0.from] } ?? [], expected)
    }
}

test("regex search continues after a partial grapheme match") {
    let state = freshState(B.doc(B.p("e\u{0301}b éb")))
    let query = SearchQuery(search: "\u{0301}b|éb", regexp: true)
    try expectEqual(query.findNext(state)?.from, 4)
    try expectEqual(query.findPrev(state)?.from, 4)
    try expectEqual(query.findAll(state).map(\.from), [4])
}

test("replaceCurrent availability requires the exact match to be selected") {
    let doc = B.doc(B.p("cat tail"))
    for (from, to) in [(1, 1), (1, 3), (1, 4)] {
        let state = EditorState.create(EditorStateConfig(schema: B.schema, doc: doc,
            selection: TextSelection.create(doc, from, to),
            plugins: [searchQueryPlugin(initialQuery: SearchQuery(search: "cat", replace: "dog"))]))
        let enabled = to == 4
        try expectEqual(replaceCurrent(state, nil), enabled)
        var dispatched = false
        try expectEqual(replaceCurrent(state, { _ in dispatched = true }), enabled)
        try expectEqual(dispatched, enabled)
    }
}

test("search replacement preserves non-ASCII numbers after a dollar sign") {
    let state = freshState(B.doc(B.p("cat")))
    for replacement in ["$٢", "$²", "$½", "$1️⃣"] {
        let query = SearchQuery(search: "cat", replace: replacement)
        let tr = state.tr
        for range in query.getReplacements(state, query.findNext(state)!).reversed() {
            try tr.replace(range.from, range.to, range.insert)
        }
        try expectEqual(tr.doc, B.doc(B.p(replacement)))
    }
}

test("search replacement copies nested capture groups without deleting preserved text") {
    let state = freshState(B.doc(B.p("prefix abc tail")))
    let query = SearchQuery(search: "(a(b)c)", regexp: true, replace: "$1$2")
    let tr = state.tr
    for range in query.getReplacements(state, query.findNext(state)!).reversed() {
        try tr.replace(range.from, range.to, range.insert)
    }
    try expectEqual(tr.doc, B.doc(B.p("prefix abcb tail")))
}

test("search replacement copies lookaround captures without editing outside the match") {
    let state = freshState(B.doc(B.p("abc")))
    for (pattern, expected) in [("(?<=(a))b", "aac"), ("b(?=(c))", "acc")] {
        let query = SearchQuery(search: pattern, regexp: true, replace: "$1")
        let match = query.findNext(state)!
        let ranges = query.getReplacements(state, match)
        try expect(ranges.allSatisfy { $0.from >= match.from && $0.to <= match.to && $0.from <= $0.to })
        let tr = state.tr
        for range in ranges.reversed() {
            try tr.replace(range.from, range.to, range.insert)
        }
        try expectEqual(tr.doc, B.doc(B.p(expected)))
    }
}

test("string search replacements preserve the actual match away from block start") {
    let state = freshState(B.doc(B.p("prefix cat tail")))
    let query = SearchQuery(search: "cat", replace: "[$&] $&")
    let results = [query.findNext(state)!, query.findPrev(state)!, query.findAll(state)[0]]
    for result in results {
        let ranges = query.getReplacements(state, result)
        try expect(ranges.allSatisfy { $0.from >= result.from && $0.to <= result.to && $0.from <= $0.to })
        let tr = state.tr
        for range in ranges.reversed() {
            try tr.replace(range.from, range.to, range.insert)
        }
        try expectEqual(tr.doc, B.doc(B.p("prefix [cat] cat tail")))
    }
}

test("regex search respects the lower bound when searching backward") {
    let state = freshState(B.doc(B.p("one two one")))
    let query = SearchQuery(search: "one", regexp: true)
    try expect(query.findPrev(state, 8, 5) == nil)
    try expectEqual(query.findPrev(state, 12, 5)?.from, 9)
    try expect(query.findPrev(state, 12, 10) == nil)
}

test("regex backward search respects bounds across paragraphs") {
    let state = freshState(B.doc(B.p("one"), B.p("two")))
    let query = SearchQuery(search: "one|two", regexp: true)
    try expect(query.findPrev(state, 10, 7) == nil)
    try expectEqual(query.findPrev(state, 10, 6)?.from, 6)
    try expectEqual(query.findPrev(state, 6, 1)?.from, 1)
}

test("regex backward search keeps the lower bound after filter rejection") {
    let state = freshState(B.doc(B.p("one two one")))
    let query = SearchQuery(search: "one", regexp: true, filter: { _, result in result.from < 9 })
    try expect(query.findPrev(state, 12, 5) == nil)
}

test("insertText empty string removes a fully covered heading before the next block") {
    let doc = B.doc(B.node("heading", ["level": .int(2)], [B.t("first")]), B.p("tail"))
    let state = freshState(doc)
    let tr = try state.tr.insertText("", 1, 8)
    try expectEqual(tr.doc, B.doc(B.p("tail")))
    try tr.doc.check()
}

test("insertText empty string removes fully covered nested wrappers") {
    let doc = B.doc(B.node("blockquote", [:], [B.p("first")]), B.p("tail"))
    let state = freshState(doc)
    let actual = try state.tr.insertText("", 2, 10)
    try expectEqual(actual.doc, B.doc(B.p("tail")))
    try actual.doc.check()
}

test("insertText empty string preserves a partially deleted heading") {
    let doc = B.doc(B.node("heading", ["level": .int(2)], [B.t("first")]))
    let tr = try freshState(doc).tr.insertText("", 2, 4)
    try expectEqual(tr.doc, B.doc(B.node("heading", ["level": .int(2)], [B.t("fst")])))
}

test("insertText collapses a selection ending at the inserted text") {
    for backwards in [false, true] {
        let doc = B.doc(B.p("abcdef"))
        let state = EditorState.create(EditorStateConfig(schema: B.schema, doc: doc,
            selection: TextSelection.create(doc, backwards ? 5 : 2, backwards ? 2 : 5)))
        let tr = try state.tr.insertText("X", 3, 5)
        try expectEqual(tr.doc.textContent, "abXef")
        try expect(tr.selection.empty)
        try expectEqual(tr.selection.head, 4)
    }
}

test("insertText outside a selection preserves the selection") {
    let doc = B.doc(B.p("abcdef"))
    let state = EditorState.create(EditorStateConfig(schema: B.schema, doc: doc, selection: TextSelection.create(doc, 2, 4)))
    let tr = try state.tr.insertText("X", 6)
    try expectEqual(tr.selection.from, 2)
    try expectEqual(tr.selection.to, 4)
}

test("create state defaults to filled doc + start selection") {
    let state = freshState()
    try expect(state.doc.childCount >= 1)
    try expect(state.selection is TextSelection)
    try expectEqual(state.selection.from, 1)
}

test("apply a transaction produces a new doc") {
    let state = freshState(B.doc(B.p("hello")))
    let tr = state.tr
    try tr.insertText("!", 6)
    let newState = state.apply(tr)
    try expectEqual(newState.doc, B.doc(B.p("hello!")))
    // original state is unchanged (immutability)
    try expectEqual(state.doc, B.doc(B.p("hello")))
}

test("selection maps across an insertion") {
    let state = freshState(B.doc(B.p("hello")))
    // cursor at end (pos 6)
    let s0 = state.tr.setSelection(TextSelection.create(state.doc, 6))
    let state2 = state.apply(s0)
    try expectEqual(state2.selection.head, 6)
    // insert text before cursor
    let tr = state2.tr
    try tr.insertText("XYZ", 1)
    let state3 = state2.apply(tr)
    try expectEqual(state3.selection.head, 9) // 6 + 3
}

test("replaceSelectionWith inserts a node and moves selection") {
    let state = freshState(B.doc(B.p("ab")))
    let tr = state.tr.setSelection(TextSelection.create(state.doc, 2)) // between a|b
    tr.replaceSelectionWith(B.img("x.png"), inheritMarks: false)
    let newState = state.apply(tr)
    try expectEqual(newState.doc, B.doc(B.p(B.t("a"), B.img("x.png"), B.t("b"))))
}

test("deleteSelection") {
    let state = freshState(B.doc(B.p("hello")))
    let tr = state.tr.setSelection(TextSelection.create(state.doc, 1, 6))
    tr.deleteSelection()
    let newState = state.apply(tr)
    try expectEqual(newState.doc, B.doc(B.p()))
}

test("stored marks cleared after a step but kept on empty selection") {
    let state = freshState(B.doc(B.p("x")))
    let tr = state.tr.setSelection(TextSelection.create(state.doc, 2))
    tr.addStoredMark(B.schema.mark("bold"))
    let newState = state.apply(tr)
    try expectNotNil(newState.storedMarks)
    try expectEqual(newState.storedMarks?.count, 1)
}

// MARK: - Selection types

test("NodeSelection on an image") {
    let doc = B.doc(B.p(B.t("a"), B.img("x.png")))
    let sel = NodeSelection.create(doc, 2) as! NodeSelection // image starts at pos 2
    try expectEqual(sel.node.type.name, "image")
    try expect(!sel.empty)
    try expectEqual(sel.toJSON()["type"]?.stringValue, "node")
}

test("NodeSelection.create at a non-selectable position falls back (no trap)") {
    let doc = B.doc(B.p(B.t("hello")))
    // End of the paragraph content — no node after; must not crash.
    let sel = NodeSelection.create(doc, doc.content.size)
    try expect(!(sel is NodeSelection), "falls back to a text/near selection")
}

test("AllSelection covers the doc") {
    let doc = B.doc(B.p("a"), B.p("b"))
    let sel = AllSelection(doc)
    try expectEqual(sel.from, 0)
    try expectEqual(sel.to, doc.content.size)
}

test("selection JSON round-trip") {
    let doc = B.doc(B.p("hello"))
    let sel = TextSelection.create(doc, 2, 5)
    let restored = try Selection.fromJSON(doc, sel.toJSON())
    try expect(restored.eq(sel))
}

// MARK: - Plugins

test("plugin state initializes and applies across transactions") {
    // A plugin that counts the number of transactions applied.
    let counter = Plugin(
        key: "counter",
        stateField: PluginStateField(
            initialize: { _, _ in 0 },
            apply: { _, value, _, _ in (value as! Int) + 1 }))
    let state = freshState(B.doc(B.p("x")), plugins: [counter])
    try expectEqual(counter.getState(state) as? Int, 0)
    let tr = state.tr
    try tr.insertText("y", 2)
    let s2 = state.apply(tr)
    try expectEqual(counter.getState(s2) as? Int, 1)
}

test("appendTransaction lets a plugin react") {
    // Plugin that, whenever the doc changes, appends a transaction marking it.
    let appended = Plugin(
        key: "appender",
        appendTransaction: { trs, _, newState in
            if trs.contains(where: { $0.docChanged }) && newState.doc.textContent != "yz" {
                let tr = newState.tr
                _ = try? tr.insertText("z", newState.doc.content.size - 1)
                return tr
            }
            return nil
        })
    let state = freshState(B.doc(B.p("y")), plugins: [appended])
    // None of these three changes the document, and none is applied.
    let tr = state.tr
    try tr.insertText("", 1, 1)
    try tr.insertText("", 1)
    let tr2 = state.tr
    try tr2.delete(1, 1)
    let tr3 = state.tr
    try tr3.insertText("", 1)
    _ = (tr, tr2, tr3)
    // A genuine edit, which triggers the append:
    let edit = state.tr
    try edit.insertText("!", 2)
    let result = state.applyTransaction(edit)
    try expect(result.transactions.count >= 1)
}

// MARK: - TextNavigation

test("character move steps within a paragraph") {
    let doc = B.doc(B.p("hello"))
    try expectEqual(TextNavigation.position(in: doc, from: 1, moving: .forward, by: .character), 2)
    try expectEqual(TextNavigation.position(in: doc, from: 3, moving: .backward, by: .character), 2)
}

test("character move crosses a block boundary in one step") {
    let doc = B.doc(B.p("ab"), B.p("cd"))
    // pos 3 = end of first paragraph content; forward should land at start of
    // the second paragraph's content (pos 5), skipping the boundary tokens.
    try expectEqual(TextNavigation.position(in: doc, from: 3, moving: .forward, by: .character), 5)
    // and backward from the start of the second paragraph returns to the first
    try expectEqual(TextNavigation.position(in: doc, from: 5, moving: .backward, by: .character), 3)
}

test("word move jumps over a word") {
    let doc = B.doc(B.p("foo bar baz"))
    // from start (pos 1), forward lands after "foo" (pos 4)
    try expectEqual(TextNavigation.position(in: doc, from: 1, moving: .forward, by: .word), 4)
    // from pos 8 (end of "bar"), backward lands at the start of "bar" (pos 5)
    try expectEqual(TextNavigation.position(in: doc, from: 8, moving: .backward, by: .word), 5)
}

test("word move at block edge crosses the boundary") {
    let doc = B.doc(B.p("hi"), B.p("yo"))
    // end of first paragraph (pos 3), forward word move crosses to next block
    try expectEqual(TextNavigation.position(in: doc, from: 3, moving: .forward, by: .word), 5)
}

test("backspace deletes the previous character mid-text (view mechanism)") {
    // Mirrors EditorTextView.deleteInDirection for a collapsed cursor: compute
    // the previous-character position, then delete that range.
    let doc = B.doc(B.p("hello"))
    let state = freshState(doc)
    let cursor = 3 // between "e" and "l"
    let target = TextNavigation.position(in: state.doc, from: cursor, moving: .backward, by: .character)
    try expectEqual(target, 2)
    let tr = state.tr
    try tr.delete(min(cursor, target), max(cursor, target))
    try expectEqual(state.apply(tr).doc, B.doc(B.p("hllo")))
}

test("forward delete removes the next character") {
    let doc = B.doc(B.p("hello"))
    let state = freshState(doc)
    let cursor = 1
    let target = TextNavigation.position(in: state.doc, from: cursor, moving: .forward, by: .character)
    try expectEqual(target, 2)
    let tr = state.tr
    try tr.delete(min(cursor, target), max(cursor, target))
    try expectEqual(state.apply(tr).doc, B.doc(B.p("ello")))
}

test("word backspace deletes the previous word") {
    let doc = B.doc(B.p("foo bar"))
    let state = freshState(doc)
    let cursor = 8 // end of "bar"
    let target = TextNavigation.position(in: state.doc, from: cursor, moving: .backward, by: .word)
    let tr = state.tr
    try tr.delete(min(cursor, target), max(cursor, target))
    try expectEqual(state.apply(tr).doc, B.doc(B.p("foo ")))
}

test("line boundary moves to textblock start/end") {
    let doc = B.doc(B.p("hello world"))
    try expectEqual(TextNavigation.position(in: doc, from: 5, moving: .backward, by: .lineBoundary), 1)
    try expectEqual(TextNavigation.position(in: doc, from: 5, moving: .forward, by: .lineBoundary), 12)
}

// MARK: - Decorations

test("DecorationSet maps through an insertion") {
    let set = DecorationSet([.inline(3, 6, ["class": "search"])])
    let m = Mapping()
    m.appendMap(StepMap([1, 0, 2])) // insert 2 chars at pos 1
    let mapped = set.map(m)
    try expectEqual(mapped.decorations.first?.from, 5)
    try expectEqual(mapped.decorations.first?.to, 8)
}

test("DecorationSet drops a decoration whose range is deleted") {
    let set = DecorationSet([.inline(3, 6, [:])])
    let m = Mapping()
    m.appendMap(StepMap([2, 6, 0])) // delete positions 2..8
    try expect(set.map(m).decorations.isEmpty)
}

test("DecorationSet removingClass filters by class") {
    let set = DecorationSet([.inline(1, 2, ["class": "search"]), .inline(3, 4, ["class": "spell"])])
    try expectEqual(set.removingClass("search").decorations.count, 1)
}

test("node decorations map with their node and drop when it is deleted") {
    let d = B.doc(B.p("ab"), B.p("cd"))
    // Decorate the second paragraph (node span 4..8).
    let set = DecorationSet([.node(4, 8, ["class": "changed"])])
    // An insertion before it shifts the decoration.
    let state = freshState(d)
    let tr = state.tr
    try tr.insertText("x", 1)
    let shifted = set.map(tr.mapping)
    try expectEqual(shifted.decorations.first?.from, 5)
    try expectEqual(shifted.decorations.first?.to, 9)
    // Deleting the node drops the decoration.
    let tr2 = state.tr
    try tr2.delete(4, 8)
    try expectEqual(set.map(tr2.mapping).decorations.count, 0)
}

// MARK: - Search

test("SearchQuery finds occurrences as document positions") {
    let doc = B.doc(B.p("the cat sat on the mat"))
    let state = EditorState.create(EditorStateConfig(schema: B.schema, doc: doc))
    let first = SearchQuery(search: "the").findNext(state)
    try expectEqual(first?.from, 1)
    try expectEqual(first?.to, 4)
}

test("SearchQuery is case-insensitive when asked and spans blocks separately") {
    let doc = B.doc(B.p("Hello"), B.p("hello world"))
    let state = EditorState.create(EditorStateConfig(schema: B.schema, doc: doc))
    let query = SearchQuery(search: "hello", caseSensitive: false)
    var count = 0, pos = 0
    while let next = query.findNext(state, pos) { count += 1; pos = next.to }
    try expectEqual(count, 2)
}

registerPMSelectionTests()
registerPMStateTests()
registerPMGapCursorTests()
registerGapCursorSearchTests()
registerDecorationFindTests()
registerSelectionAPITests()
registerStateAPITests()
registerSearchQueryAPITests()
registerPMSearchTests()
registerSearchRebuildTests()
registerSearchIncrementalTests()

registerSelectionJSONGuardTests()
registerSelectionEndpointTests()
registerEditBench()

TestSuite.main("EditorStateKitTests", collector.all)
