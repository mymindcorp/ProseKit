import DocumentModel
import DocumentTransform

/// A visual decoration over a document range that does not change the document
/// itself — used for search highlights, spell-check underlines, collaboration
/// cursors, and similar overlays. (The deferred M2/M7 decoration layer.)
public struct Decoration: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Styles the inline content in `[from, to)`.
        case inline
        /// A zero-width marker at `from` (e.g. a remote collaborator's caret).
        case widget
    }

    public var from: Int
    public var to: Int
    public var kind: Kind
    /// Style hints the renderer understands: `background`, `underline`,
    /// `color` (hex), and `class` (an identifying tag, e.g. "search").
    public var attributes: [String: String]

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
}

/// An immutable collection of decorations that can be mapped forward through
/// document changes. (A simple flat implementation, not ProseMirror's optimized
/// tree — fine for the document sizes this editor targets.)
public struct DecorationSet: Sendable, Equatable {
    public private(set) var decorations: [Decoration]

    public init(_ decorations: [Decoration] = []) {
        self.decorations = decorations
    }

    public static let empty = DecorationSet()

    /// All decorations overlapping `[from, to)` (or all when omitted).
    public func find(_ from: Int? = nil, _ to: Int? = nil) -> [Decoration] {
        guard let from, let to else { return decorations }
        return decorations.filter { $0.from < to && $0.to > from || ($0.kind == .widget && $0.from >= from && $0.from <= to) }
    }

    /// Remap all decorations through a mapping, dropping any that were deleted.
    public func map(_ mapping: Mapping) -> DecorationSet {
        let mapped = decorations.compactMap { d -> Decoration? in
            let from = mapping.map(d.from, 1)
            switch d.kind {
            case .widget:
                let result = mapping.mapResult(d.from, 1)
                return result.deleted ? nil : Decoration(from: result.pos, to: result.pos, kind: .widget, attributes: d.attributes)
            case .inline:
                let to = mapping.map(d.to, -1)
                return to > from ? Decoration(from: from, to: to, kind: .inline, attributes: d.attributes) : nil
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
