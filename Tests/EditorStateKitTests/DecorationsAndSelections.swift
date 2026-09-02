import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import TestHarness

// `DecorationSet.find(from, to)` is what every paint asks — which decorations
// touch the viewport — and it answers with a pair of binary searches over a
// running maximum. Nothing headless called it: the renderer is the only
// client, and the renderer's tests are iOS-only. The property below pins it
// against the obvious scan, on sorted sets (the fast path) and unsorted ones
// (the fallback), with widgets at the query's edges where an off-by-one hides.
//
// The rest are the selection, transaction, state, and search entry points that
// had no direct test.

/// A small seeded generator, so a failure names the seed that produced it.
private struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

private func overlaps(_ d: Decoration, _ from: Int, _ to: Int) -> Bool {
    d.from < to && d.to > from || (d.kind == .widget && d.from >= from && d.from <= to)
}

private func randomDecorations(_ rng: inout LCG, count: Int, span: Int) -> [Decoration] {
    (0..<count).map { i in
        let from = rng.int(span)
        switch rng.int(3) {
        case 0: return .widget(from, ["i": "\(i)"])
        case 1: return .node(from, from + 1 + rng.int(6), ["i": "\(i)"])
        default: return .inline(from, from + 1 + rng.int(12), ["i": "\(i)"])
        }
    }
}

func registerDecorationFindTests() {
    test("DecorationSet.find: a sorted set answers exactly what a scan would") {
        for seed in 1...40 {
            var rng = LCG(state: UInt64(seed))
            let decos = randomDecorations(&rng, count: 1 + rng.int(60), span: 80)
                .sorted { $0.from < $1.from }
            let set = DecorationSet(decos)
            for _ in 0..<25 {
                let a = rng.int(90), b = rng.int(90)
                let from = min(a, b), to = max(a, b)
                let expected = decos.filter { overlaps($0, from, to) }
                let found = set.find(from, to)
                try expectEqual(found, expected, "seed \(seed), query \(from)..\(to)")
            }
        }
    }

    test("DecorationSet.find: an unsorted set falls back to the scan and agrees") {
        for seed in 1...20 {
            var rng = LCG(state: UInt64(1000 + seed))
            var decos = randomDecorations(&rng, count: 2 + rng.int(40), span: 60)
            // Make sure it really is out of order.
            decos.sort { $0.from < $1.from }
            decos.swapAt(0, decos.count - 1)
            let set = DecorationSet(decos)
            for _ in 0..<15 {
                let a = rng.int(70), b = rng.int(70)
                let from = min(a, b), to = max(a, b)
                let expected = decos.filter { overlaps($0, from, to) }
                try expectEqual(set.find(from, to), expected, "seed \(seed), query \(from)..\(to)")
            }
        }
    }

    test("DecorationSet.find: widgets count at either edge of the range, inline ranges don't") {
        let set = DecorationSet([
            .inline(0, 5, ["n": "before"]),   // ends exactly at from
            .widget(5, ["n": "atFrom"]),
            .inline(6, 8, ["n": "inside"]),
            .widget(10, ["n": "atTo"]),
            .inline(10, 12, ["n": "after"]),  // starts exactly at to
        ])
        let names = set.find(5, 10).map { $0.attributes["n"]! }
        try expectEqual(names, ["atFrom", "inside", "atTo"])
        try expectEqual(set.find(5, 5).map { $0.attributes["n"]! }, ["atFrom"], "an empty range still sees a widget on it")
    }

    test("DecorationSet.find: an earlier decoration that reaches past later ones is still found") {
        // Sorted by `from`, the long one comes first; a search bounded by
        // `from` alone would skip it.
        let set = DecorationSet([.inline(0, 100, ["n": "long"]), .inline(1, 2, [:]), .inline(3, 4, [:]), .inline(50, 51, [:])])
        try expectEqual(set.find(60, 70).map { $0.attributes["n"] ?? "" }, ["long"])
    }

    test("DecorationSet.find: with no range, everything") {
        let set = DecorationSet([.inline(1, 2, [:]), .widget(9, [:])])
        try expectEqual(set.find().count, 2)
        try expect(set.find(3, 4).isEmpty)
    }

    test("DecorationSet.adding: appends and stays queryable") {
        let set = DecorationSet([.inline(1, 2, ["n": "a"])]).adding([.inline(5, 6, ["n": "b"])])
        try expectEqual(set.decorations.count, 2)
        try expectEqual(set.find(5, 6).map { $0.attributes["n"]! }, ["b"])
        try expectEqual(set, DecorationSet([.inline(1, 2, ["n": "a"]), .inline(5, 6, ["n": "b"])]))
    }

    test("DecorationSet.map: a widget moves with insertions and goes when its position is deleted") {
        let set = DecorationSet([.widget(5, ["n": "w"])])
        let shift = Mapping()
        shift.appendMap(StepMap([1, 0, 3]))
        try expectEqual(set.map(shift).decorations.first?.from, 8)
        let remove = Mapping()
        remove.appendMap(StepMap([3, 5, 0])) // deletes 3..8
        try expect(set.map(remove).decorations.isEmpty)
    }

    test("DecorationSet.map: with the document, a node decoration whose node was split is dropped") {
        let d = B.doc(B.p("abcd"))
        let set = DecorationSet([.node(0, 6, ["n": "para"])])
        let state = EditorState.create(EditorStateConfig(schema: B.schema, doc: d))
        let split = state.tr
        try split.split(3)
        try expect(set.map(split.mapping, doc: split.doc).decorations.isEmpty, "the span now covers two paragraphs")
        try expectEqual(set.map(split.mapping).decorations.count, 1, "without the document the ends are trusted")
        let typed = state.tr
        try typed.insertText("x", 2)
        try expectEqual(set.map(typed.mapping, doc: typed.doc).decorations.first?.to, 7)
    }
}

// MARK: - Selections

/// A selection type of its own, to check what the base class provides.
private final class BareSelection: Selection {
    override func eq(_ other: Selection) -> Bool { other is BareSelection && other.anchor == anchor && other.head == head }
    override func map(_ doc: Node, _ mapping: any Mappable) -> Selection {
        BareSelection(doc.resolve(mapping.map(anchor)), doc.resolve(mapping.map(head)))
    }
    override func toJSON() -> [String: AttributeValue] { ["type": .string("bare")] }
}

func registerSelectionAPITests() {
    test("Selection.getBookmark: the default bookmarks the nearest text selection") {
        let d = B.doc(B.p("hello"))
        let sel = BareSelection(d.resolve(2), d.resolve(4))
        let restored = sel.getBookmark().resolve(d)
        try expect(restored is TextSelection)
        try expectEqual(restored.anchor, 2)
        try expectEqual(restored.head, 4)
    }

    test("NodeSelection.content: the selected node, closed on both sides") {
        let d = B.doc(B.p("a"), B.hr(), B.p("b"))
        let slice = NodeSelection.create(d, 3).content()
        try expectEqual(slice.openStart, 0)
        try expectEqual(slice.openEnd, 0)
        try expectEqual(slice.content, Fragment.from(B.hr()))
    }

    test("AllSelection.content: the whole document, with its parents") {
        let d = B.doc(B.p("a"), B.hr())
        let slice = AllSelection(d).content()
        try expectEqual(slice.content, d.content)
        try expectEqual(slice.openStart, 0)
        try expectEqual(slice.openEnd, 0)
    }

    test("TextSelection.between: two equal block-level positions collapse onto the text found") {
        let d = B.doc(B.p("ab"))
        let sel = TextSelection.between(d.resolve(0), d.resolve(0))
        try expect(sel is TextSelection)
        try expectEqual(sel.anchor, 1)
        try expectEqual(sel.head, 1)
    }

    test("NodeSelection.map: when the node is deleted, the selection lands nearby") {
        let d = B.doc(B.p("a"), B.hr(), B.p("b"))
        let state = EditorState.create(EditorStateConfig(schema: B.schema, doc: d, selection: NodeSelection.create(d, 3)))
        let tr = state.tr
        try tr.delete(3, 4)
        let next = state.apply(tr)
        try expect(!(next.selection is NodeSelection))
        try expectEqual(next.doc, B.doc(B.p("a"), B.p("b")))
    }

    test("NodeSelection bookmark: resolving where no selectable node remains gives a text selection") {
        let d = B.doc(B.p("a"), B.hr(), B.p("b"))
        let bookmark = NodeSelection.create(d, 3).getBookmark()
        let other = B.doc(B.p("abcdef"))
        let restored = bookmark.resolve(other)
        try expect(restored is TextSelection)
        try expectEqual(restored.head, 3)
    }
}

// MARK: - Transactions and state

func registerStateAPITests() {
    test("Transaction.removeStoredMark: drops one mark from the stored set and flags the change") {
        let d = B.doc(B.p(B.strong("ab")))
        let state = EditorState.create(EditorStateConfig(schema: B.schema, doc: d, selection: TextSelection.create(d, 3)))
        let untouched = state.tr
        try expect(!untouched.storedMarksSet)
        let tr = state.tr.removeStoredMark(B.schema.mark("bold"))
        try expect(tr.storedMarksSet)
        try expectEqual(tr.storedMarks?.count, 0, "the bold at the cursor is no longer stored")
        try tr.insertText("x")
        try expectEqual(tr.doc, B.doc(B.p(B.strong("ab"), B.t("x"))))
    }

    test("EditorState.reconfigure: a plugin already present keeps its state") {
        final class Counter: @unchecked Sendable { var value = 0 }
        let plugin = Plugin(key: "counter", stateField: PluginStateField(
            initialize: { _, _ in Counter() },
            apply: { _, value, _, _ in (value as! Counter).value += 1; return value }))
        let other = Plugin(key: "other", stateField: PluginStateField(initialize: { _, _ in "fresh" }, apply: { _, v, _, _ in v }))
        var state = EditorState.create(EditorStateConfig(schema: B.schema, plugins: [plugin]))
        state = state.apply(state.tr)
        state = state.apply(state.tr)
        try expectEqual((plugin.getState(state) as? Counter)?.value, 2)
        let reconfigured = state.reconfigure(plugins: [plugin, other])
        try expectEqual((plugin.getState(reconfigured) as? Counter)?.value, 2, "kept, not reinitialized")
        try expectEqual(other.getState(reconfigured) as? String, "fresh")
    }

    test("EditorState.fromJSON: JSON without a document is rejected") {
        try expectThrows { _ = try EditorState.fromJSON(EditorStateConfig(schema: B.schema), ["selection": .object([:])]) }
    }

    test("TextNavigation: a word step from a block boundary is a character step") {
        let d = B.doc(B.p("ab"), B.hr(), B.p("cd"))
        // Position 4 sits between the paragraph and the rule, in the document
        // itself — there are no words there to step over.
        let forward = TextNavigation.position(in: d, from: 4, moving: .forward, by: .word)
        let byChar = TextNavigation.position(in: d, from: 4, moving: .forward, by: .character)
        try expectEqual(forward, byChar)
    }

    test("TextNavigation.inlineCharacters: an inline atom is one placeholder character") {
        let para = B.p(B.t("a"), B.img("x"), B.t("b"))
        try expectEqual(TextNavigation.inlineCharacters(of: para), ["a", "\u{fffc}", "b"])
    }
}

// MARK: - Search queries

func registerSearchQueryAPITests() {
    test("SearchQuery.eq: compares the search, its flags, and the replacement") {
        let a = SearchQuery(search: "x", replace: "y")
        try expect(a.eq(SearchQuery(search: "x", replace: "y")))
        try expect(!a.eq(SearchQuery(search: "x", replace: "z")))
        try expect(!a.eq(SearchQuery(search: "x", caseSensitive: true, replace: "y")))
        try expect(!a.eq(SearchQuery(search: "x", regexp: true, replace: "y")))
        try expect(!a.eq(SearchQuery(search: "x", replace: "y", wholeWord: true)))
    }

    test("SearchQuery: \\n, \\t, \\r and \\\\ in a string query are unescaped unless literal") {
        let d = B.doc(B.p("a\nb\tc\rd\\e"))
        let state = EditorState.create(EditorStateConfig(schema: B.schema, doc: d))
        try expectEqual(SearchQuery(search: "a\\nb").findNext(state)?.from, 1)
        try expectEqual(SearchQuery(search: "b\\tc").findNext(state)?.from, 3)
        try expectEqual(SearchQuery(search: "c\\rd").findNext(state)?.from, 5)
        try expectEqual(SearchQuery(search: "d\\\\e").findNext(state)?.from, 7)
        try expectNil(SearchQuery(search: "a\\nb", literal: true).findNext(state))
        try expectEqual(SearchQuery(search: "d\\e", literal: true).findNext(state)?.from, 7)
        // A backslash before anything else is just a backslash.
        try expectEqual(SearchQuery(search: "d\\e").findNext(state)?.from, 7)
    }

    test("SearchQuery: an invalid regular expression matches nothing rather than throwing") {
        let d = B.doc(B.p("(a"))
        let state = EditorState.create(EditorStateConfig(schema: B.schema, doc: d))
        let query = SearchQuery(search: "(", regexp: true)
        try expect(!query.valid)
        try expectNil(query.findNext(state))
        try expectNil(query.findPrev(state))
        try expect(query.findAll(state).isEmpty)
    }

    test("SearchQuery: $$ in a replacement is a literal dollar sign") {
        let d = B.doc(B.p("price"))
        let query = SearchQuery(search: "(price)", regexp: true, replace: "$$$1")
        var state = EditorState.create(EditorStateConfig(schema: B.schema, doc: d, plugins: [searchQueryPlugin(initialQuery: query)]))
        try expect(replaceAll(state) { state = state.apply($0) })
        try expectEqual(state.doc.textContent, "$price")
    }

    test("getSearchQueryState: reads the plugin's query and range") {
        let query = SearchQuery(search: "x")
        let state = EditorState.create(EditorStateConfig(
            schema: B.schema, doc: B.doc(B.p("x")),
            plugins: [searchQueryPlugin(initialQuery: query, initialRange: SearchRange(from: 0, to: 3))]))
        let found = getSearchQueryState(state)
        try expect(found?.query.eq(query) == true)
        try expectEqual(found?.range, SearchRange(from: 0, to: 3))
        try expectNil(getSearchQueryState(EditorState.create(EditorStateConfig(schema: B.schema))))
    }
}
