public import DocumentModel
import Foundation

// A schema-driven random document generator for the test suites.
//
// It walks each node type's content expression rather than working from a
// hand-written list of shapes, so a suite that fuzzes documents keeps covering
// the schema as extensions are added rather than drifting behind it. Lives in
// its own target because more than one test suite needs it and neither should
// own it.

// MARK: - Deterministic RNG

/// Seeded so any failure reproduces from the seed printed with it.
public struct SeededRNG: RandomNumberGenerator {
    private var s: UInt64
    public init(_ seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}

// MARK: - Schema-driven document generator

/// Builds random documents for a schema by walking node content expressions.
///
/// `focus` steers it: given a chain of types from the top node down to some
/// target, the generator takes that branch whenever it is on offer, which is
/// how corners a random walk rarely reaches (a figure's caption, a details
/// summary) end up in the corpus deterministically.
public struct DocGen {
    public let schema: Schema
    public var rng: SeededRNG
    /// A chain of types from the top node down to a target; see above.
    public var focus: [NodeType] = []
    /// A node budget, so a schema with nestable containers (a table whose cells
    /// take blocks, which include tables) can't produce a document too big to
    /// sweep — or to read in a failure message.
    private var budget = 0

    public init(schema: Schema, seed: UInt64) {
        self.schema = schema
        rng = SeededRNG(seed)
    }

    /// Deliberately awkward text. A document position is a grapheme cluster but
    /// an attributed string is indexed in UTF-16, and every layer that converts
    /// between them is somewhere an off-by-one can hide: a surrogate pair, a ZWJ
    /// sequence that is one cluster over many scalars, a combining mark that
    /// joins the character before it, and a CJK run that wraps anywhere.
    private static let alphabet: [Character] = Array("ab c d ef.") + ["🙂", "👩‍👩‍👧‍👦", "e\u{0301}", "漢", "字", "\u{200B}"]

    public mutating func randomText() -> String {
        let n = Int.random(in: 1 ... 6, using: &rng)
        return String((0 ..< n).map { _ in Self.alphabet.randomElement(using: &rng)! })
    }

    /// A random mark set the given parent will accept (`code_block` accepts
    /// none, and `addToSet` settles the exclusion rules for the rest).
    public mutating func randomMarks(allowedBy parent: NodeType) -> [Mark] {
        var set: [Mark] = []
        for _ in 0 ..< Int.random(in: 0 ... 2, using: &rng) {
            guard let name = schema.markSpecOrder.randomElement(using: &rng),
                  let type = schema.marks[name], parent.allowsMarkType(type) else { continue }
            var attrs: Attrs = [:]
            if type.attrs["href"] != nil { attrs["href"] = .string("https://example.com/a") }
            if type.attrs["color"] != nil { attrs["color"] = .string("#ff0000") }
            set = schema.mark(type, attrs).addToSet(set)
        }
        return set
    }

    /// Plausible values for attributes that carry the node's actual content.
    ///
    /// An attribute with a default was originally left at it, which sounds
    /// harmless and isn't: a footnote's `label` defaults to the empty string,
    /// so every generated footnote was an unlabelled one, and a formula's
    /// `latex` defaults to empty, so every generated formula was blank. Those
    /// are the degenerate cases, not the representative ones — a round-trip
    /// property fed only blanks reports on how blanks travel and never on how a
    /// footnote does. Each of these still gets an empty value some of the time,
    /// because the blank *is* a real state (a formula the user hasn't typed
    /// into yet) and worth covering — just not exclusively.
    /// An array rather than a dictionary, because this is walked while drawing
    /// from the RNG: Swift randomizes a `Dictionary`'s iteration order per
    /// process, so the same seed would draw in a different order on every run
    /// and a failure would stop reproducing from the seed printed with it.
    private static let contentfulAttrs: [(name: String, choices: [AttributeValue])] = [
        ("latex", [.string("x^2 + 1"), .string("\\frac{a}{b}"), .string("")]),
        ("label", [.string("1"), .string("note"), .string("")]),
        ("language", [.string("swift"), .string("json"), .string("")]),
        ("href", [.string("https://example.com/a"), .string("#anchor")]),
        ("src", [.string("image.png"), .string("https://example.com/i.png")]),
        ("alt", [.string("a picture"), .string("")]),
        ("title", [.string("a title"), .string("")]),
        ("text", [.string("Some Page"), .string("x")]),
        ("id", [.string("id-1"), .string("id-2")]),
    ]

    /// Required attributes get a placeholder, the ones that carry content get a
    /// plausible value, and a couple of optional ones get randomized so headings
    /// and task items aren't all identical.
    public mutating func randomAttrs(for type: NodeType) -> Attrs {
        var attrs: Attrs = [:]
        for (name, spec) in type.attrs where !spec.hasDefault {
            attrs[name] = .string(name == "src" ? "image.png" : "x")
        }
        for (name, choices) in Self.contentfulAttrs where type.attrs[name] != nil {
            attrs[name] = choices.randomElement(using: &rng)!
        }
        if type.attrs["level"] != nil { attrs["level"] = .int(Int.random(in: 1 ... 6, using: &rng)) }
        if type.attrs["checked"] != nil { attrs["checked"] = .bool(Bool.random(using: &rng)) }
        return attrs
    }

    /// The whole document. The top node always has a fill, so this can't fail.
    public mutating func randomDoc(depth: Int = 4, budget: Int = 90) -> Node {
        self.budget = budget
        return node(schema.topNodeType, depth: depth) ?? schema.topNodeType.createAndFill()!
    }

    /// A node of the given type, or `nil` when this type can't be built inside
    /// the remaining depth budget (the caller then tries a different type).
    public mutating func node(_ type: NodeType, depth: Int, parent: NodeType? = nil) -> Node? {
        budget -= 1
        if type.isText {
            return schema.text(randomText(), parent.map { randomMarks(allowedBy: $0) } ?? [])
        }
        let attrs = randomAttrs(for: type)
        if type.name == "table" { return randomTable(attrs: attrs, depth: depth) }
        if type.isLeaf { return try? type.create(attrs) }
        guard let content = randomContent(of: type, depth: depth) else {
            return type.createAndFill(attrs)
        }
        return (try? type.createChecked(attrs, content: content)) ?? type.createAndFill(attrs, content: content)
    }

    /// Walk the content expression, picking a random (or focused) type at each
    /// edge, then let `fillBefore` complete whatever the expression still
    /// requires — so the result is always valid content for `type`.
    private mutating func randomContent(of type: NodeType, depth: Int) -> Fragment? {
        var match = type.contentMatch
        var children: [Node] = []
        let limit = Int.random(in: 1 ... 3, using: &rng)
        // Keep going past `limit` while a focus step is still pending: an
        // optional tail like a figure's `figcaption?` only becomes available
        // after the required content in front of it, so a one-child node would
        // never reach it. The attempt cap stops a focus this node can't satisfy
        // from padding it forever.
        var attempts = 0
        while children.count < limit || !focus.isEmpty {
            attempts += 1
            if attempts > 8 { break }
            if match.validEnd, focus.isEmpty, Int.random(in: 0 ..< 4, using: &rng) == 0 { break }
            var candidates = match.edgeTypes.filter { canBuild($0, depth: depth) }
            var built: (NodeType, Node)?
            // Take the focused branch when it is available here.
            if let want = focus.first, let i = candidates.firstIndex(where: { $0 === want }) {
                candidates.remove(at: i)
                // Spend the step *before* recursing: the subtree consumes the
                // rest of the path itself, so popping afterwards would drop
                // whatever it had already consumed.
                let saved = focus
                focus.removeFirst()
                if let n = node(want, depth: depth - 1, parent: type) { built = (want, n) } else { focus = saved }
            }
            while built == nil, !candidates.isEmpty {
                let t = candidates.remove(at: Int.random(in: 0 ..< candidates.count, using: &rng))
                if let n = node(t, depth: depth - 1, parent: type) { built = (t, n) }
            }
            guard let (chosen, child) = built, let next = match.matchType(chosen) else { break }
            children.append(child)
            match = next
        }
        guard let tail = match.fillBefore(.empty, toEnd: true) else { return nil }
        return Fragment.from(children).append(tail)
    }

    /// Tables get built by hand rather than from the content expression: a
    /// random `tableRow+` walk produces ragged rows, which are schema-valid but
    /// not a table any `TableMap` consumer is meant to see.
    ///
    /// Some of the cells span. That is the whole reason this can't be a plain
    /// nested loop: a merged cell is where every table position stops being
    /// derivable from `(row, column)` — `TableMap` has to look it up, a
    /// `CellSelection` over one has to grow to a rectangle, and a column delete
    /// under one has to narrow it rather than remove it. The corpus had none.
    /// Every sweep that walks a *static* document — the selection sweeps, the
    /// serializer round-trips, the structural predicates — was therefore only
    /// ever shown the uniform grid, while the only spanning tables in the
    /// package were the ones a live fuzz built with `mergeCells`, which no
    /// static sweep ever sees.
    ///
    /// The occupancy grid is what keeps the result a table rather than a mess:
    /// a span is only taken when the slots it would cover are free and inside
    /// the grid, so every row still adds up to the same width and the map stays
    /// rectangular — which is the invariant `TableMap` is written against, and
    /// the one a ragged random walk breaks.
    private mutating func randomTable(attrs: Attrs, depth: Int) -> Node? {
        guard let table = schema.nodes["table"], let row = schema.nodes["tableRow"],
              let cell = schema.nodes["tableCell"], let header = schema.nodes["tableHeader"] else { return nil }
        // Rows and cells never come from the content walk, so spend the focus
        // steps this builder is about to satisfy itself — otherwise a path that
        // ends at `tableRow` stays pending forever and keeps every later node
        // padding itself out looking for it.
        var wantsHeader = false
        while let want = focus.first, want === row || want === cell || want === header {
            if want === header { wantsHeader = true }
            focus.removeFirst()
        }
        let rows = Int.random(in: 1 ... 3, using: &rng)
        let cols = Int.random(in: 1 ... 3, using: &rng)
        let headerRow = wantsHeader || Bool.random(using: &rng)
        // One in three tables merges; the rest stay uniform, because the plain
        // grid is still the common case and a corpus of nothing but merged
        // tables would be as lopsided as one with none.
        let spanning = rows > 1 && cols > 1 && Int.random(in: 0 ..< 3, using: &rng) == 0

        var taken = Array(repeating: false, count: rows * cols)
        var rowNodes: [Node] = []
        for r in 0 ..< rows {
            var cells: [Node] = []
            for c in 0 ..< cols where !taken[r * cols + c] {
                var colspan = 1, rowspan = 1
                if spanning, Bool.random(using: &rng) {
                    let wantCols = Int.random(in: 1 ... Swift.min(2, cols - c), using: &rng)
                    // A header row that spans downward would put a header cell
                    // in a body row, which is a table no command in the kit can
                    // produce and not the shape this is here to cover.
                    let wantRows = headerRow && r == 0 ? 1 : Int.random(in: 1 ... Swift.min(2, rows - r), using: &rng)
                    var free = true
                    for rr in r ..< r + wantRows {
                        for cc in c ..< c + wantCols where taken[rr * cols + cc] { free = false }
                    }
                    // Only take the span when every slot under it is still free;
                    // otherwise this cell stays 1×1 and the grid stays square.
                    if free { colspan = wantCols; rowspan = wantRows }
                }
                for rr in r ..< r + rowspan {
                    for cc in c ..< c + colspan { taken[rr * cols + cc] = true }
                }
                let type = (headerRow && r == 0) ? header : cell
                var cellAttrs: Attrs = [:]
                if colspan > 1 { cellAttrs["colspan"] = .int(colspan) }
                if rowspan > 1 { cellAttrs["rowspan"] = .int(rowspan) }
                let body = randomContent(of: type, depth: Swift.max(1, depth - 3)) ?? .empty
                guard let node = type.createAndFill(cellAttrs, content: body) else { return nil }
                cells.append(node)
            }
            guard let node = try? row.createChecked([:], content: Fragment.from(cells)) else { return nil }
            rowNodes.append(node)
        }
        return try? table.createChecked(attrs, content: Fragment.from(rowNodes))
    }

    private func canBuild(_ type: NodeType, depth: Int) -> Bool {
        if type.isText || type.isLeaf { return true }
        // Past the budget only leaves and text still fit, so every open node
        // closes on its next child.
        if budget <= 0 && (focus.isEmpty || budget <= -40) { return false }
        if type.name == "table" { return depth >= 3 } // table > row > cell > block > text
        return depth > 0
    }
}

// MARK: - Walking the schema

/// Every node type that can appear anywhere inside `type`'s content, found by
/// walking its content DFA (`edgeTypes` only reports one state's edges).
public func contentTypes(of type: NodeType) -> [NodeType] {
    var seen: [ContentMatch] = []
    var out: [NodeType] = []
    func walk(_ match: ContentMatch) {
        if seen.contains(where: { $0 === match }) { return }
        seen.append(match)
        for t in match.edgeTypes {
            if !out.contains(where: { $0 === t }) { out.append(t) }
            if let next = match.matchType(t) { walk(next) }
        }
    }
    walk(type.contentMatch)
    return out
}

/// A shortest chain of types from the top node down to `target`, for `DocGen.focus`.
public func typePath(to target: NodeType, in schema: Schema) -> [NodeType]? {
    if target === schema.topNodeType { return [] }
    var queue: [(NodeType, [NodeType])] = [(schema.topNodeType, [])]
    var seen: [NodeType] = [schema.topNodeType]
    while !queue.isEmpty {
        let (type, path) = queue.removeFirst()
        for next in contentTypes(of: type) {
            if next === target { return path + [next] }
            if seen.contains(where: { $0 === next }) { continue }
            seen.append(next)
            queue.append((next, path + [next]))
        }
    }
    return nil
}

/// The node types a document can actually contain, top node included.
public func reachableTypes(in schema: Schema) -> [NodeType] {
    var out: [NodeType] = [schema.topNodeType]
    var i = 0
    while i < out.count {
        for t in contentTypes(of: out[i]) where !out.contains(where: { $0 === t }) { out.append(t) }
        i += 1
    }
    return out
}

public func nodeTypeNames(in doc: Node) -> Set<String> {
    var names: Set<String> = [doc.type.name]
    doc.descendants { node, _, _, _ in names.insert(node.type.name); return true }
    return names
}

// MARK: - The corpus

/// A deterministic corpus: `count` random documents, preceded by one document
/// steered at each node type in the schema.
public func generatedCorpus(_ schema: Schema, count: Int) -> [(seed: String, doc: Node)] {
    // `PROSEKIT_FUZZ_DOCS=400` deepens every sweep for an ad-hoc hunt without
    // touching the per-test numbers, which are sized for a routine run.
    let count = ProcessInfo.processInfo.environment["PROSEKIT_FUZZ_DOCS"].flatMap(Int.init) ?? count
    var docs: [(String, Node)] = []
    for (i, type) in reachableTypes(in: schema).enumerated() where type !== schema.topNodeType {
        guard let path = typePath(to: type, in: schema) else { continue }
        var gen = DocGen(schema: schema, seed: UInt64(1000 + i))
        gen.focus = path
        docs.append(("focus:\(type.name)", gen.randomDoc(depth: Swift.max(4, path.count + 1))))
    }
    for seed in 1 ... count {
        var gen = DocGen(schema: schema, seed: UInt64(seed))
        docs.append(("seed:\(seed)", gen.randomDoc(depth: Int(seed % 3) + 3)))
    }
    return docs
}

