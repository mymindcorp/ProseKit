import Foundation

/// This class represents a node in the document tree.
///
/// Nodes are persistent data structures. Instead of changing them, you create
/// new ones with the content you want. Old ones keep pointing at the old
/// document shape. This is made cheaper by sharing structure between the old
/// and new data as much as possible, which a tree shape like this (without back
/// pointers) makes easy.
public struct Node: Hashable, Sendable {
    /// The type of node that this is.
    public let type: NodeType
    /// An object mapping attribute names to values.
    public let attrs: Attrs
    /// A fragment holding the node's children.
    public let content: Fragment
    /// The marks (things like whether it is emphasized or part of a link)
    /// applied to this node.
    public let marks: [Mark]
    /// For text nodes, this contains the node's text content.
    public let text: String?

    init(type: NodeType, attrs: Attrs, content: Fragment = .empty, marks: [Mark] = [], text: String? = nil) {
        self.type = type
        self.attrs = attrs
        self.content = content
        self.marks = marks
        self.text = text
    }

    public static func == (lhs: Node, rhs: Node) -> Bool {
        lhs.type === rhs.type &&
            lhs.text == rhs.text &&
            lhs.attrs == rhs.attrs &&
            lhs.marks == rhs.marks &&
            lhs.content == rhs.content
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(type))
        hasher.combine(text)
        hasher.combine(attrs)
        hasher.combine(marks)
        hasher.combine(content)
    }

    // MARK: - Size

    /// The size of this node, as defined by the integer-based indexing scheme.
    /// For text nodes, this is the amount of characters. For other leaf nodes,
    /// it is one. For non-leaf nodes, it is the size of the content plus two
    /// (the start and end token).
    public var nodeSize: Int {
        if isText { return text!.count }
        if isLeaf { return 1 }
        return 2 + content.size
    }

    /// The number of children this node has.
    public var childCount: Int { content.childCount }

    /// Get the child node at the given index.
    public func child(_ index: Int) -> Node { content.child(index) }
    public func maybeChild(_ index: Int) -> Node? { content.maybeChild(index) }

    public var firstChild: Node? { content.firstChild }
    public var lastChild: Node? { content.lastChild }

    // MARK: - Type predicates

    public var isBlock: Bool { type.isBlock }
    public var isInline: Bool { type.isInline }
    public var isText: Bool { type.isText }
    public var isLeaf: Bool { type.isLeaf }
    public var isAtom: Bool { type.isAtom }
    public var isTextblock: Bool { type.isTextblock }
    public var inlineContent: Bool { type.inlineContent }

    /// The string representation of this node's content type description.
    public var textContent: String {
        if let text { return text }
        return (isLeaf && type.spec.leafText != nil) ? type.spec.leafText!(self)
            : textBetween(0, content.size, blockSeparator: "")
    }

    public func textBetween(_ from: Int, _ to: Int, blockSeparator: String? = nil, leafText: String? = nil) -> String {
        content.textBetween(from, to, blockSeparator: blockSeparator, leafText: leafText)
    }

    // MARK: - Traversal

    public func nodesBetween(_ from: Int, _ to: Int, _ f: (_ node: Node, _ pos: Int, _ parent: Node?, _ index: Int) -> Bool, startPos: Int = 0) -> Void {
        content.nodesBetween(from, to, f, nodeStart: startPos, parent: self)
    }

    public func descendants(_ f: (_ node: Node, _ pos: Int, _ parent: Node?, _ index: Int) -> Bool) {
        nodesBetween(0, content.size, f)
    }

    // MARK: - Slicing

    /// Cut out the part of the document between the given positions, and return
    /// it as a `Node`. For text nodes, this slices the text content.
    public func cut(_ from: Int, _ to: Int? = nil) -> Node {
        if isText {
            let s = text ?? ""
            let count = s.count
            let to = to ?? count
            if from == 0 && to == count { return self }
            let start = s.index(s.startIndex, offsetBy: from)
            let end = s.index(start, offsetBy: to - from)
            return withText(String(s[start..<end]))
        }
        let to = to ?? content.size
        if from == 0 && to == content.size { return self }
        return copy(content: content.cut(from, to))
    }

    /// Cut out the part of the document between the given positions, and return
    /// it as a `Slice` object.
    public func slice(_ from: Int, _ to: Int? = nil, includeParents: Bool = false) -> Slice {
        let to = to ?? content.size
        if from == to { return Slice.empty }

        let resolvedFrom = resolve(from)
        let resolvedTo = resolve(to)
        let depth = includeParents ? 0 : resolvedFrom.sharedDepth(to)
        let start = resolvedFrom.start(depth)
        let node = resolvedFrom.node(depth)
        let content = node.content.cut(resolvedFrom.pos - start, resolvedTo.pos - start)
        return Slice(content: content, openStart: resolvedFrom.depth - depth, openEnd: resolvedTo.depth - depth)
    }

    /// Replace the part of the document between the given positions with the
    /// given slice.
    public func replace(_ from: Int, _ to: Int, _ slice: Slice) throws(ModelError) -> Node {
        try ReplaceAlgorithm.replace(resolve(from), resolve(to), slice)
    }

    /// Find the node directly after the given position.
    public func nodeAt(_ pos: Int) -> Node? {
        var node = self
        var pos = pos
        while true {
            let (index, offset) = node.content.findIndex(pos)
            guard let child = node.maybeChild(index) else { return nil }
            if offset == pos || child.isText { return child }
            pos -= offset + 1
            node = child
        }
    }

    /// Find the (direct) child node after the given offset, if any, and return
    /// it along with its index and offset relative to this node.
    public func childAfter(_ pos: Int) -> (node: Node?, index: Int, offset: Int) {
        let (index, offset) = content.findIndex(pos)
        return (content.maybeChild(index), index, offset)
    }

    public func childBefore(_ pos: Int) -> (node: Node?, index: Int, offset: Int) {
        if pos == 0 { return (nil, 0, 0) }
        let (index, offset) = content.findIndex(pos)
        if offset < pos { return (content.child(index), index, offset) }
        let node = content.child(index - 1)
        return (node, index - 1, offset - node.nodeSize)
    }

    // MARK: - Positions

    /// Resolve the given position in the document, returning a `ResolvedPos`.
    public func resolve(_ pos: Int) -> ResolvedPos {
        ResolvedPos.resolveCached(self, pos)
    }

    // MARK: - Marks

    /// Test whether a mark of the given type occurs in this document between the
    /// two positions.
    public func rangeHasMark(_ from: Int, _ to: Int, _ type: MarkType) -> Bool {
        var found = false
        if to > from {
            nodesBetween(from, to, { node, _, _, _ in
                if type.isInSet(node.marks) != nil { found = true }
                return !found
            })
        }
        return found
    }

    // MARK: - Markup / copying

    /// Create a new node with the same markup as this node, containing the
    /// given content (or empty, if no content is given).
    public func copy(content: Fragment? = nil) -> Node {
        let content = content ?? self.content
        if content == self.content { return self }
        return Node(type: type, attrs: attrs, content: content, marks: marks, text: text)
    }

    /// Create a copy of this node, with the given set of marks instead of the
    /// node's own marks.
    public func mark(_ marks: [Mark]) -> Node {
        if marks == self.marks { return self }
        return Node(type: type, attrs: attrs, content: content, marks: marks, text: text)
    }

    /// For text nodes: create a copy with the given text.
    public func withText(_ text: String) -> Node {
        if text == self.text { return self }
        precondition(isText, "withText called on non-text node")
        return Node(type: type, attrs: attrs, content: content, marks: marks, text: text)
    }

    /// Create a copy of this node with only the part of its content between the
    /// given positions. (For text nodes, slices the text.)
    public func withMarks(_ marks: [Mark]) -> Node { mark(marks) }

    /// Test whether two nodes represent the same piece of document.
    public func eq(_ other: Node) -> Bool { self == other }

    /// Compare the markup (type, attributes, and marks) of this node to those
    /// of another.
    public func sameMarkup(_ other: Node) -> Bool {
        hasMarkup(other.type, other.attrs, other.marks)
    }

    /// Check whether this node's markup correspond to the given type, attributes,
    /// and marks.
    public func hasMarkup(_ type: NodeType, _ attrs: Attrs? = nil, _ marks: [Mark] = []) -> Bool {
        self.type === type &&
            self.attrs == (attrs ?? type.defaultAttrs) &&
            Mark.sameSet(self.marks, marks)
    }

    // MARK: - Validation

    /// Check whether this node and its descendants conform to the schema.
    public func check() throws(ModelError) {
        try type.checkContent(content)
        try type.checkAttrs(attrs)
        // Rebuild the mark set through addToSet and compare: this catches invalid
        // collections (e.g. duplicate or excluded marks) the same way ProseMirror does.
        var copy: [Mark] = []
        for mark in marks {
            try mark.type.checkAttrs(mark.attrs)
            copy = mark.addToSet(copy)
        }
        if !Mark.sameSet(copy, marks) {
            throw ModelError.invalidContent("Invalid collection of marks for node \(type.name): \(marks.map { $0.type.name })")
        }
        for i in 0..<content.childCount {
            try content.child(i).check()
        }
    }

    /// Check whether the given content can be appended at the given position.
    public func canReplace(_ from: Int, _ to: Int, replacement: Fragment = .empty, start: Int = 0, end: Int? = nil) -> Bool {
        let end = end ?? replacement.childCount
        let one = contentMatchAt(from).matchFragment(replacement, start: start, end: end)
        guard let two = one?.matchFragment(content, start: to) else { return false }
        if !two.validEnd { return false }
        for i in start..<end {
            if !type.allowsMarks(replacement.child(i).marks) { return false }
        }
        return true
    }

    public func contentMatchAt(_ index: Int) -> ContentMatch {
        guard let match = type.contentMatch.matchFragment(content, start: 0, end: index) else {
            return type.contentMatch // fallback; shouldn't happen for valid docs
        }
        return match
    }

    /// Test whether the given node's content could be appended to this node.
    public func canAppend(_ other: Node) -> Bool {
        if other.content.size != 0 {
            return canReplace(childCount, childCount, replacement: other.content)
        }
        return type.compatibleContent(other.type)
    }

    public func canReplaceWith(_ from: Int, _ to: Int, _ type: NodeType, _ marks: [Mark]? = nil) -> Bool {
        if let marks, !self.type.allowsMarks(marks) { return false }
        guard let start = contentMatchAt(from).matchType(type) else { return false }
        guard let next = start.matchFragment(content, start: to) else { return false }
        return next.validEnd
    }

    // MARK: - JSON

    public func toJSON() -> [String: AttributeValue] {
        var obj: [String: AttributeValue] = ["type": .string(type.name)]
        if !attrs.isEmpty { obj["attrs"] = .object(attrs) }
        if content.size > 0 { obj["content"] = .array(content.toJSON()) }
        if !marks.isEmpty { obj["marks"] = .array(marks.map { .object($0.toJSON()) }) }
        if let text { obj["text"] = .string(text) }
        return obj
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> Node {
        guard let typeName = json["type"]?.stringValue else {
            throw ModelError.invalidJSON("Invalid node JSON: missing type")
        }
        var marks: [Mark] = []
        if case let .array(markArr)? = json["marks"] {
            marks = try markArr.map { (v) throws(ModelError) -> Mark in
                guard case let .object(o) = v else { throw ModelError.invalidJSON("Invalid mark JSON") }
                return try Mark.fromJSON(schema, o)
            }
        }
        if typeName == "text" {
            guard let text = json["text"]?.stringValue else {
                throw ModelError.invalidJSON("Invalid text node in JSON")
            }
            return schema.text(text, marks)
        }
        var content: [AttributeValue] = []
        if case let .array(c)? = json["content"] { content = c }
        var attrs: Attrs = [:]
        if case let .object(a)? = json["attrs"] { attrs = a }
        return try schema.nodeType(typeName).create(attrs, content: Fragment.fromJSON(schema, content), marks: marks)
    }
}
