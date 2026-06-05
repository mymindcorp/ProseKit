import DocumentModel
import DocumentTransform

/// A text selection represents a classical editor selection, with a head
/// (the moving side) and anchor (immobile side), both of which point into
/// textblock nodes.
public final class TextSelection: Selection {
    public init(_ anchor: ResolvedPos, _ head: ResolvedPos? = nil) {
        super.init(anchor, head ?? anchor)
    }

    /// When the selection is collapsed, the resolved cursor position.
    public var cursor: ResolvedPos? {
        resolvedAnchor.pos == resolvedHead.pos ? resolvedHead : nil
    }

    public override func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        let head = doc.resolve(mapping.map(self.head))
        if !head.parent.inlineContent { return Selection.near(head) }
        let anchor = doc.resolve(mapping.map(self.anchor))
        return TextSelection(anchor.parent.inlineContent ? anchor : head, head)
    }

    public override func eq(_ other: Selection) -> Bool {
        (other as? TextSelection).map { $0.anchor == anchor && $0.head == head } ?? false
    }

    public override func toJSON() -> [String: AttributeValue] {
        ["type": "text", "anchor": .int(anchor), "head": .int(head)]
    }

    public override func getBookmark() -> SelectionBookmark {
        TextBookmark(anchor: anchor, head: head)
    }

    /// Create a text selection from non-resolved positions.
    public static func create(_ doc: Node, _ anchor: Int, _ head: Int? = nil) -> TextSelection {
        let resolvedAnchor = doc.resolve(anchor)
        return TextSelection(resolvedAnchor, doc.resolve(head ?? anchor))
    }

    /// Find a valid text selection between the two given resolved positions.
    public static func between(_ anchor: ResolvedPos, _ head: ResolvedPos, _ bias: Int? = nil) -> Selection {
        var anchor = anchor
        var head = head
        let dPos = anchor.pos - head.pos
        var bias = bias ?? 0
        if bias == 0 || dPos != 0 { bias = dPos >= 0 ? 1 : -1 }
        if !head.parent.inlineContent {
            if let found = Selection.findFrom(head, bias, textOnly: true) ?? Selection.findFrom(head, -bias, textOnly: true) {
                head = found.resolvedHead
            } else {
                return Selection.near(head, bias)
            }
        }
        if !anchor.parent.inlineContent {
            if dPos == 0 {
                anchor = head
            } else if let found = Selection.findFrom(anchor, -bias, textOnly: true) ?? Selection.findFrom(anchor, bias, textOnly: true) {
                anchor = found.resolvedAnchor
                if (anchor.pos < head.pos) != (dPos < 0) { anchor = head }
            } else {
                anchor = head
            }
        }
        return TextSelection(anchor, head)
    }
}

struct TextBookmark: SelectionBookmark {
    let anchor: Int
    let head: Int
    func map(_ mapping: Mappable) -> SelectionBookmark {
        TextBookmark(anchor: mapping.map(anchor), head: mapping.map(head))
    }
    func resolve(_ doc: Node) -> Selection {
        TextSelection.between(doc.resolve(anchor), doc.resolve(head))
    }
}

/// A node selection points at a single node. Its `node` is the selected node.
public final class NodeSelection: Selection {
    public let node: Node

    public init(_ pos: ResolvedPos) {
        let node = pos.nodeAfter!
        let end = pos.node(0).resolve(pos.pos + node.nodeSize)
        self.node = node
        super.init(pos, end)
    }

    public override var empty: Bool { false }

    public override func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        let result = mapping.mapResult(anchor)
        let pos = doc.resolve(result.pos)
        if result.deleted { return Selection.near(pos) }
        if pos.nodeAfter != nil && NodeSelection.isSelectable(pos.nodeAfter!) {
            return NodeSelection(pos)
        }
        return Selection.near(pos)
    }

    public override func content() -> Slice {
        Slice(content: Fragment.from(node), openStart: 0, openEnd: 0)
    }

    public override func eq(_ other: Selection) -> Bool {
        (other as? NodeSelection).map { $0.anchor == anchor } ?? false
    }

    public override func toJSON() -> [String: AttributeValue] {
        ["type": "node", "anchor": .int(anchor)]
    }

    public override func getBookmark() -> SelectionBookmark {
        NodeBookmark(anchor: anchor)
    }

    public static func create(_ doc: Node, _ from: Int) -> NodeSelection {
        NodeSelection(doc.resolve(from))
    }

    /// Whether the given node may be selected as a node selection.
    public static func isSelectable(_ node: Node) -> Bool {
        !node.isText && node.type.spec.selectable
    }
}

struct NodeBookmark: SelectionBookmark {
    let anchor: Int
    func map(_ mapping: Mappable) -> SelectionBookmark {
        let result = mapping.mapResult(anchor)
        return result.deletedAfter ? TextBookmark(anchor: result.pos, head: result.pos) : NodeBookmark(anchor: result.pos)
    }
    func resolve(_ doc: Node) -> Selection {
        let pos = doc.resolve(anchor)
        if let after = pos.nodeAfter, NodeSelection.isSelectable(after) { return NodeSelection(pos) }
        return Selection.near(pos)
    }
}

/// A selection covering the whole document.
public final class AllSelection: Selection {
    public init(_ doc: Node) {
        super.init(doc.resolve(0), doc.resolve(doc.content.size))
    }

    public override func toJSON() -> [String: AttributeValue] { ["type": "all"] }

    public override func map(_ doc: Node, _ mapping: Mappable) -> Selection { AllSelection(doc) }

    public override func eq(_ other: Selection) -> Bool { other is AllSelection }

    public override func content() -> Slice {
        resolvedFrom.doc.slice(0, resolvedFrom.doc.content.size, includeParents: true)
    }

    public override func getBookmark() -> SelectionBookmark { AllBookmark() }
}

struct AllBookmark: SelectionBookmark {
    func map(_ mapping: Mappable) -> SelectionBookmark { self }
    func resolve(_ doc: Node) -> Selection { AllSelection(doc) }
}
