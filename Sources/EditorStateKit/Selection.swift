import DocumentModel
import DocumentTransform

/// Represents a selected range in a document.
public struct SelectionRange {
    public let from: ResolvedPos
    public let to: ResolvedPos
    public init(_ from: ResolvedPos, _ to: ResolvedPos) {
        self.from = from
        self.to = to
    }
}

/// Superclass for editor selections. Every selection type should provide an
/// anchor and head, and the abstract methods below.
open class Selection {
    /// The ranges covered by the selection.
    public let ranges: [SelectionRange]
    /// The resolved anchor of the selection (immobile side).
    public let resolvedAnchor: ResolvedPos
    /// The resolved head of the selection (mobile side).
    public let resolvedHead: ResolvedPos

    public init(_ anchor: ResolvedPos, _ head: ResolvedPos, ranges: [SelectionRange]? = nil) {
        self.resolvedAnchor = anchor
        self.resolvedHead = head
        if let ranges {
            self.ranges = ranges
        } else {
            let from = anchor.min(head)
            let to = anchor.max(head)
            self.ranges = [SelectionRange(from, to)]
        }
    }

    /// The selection's anchor, as an unresolved position.
    public var anchor: Int { resolvedAnchor.pos }
    /// The selection's head.
    public var head: Int { resolvedHead.pos }
    /// The lower bound of the selection's main range.
    public var from: Int { ranges[0].from.pos }
    /// The upper bound of the selection's main range.
    public var to: Int { ranges[0].to.pos }
    public var resolvedFrom: ResolvedPos { ranges[0].from }
    public var resolvedTo: ResolvedPos { ranges[0].to }

    /// Whether the selection is empty (a cursor).
    open var empty: Bool {
        ranges.allSatisfy { $0.from.pos == $0.to.pos }
    }

    /// Test whether the selection is the same as another.
    open func eq(_ other: Selection) -> Bool {
        fatalError("must override")
    }

    /// Map this selection through a set of mappings, onto a new document.
    open func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        fatalError("must override")
    }

    /// Get the content of this selection as a slice.
    open func content() -> Slice {
        resolvedFrom.doc.slice(from, to, includeParents: true)
    }

    /// Replace the selection with a slice (or empty to delete it).
    open func replace(_ tr: Transaction, _ content: Slice = .empty) {
        var mapFrom = tr.steps.count
        for range in ranges {
            let mapping = tr.mapping.slice(mapFrom)
            let from = mapping.map(range.from.pos)
            let to = mapping.map(range.to.pos)
            _ = try? tr.replaceRange(from, to, content)
            mapFrom = tr.steps.count
        }
    }

    /// Replace the selection with the given node.
    open func replaceWith(_ tr: Transaction, _ node: Node) {
        var mapFrom = tr.steps.count
        for range in ranges {
            let mapping = tr.mapping.slice(mapFrom)
            let from = mapping.map(range.from.pos)
            let to = mapping.map(range.to.pos)
            _ = try? tr.replaceRangeWith(from, to, node)
            mapFrom = tr.steps.count
        }
    }

    /// Serialize to JSON.
    open func toJSON() -> [String: AttributeValue] {
        fatalError("must override")
    }

    /// Get a bookmark for this selection (position that survives mapping).
    open func getBookmark() -> SelectionBookmark {
        TextSelection.between(resolvedAnchor, resolvedHead).getBookmark()
    }

    // MARK: - Static helpers

    /// Find a valid cursor or leaf-node selection starting at the given
    /// position and searching in the given direction.
    public static func findFrom(_ pos: ResolvedPos, _ dir: Int, textOnly: Bool = false) -> Selection? {
        let inner = pos.parent.inlineContent
            ? TextSelection(pos) as Selection
            : findSelectionIn(pos.doc, pos.parent, pos.pos, pos.index(), dir, textOnly)
        if inner != nil { return inner }
        var depth = pos.depth - 1
        while depth >= 0 {
            let node = pos.node(depth)
            let found: Selection?
            if dir > 0 {
                found = findSelectionIn(pos.doc, node, pos.after(depth + 1), pos.index(depth) + 1, dir, textOnly)
            } else {
                found = findSelectionIn(pos.doc, node, pos.before(depth + 1), pos.index(depth), dir, textOnly)
            }
            if let found { return found }
            depth -= 1
        }
        return nil
    }

    /// Find a valid selection near the given position.
    public static func near(_ pos: ResolvedPos, _ bias: Int = 1) -> Selection {
        findFrom(pos, bias) ?? findFrom(pos, -bias) ?? AllSelection(pos.doc)
    }

    /// The selection at the start of the document.
    public static func atStart(_ doc: Node) -> Selection {
        findSelectionIn(doc, doc, 0, 0, 1) ?? AllSelection(doc)
    }

    /// The selection at the end of the document.
    public static func atEnd(_ doc: Node) -> Selection {
        findSelectionIn(doc, doc, doc.content.size, doc.childCount, -1) ?? AllSelection(doc)
    }

    public static func fromJSON(_ doc: Node, _ json: [String: AttributeValue]) throws -> Selection {
        guard let type = json["type"]?.stringValue else {
            throw ModelError.invalidJSON("Invalid selection JSON: missing type")
        }
        switch type {
        case "text":
            guard let anchor = json["anchor"]?.intValue, let head = json["head"]?.intValue else {
                throw ModelError.invalidJSON("Invalid text selection JSON")
            }
            return TextSelection(doc.resolve(anchor), doc.resolve(head))
        case "node":
            guard let anchor = json["anchor"]?.intValue else {
                throw ModelError.invalidJSON("Invalid node selection JSON")
            }
            return NodeSelection(doc.resolve(anchor))
        case "all":
            return AllSelection(doc)
        default:
            throw ModelError.invalidJSON("No selection type \(type)")
        }
    }
}

func findSelectionIn(_ doc: Node, _ node: Node, _ pos: Int, _ index: Int, _ dir: Int, _ text: Bool = false) -> Selection? {
    if node.inlineContent { return TextSelection(doc.resolve(pos)) }
    var index = index
    var pos = pos
    while true {
        let nextIndex = dir > 0 ? index : index - 1
        if nextIndex < 0 || nextIndex >= node.childCount { return nil }
        let child = node.child(nextIndex)
        let nextPos = dir > 0 ? pos + 1 : pos - 1
        if child.isAtom {
            if !text && NodeSelection.isSelectable(child) {
                return NodeSelection(doc.resolve(dir > 0 ? pos : pos - child.nodeSize))
            }
        } else if let found = findSelectionIn(doc, child, dir > 0 ? pos + 1 : pos - 1, dir > 0 ? 0 : child.childCount, dir, text) {
            return found
        }
        index += dir
        pos += dir > 0 ? child.nodeSize : -node.child(nextIndex).nodeSize
        _ = nextPos
    }
}

/// A lightweight, position-only representation of a selection that can be
/// mapped through document changes.
public protocol SelectionBookmark {
    func map(_ mapping: Mappable) -> SelectionBookmark
    func resolve(_ doc: Node) -> Selection
}
