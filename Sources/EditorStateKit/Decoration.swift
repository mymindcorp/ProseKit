public import DocumentModel
public import DocumentTransform

/// A visual decoration over a document range that does not change the document
/// itself — used for search highlights, spell-check underlines, collaboration
/// cursors, and similar overlays. (The deferred M2/M7 decoration layer.)
public struct Decoration: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Styles the inline content in `[from, to)`.
        case inline
        /// A zero-width marker at `from` (e.g. a remote collaborator's caret).
        case widget
        /// Styles a single node: `[from, to)` must span exactly one node
        /// (`from` just before it, `to` just after).
        case node
    }

    public let from: Int
    public let to: Int
    public let kind: Kind
    /// Style hints the renderer understands: `background`, `underline`,
    /// `color` (hex), and `class` (an identifying tag, e.g. "search").
    public let attributes: [String: String]

    public init(from: Int, to: Int, kind: Kind = .inline, attributes: [String: String] = [:]) {
        self.from = from
        self.to = to
        self.kind = kind
        self.attributes = attributes
    }

    /// An inline decoration over `[from, to)`.
    public static func inline(_ from: Int, _ to: Int, _ attributes: [String: String]) -> Decoration {
        Decoration(from: from, to: to, kind: .inline, attributes: attributes)
    }

    /// A widget decoration at `pos`.
    public static func widget(_ pos: Int, _ attributes: [String: String]) -> Decoration {
        Decoration(from: pos, to: pos, kind: .widget, attributes: attributes)
    }

    /// A node decoration spanning exactly the node in `[from, to)`.
    public static func node(_ from: Int, _ to: Int, _ attributes: [String: String]) -> Decoration {
        Decoration(from: from, to: to, kind: .node, attributes: attributes)
    }
}

/// An immutable collection of decorations that can be mapped forward through
/// document changes. (A simple flat implementation, not ProseMirror's optimized
/// tree — fine for the document sizes this editor targets.)
public struct DecorationSet: Sendable, Equatable {
    public let decorations: [Decoration]

    /// `reach[i]` is the largest `to` among `decorations[0...i]`, built only
    /// when the decorations arrive sorted by `from` — which is what walking a
    /// document to produce them gives, and what every set this editor builds
    /// does. Nil means "not sorted", and `find` falls back to a scan.
    ///
    /// Sorting by `from` alone cannot bound a range query from below: an
    /// earlier decoration may still reach past a later one. The running maximum
    /// can, and it is non-decreasing, so both ends of the query are a binary
    /// search. Deliberately *not* sorted here on the caller's behalf: the
    /// public array's order is observable, and reordering it to win a search
    /// would be a surprising thing for a constructor to do.
    private let reach: [Int]?

    public init(_ decorations: [Decoration] = []) {
        self.decorations = decorations
        var sorted = true
        for i in 1 ..< max(decorations.count, 1) where decorations[i].from < decorations[i - 1].from {
            sorted = false
            break
        }
        if sorted {
            var running = Int.min
            self.reach = decorations.map { running = max(running, $0.to); return running }
        } else {
            self.reach = nil
        }
    }

    /// Compares the decorations alone: `reach` is derived from them, and a
    /// synthesized `==` would compare it too.
    public static func == (lhs: DecorationSet, rhs: DecorationSet) -> Bool {
        lhs.decorations == rhs.decorations
    }

    public static let empty = DecorationSet()

    /// Whether a decoration overlaps `[from, to)` — widgets, being zero-width,
    /// count at either edge.
    private static func overlaps(_ d: Decoration, _ from: Int, _ to: Int) -> Bool {
        d.from < to && d.to > from || (d.kind == .widget && d.from >= from && d.from <= to)
    }

    /// All decorations overlapping `[from, to)` (or all when omitted).
    ///
    /// Bounded by binary search when the set is ordered. This is called once
    /// per frame per plugin while drawing, and a find-all over a long document
    /// puts tens of thousands of decorations in here — walking them all to
    /// find the handful on screen was a measurable part of a scroll frame.
    public func find(_ from: Int? = nil, _ to: Int? = nil) -> [Decoration] {
        guard let from, let to else { return decorations }
        guard let reach else {
            return decorations.filter { Self.overlaps($0, from, to) }
        }
        // Last candidate: decorations are sorted by `from`, so the first one
        // starting past `to` ends it. Past, not at: a widget exactly at `to`
        // still counts.
        var lo = 0, hi = decorations.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if decorations[mid].from <= to { lo = mid + 1 } else { hi = mid }
        }
        let end = lo
        // First candidate: nothing before the first index whose running reach
        // gets to `from` can overlap. Inclusive, again for zero-width widgets.
        var blo = 0, bhi = end
        while blo < bhi {
            let mid = (blo + bhi) / 2
            if reach[mid] < from { blo = mid + 1 } else { bhi = mid }
        }
        return decorations[blo ..< end].filter { Self.overlaps($0, from, to) }
    }

    /// Remap all decorations through a mapping, dropping any that were deleted.
    ///
    /// Pass the document the mapping leads to when there is one. A node
    /// decoration promises to span exactly one node, and mapping its two ends
    /// can't tell that the node was *split* — both ends survive, the span just
    /// now covers two paragraphs — so with the document to hand, a node
    /// decoration that no longer spans one node is dropped, as ProseMirror's
    /// does. Without it, the ends are mapped and the caller is trusted.
    public func map(_ mapping: Mapping, doc: Node? = nil) -> DecorationSet {
        let mapped = decorations.compactMap { d -> Decoration? in
            let from = mapping.map(d.from, 1)
            switch d.kind {
            case .widget:
                let result = mapping.mapResult(d.from, 1)
                return result.deleted ? nil : Decoration(from: result.pos, to: result.pos, kind: .widget, attributes: d.attributes)
            case .inline:
                let to = mapping.map(d.to, -1)
                return to > from ? Decoration(from: from, to: to, kind: .inline, attributes: d.attributes) : nil
            case .node:
                // A node decoration survives only while its node does: drop it
                // when either boundary was deleted or the span collapsed.
                let fromResult = mapping.mapResult(d.from, 1)
                let toResult = mapping.mapResult(d.to, -1)
                if fromResult.deleted || toResult.deleted || toResult.pos <= fromResult.pos { return nil }
                if let doc {
                    guard fromResult.pos <= doc.content.size,
                          let node = doc.resolve(fromResult.pos).nodeAfter,
                          fromResult.pos + node.nodeSize == toResult.pos else { return nil }
                }
                return Decoration(from: fromResult.pos, to: toResult.pos, kind: .node, attributes: d.attributes)
            }
        }
        return DecorationSet(mapped)
    }

    public func adding(_ more: [Decoration]) -> DecorationSet { DecorationSet(decorations + more) }

    /// Remove decorations whose `class` attribute matches.
    public func removingClass(_ klass: String) -> DecorationSet {
        DecorationSet(decorations.filter { $0.attributes["class"] != klass })
    }
}
