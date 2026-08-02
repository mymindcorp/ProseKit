public import DocumentModel
public import DocumentTransform

// A port of prosemirror-changeset's changeset.ts: ChangeSet tracks the changes
// to a document from a point in the past, condensing step maps into a flat
// sequence of replacements and minimizing them by diffing content.

public final class ChangeSet<Data> {
    struct Config {
        let doc: Node
        let combine: (Data, Data) -> Data?
        let encoder: ChangesetTokenEncoder
    }

    let config: Config
    /// Replaced regions.
    public let changes: [Change<Data>]

    init(_ config: Config, _ changes: [Change<Data>]) {
        self.config = config
        self.changes = changes
    }

    /// The starting document of the change set.
    public var startDoc: Node { config.doc }

    /// Compute a new set with the given step maps and metadata added (one data
    /// value per map). Does not mutate this set. Note that, because of the
    /// simplification that runs after each add, incrementally adding steps may
    /// produce a different set than adding them all at once.
    public func addSteps(_ newDoc: Node, _ maps: [StepMap], _ data: [Data]) -> ChangeSet<Data> {
        // Build Change objects from the position maps, merge them into the
        // existing changes, then re-diff any change the new steps touched to
        // drop matching content from both sides.
        var stepChanges: [Change<Data>] = []
        for (i, map) in maps.enumerated() {
            let d = data[i]
            var off = 0
            map.forEach { fromA, toA, fromB, toB in
                stepChanges.append(Change(fromA + off, toA + off, fromB, toB,
                                          fromA == toA ? [] : [Span(toA - fromA, d)],
                                          fromB == toB ? [] : [Span(toB - fromB, d)]))
                off = (toB - fromB) - (toA - fromA)
            }
        }
        if stepChanges.isEmpty { return self }

        let newChanges = mergeAll(stepChanges, config.combine)
        let changes = Change.merge(self.changes, newChanges, config.combine)
        var updated = changes

        // Minimize changes when possible.
        var i = 0
        while i < updated.count {
            let change = updated[i]
            if change.fromA == change.toA || change.fromB == change.toB
                // Only look at changes that touch newly added changed ranges.
                || !newChanges.contains(where: { $0.toB > change.fromB && $0.fromB < change.toB }) {
                i += 1
                continue
            }
            let diff = computeDiff(config.doc.content, newDoc.content, change, config.encoder)
            // Fast path: when completely different, leave the change as is.
            if diff.count == 1, diff[0].fromB == 0, diff[0].toB == change.toB - change.fromB {
                i += 1
                continue
            }
            updated.replaceSubrange(i...i, with: diff)
            i += diff.count == 0 ? 0 : diff.count
        }

        return ChangeSet(config, updated)
    }

    /// Convenience: the same data value for every map.
    public func addSteps(_ newDoc: Node, _ maps: [StepMap], _ data: Data) -> ChangeSet<Data> {
        addSteps(newDoc, maps, Array(repeating: data, count: maps.count))
    }

    /// Map the data values of every span through a function.
    public func map(_ f: (Span<Data>) -> Data) -> ChangeSet<Data> {
        func mapSpan(_ span: Span<Data>) -> Span<Data> {
            Span(span.length, f(span))
        }
        return ChangeSet(config, changes.map { ch in
            Change(ch.fromA, ch.toA, ch.fromB, ch.toB, ch.deleted.map(mapSpan), ch.inserted.map(mapSpan))
        })
    }

    /// Compare two changesets and return the range (in new-document
    /// coordinates) in which they differ, if any. If the document changed
    /// between the sets, pass the maps for the steps that changed it, call
    /// this on the OLD set and pass the new one.
    public func changedRange(_ b: ChangeSet<Data>, _ maps: [StepMap]?,
                             isSameData: (Data, Data) -> Bool) -> (from: Int, to: Int)? {
        if b === self { return nil }
        let touched = maps.flatMap(touchedRange)
        let moved = touched.map { ($0.toB - $0.fromB) - ($0.toA - $0.fromA) } ?? 0
        func mapPos(_ p: Int) -> Int {
            guard let touched, p > touched.fromA else { return p }
            return p + moved
        }

        var from = touched?.fromB ?? 200_000_000
        var to = touched?.toB ?? -200_000_000
        func add(_ start: Int, _ end: Int) {
            from = min(start, from)
            to = max(end, to)
        }

        // NB: like upstream, iteration stops when either list is exhausted.
        let rA = changes, rB = b.changes
        var iA = 0, iB = 0
        while iA < rA.count && iB < rB.count {
            let rangeA = rA[iA], rangeB = rB[iB]
            if sameRanges(rangeA, rangeB, mapPos, isSameData) {
                iA += 1
                iB += 1
            } else if mapPos(rangeA.fromB) >= rangeB.fromB {
                add(rangeB.fromB, rangeB.toB)
                iB += 1
            } else {
                add(mapPos(rangeA.fromB), mapPos(rangeA.toB))
                iA += 1
            }
        }

        return from <= to ? (from, to) : nil
    }

    /// Create a changeset for the given starting document. `combine` compares
    /// and combines metadata — nil means incompatible, a value is the combined
    /// metadata for a merged range.
    public static func create(_ doc: Node,
                              combine: @escaping (Data, Data) -> Data?,
                              encoder: ChangesetTokenEncoder = .default,
                              changes: [Change<Data>] = []) -> ChangeSet<Data> {
        ChangeSet(Config(doc: doc, combine: combine, encoder: encoder), changes)
    }
}

public extension ChangeSet where Data: Equatable {
    /// Create a changeset with the upstream default combine: equal values
    /// merge, unequal ones stay separate.
    static func create(_ doc: Node, encoder: ChangesetTokenEncoder = .default) -> ChangeSet<Data> {
        create(doc, combine: { a, b in a == b ? a : nil }, encoder: encoder)
    }

    /// `changedRange` with span data compared by equality (upstream compares
    /// with `!==`; value types compare by value here).
    func changedRange(_ b: ChangeSet<Data>, maps: [StepMap]? = nil) -> (from: Int, to: Int)? {
        changedRange(b, maps, isSameData: { $0 == $1 })
    }
}

/// Divide-and-conquer merge of a series of ranges.
private func mergeAll<Data>(_ ranges: [Change<Data>], _ combine: (Data, Data) -> Data?,
                            _ start: Int = 0, _ end: Int? = nil) -> [Change<Data>] {
    let end = end ?? ranges.count
    if end == start + 1 { return [ranges[start]] }
    let mid = (start + end) >> 1
    return Change.merge(mergeAll(ranges, combine, start, mid),
                        mergeAll(ranges, combine, mid, end), combine)
}

private func endRange(_ maps: [StepMap]) -> (from: Int, to: Int)? {
    var from = 200_000_000, to = -200_000_000
    for map in maps {
        if from != 200_000_000 {
            from = map.map(from, -1)
            to = map.map(to, 1)
        }
        map.forEach { _, _, start, end in
            from = min(from, start)
            to = max(to, end)
        }
    }
    return from == 200_000_000 ? nil : (from, to)
}

private func touchedRange(_ maps: [StepMap]) -> (fromA: Int, toA: Int, fromB: Int, toB: Int)? {
    guard let b = endRange(maps), let a = endRange(maps.map { $0.invert() }.reversed()) else { return nil }
    return (a.from, a.to, b.from, b.to)
}

private func sameRanges<Data>(_ a: Change<Data>, _ b: Change<Data>,
                              _ map: (Int) -> Int, _ isSameData: (Data, Data) -> Bool) -> Bool {
    map(a.fromB) == b.fromB && map(a.toB) == b.toB
        && sameSpans(a.deleted, b.deleted, isSameData) && sameSpans(a.inserted, b.inserted, isSameData)
}

private func sameSpans<Data>(_ a: [Span<Data>], _ b: [Span<Data>], _ isSameData: (Data, Data) -> Bool) -> Bool {
    guard a.count == b.count else { return false }
    for i in 0..<a.count where a[i].length != b[i].length || !isSameData(a[i].data, b[i].data) { return false }
    return true
}
