import Foundation

/// A node in the document tree.
///
/// Nodes are persistent data structures. Instead of changing them, you create
/// new ones with the content you want. Old ones keep pointing at the old
/// document shape. This is made cheaper by sharing structure between the old
/// and new data as much as possible, which a tree shape like this (without back
/// pointers) makes easy.
public struct Node: Hashable, Sendable {
    /// What a node holds, behind one reference.
    ///
    /// A node's five reference-counted fields were stored inline, so copying a
    /// node meant five retains. An edit copies every sibling along its path
    /// into a new array and later frees the old one, and that traffic was most
    /// of what a keystroke cost in a document of many blocks. Behind one
    /// reference a copy is a single retain — and a node is what upstream's is,
    /// an object that can be compared by identity.
    private final class Storage: Sendable {
        let type: NodeType
        let attrs: Attrs
        let content: Fragment
        let marks: [Mark]
        let text: String?
        /// `nodeSize`, measured once here. It is read for every sibling on
        /// every walk of a fragment — `findIndex`, `cut`, `replace`, resolving
        /// a position. For a text node it is the character count, which
        /// JavaScript strings know but `String.count` has to walk the grapheme
        /// clusters for; for the rest, the leaf test reads a class `var`, whose
        /// exclusivity check and retain were most of what resolving a position
        /// cost.
        let size: Int

        init(type: NodeType, attrs: Attrs, content: Fragment, marks: [Mark], text: String?, size: Int) {
            self.type = type
            self.attrs = attrs
            self.content = content
            self.marks = marks
            self.text = text
            self.size = size
        }
    }

    private let storage: Storage

    /// The type of node that this is.
    public var type: NodeType { storage.type }
    /// An object mapping attribute names to values.
    public var attrs: Attrs { storage.attrs }
    /// A fragment holding the node's children.
    public var content: Fragment { storage.content }
    /// The marks (things like whether it is emphasized or part of a link)
    /// applied to this node.
    public var marks: [Mark] { storage.marks }
    /// For text nodes, this contains the node's text content.
    public var text: String? { storage.text }

    /// `textCount` is the text's length in characters, for a caller that
    /// already knows it — every position in the document rests on it being
    /// right, so debug builds, and so the fuzzers, recount it.
    init(type: NodeType, attrs: Attrs, content: Fragment = .empty, marks: [Mark] = [], text: String? = nil,
         textCount: Int? = nil) {
        assert(textCount == nil || textCount == text?.count, "Wrong character count for \(text ?? "nil")")
        let size = type.isText ? (textCount ?? text?.count ?? 0) : type.isLeaf ? 1 : 2 + content.size
        storage = Storage(type: type, attrs: attrs, content: content, marks: marks, text: text, size: size)
    }

    public static func == (lhs: Node, rhs: Node) -> Bool {
        lhs.storage === rhs.storage || (lhs.type === rhs.type &&
            lhs.text == rhs.text &&
            lhs.attrs == rhs.attrs &&
            lhs.marks == rhs.marks &&
            lhs.content == rhs.content)
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
    public var nodeSize: Int { storage.size }

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

    /// The text of this node and its descendants, concatenated with no
    /// separator between blocks. A leaf contributes its `leafText`, if its
    /// spec defines one.
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

    /// Call `f` for every descendant of this node that isn't also in `old` —
    /// prosemirror-tables' `changedDescendants`. A child found unchanged among
    /// the next few children of `old` is skipped with its whole subtree; a
    /// changed child is visited, then compared with its counterpart in `old`
    /// one level down. Returning false from `f` skips a node's children, as in
    /// `descendants`.
    ///
    /// An edit leaves every sibling it didn't touch sharing storage with the
    /// document it was made from, so after a keystroke this visits one path
    /// from the root instead of the whole tree.
    public func changedDescendants(since old: Node, _ f: (_ node: Node, _ pos: Int) -> Bool) {
        Node.changedDescendants(old, self, 0, f)
    }

    private static func changedDescendants(_ old: Node, _ cur: Node, _ offset: Int,
                                           _ f: (_ node: Node, _ pos: Int) -> Bool) {
        let oldSize = old.childCount
        var offset = offset
        var j = 0
        outer: for i in 0..<cur.childCount {
            let child = cur.child(i)
            for scan in j..<max(j, min(oldSize, i + 3)) where old.child(scan).sameStorage(as: child) {
                j = scan + 1
                offset += child.nodeSize
                continue outer
            }
            if f(child, offset) {
                if j < oldSize, old.child(j).sameMarkup(child) {
                    changedDescendants(old.child(j), child, offset + 1, f)
                } else {
                    child.nodesBetween(0, child.content.size, { node, pos, _, _ in f(node, pos) },
                                       startPos: offset + 1)
                }
            }
            offset += child.nodeSize
        }
    }

    // MARK: - Slicing

    /// Cut out the part of the document between the given positions, and return
    /// it as a `Node`. For text nodes, this slices the text content.
    public func cut(_ from: Int, _ to: Int? = nil) -> Node {
        if isText { return cutText(from, to ?? nodeSize) }
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
        // A position outside the node has no node at it, which is what the
        // optional already says. Without this the descent walks into
        // `Fragment.findIndex`, whose precondition takes the process down —
        // and a step's position can come from a stale history entry or a
        // collab peer, where `apply` is written to fail rather than crash.
        // ProseMirror throws here; a throw is catchable, a precondition is not.
        guard pos >= 0, pos <= content.size else { return nil }
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
    /// given content — or this node itself, when no content is given.
    public func copy(content: Fragment? = nil) -> Node {
        guard let content else { return self }
        // Storage identity, not structural equality. Upstream's `content ==
        // this.content` is a JavaScript reference check, and this is the only
        // thing it can tell us: whether the caller handed back the fragment we
        // already had. Asking whether the two are structurally equal instead
        // walks every child, and this runs once per level of every replace —
        // marking up a document then costs a comparison of the whole document
        // per step. When storage differs we simply build the node; the result
        // is the same value either way, so nothing but the work changes.
        if content.sharesStorage(with: self.content) { return self }
        return Node(type: type, attrs: attrs, content: content, marks: marks, text: text)
    }

    /// Whether this node is the one `other` was made from — same markup, and
    /// content sharing storage. The cheap stand-in for the reference check
    /// upstream uses to skip rebuilding a node that hasn't changed.
    func sameStorage(as other: Node) -> Bool {
        storage === other.storage || (type === other.type && text == other.text && marks == other.marks
            && attrs == other.attrs && content.sharesStorage(with: other.content))
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
        precondition(!text.isEmpty, "Empty text nodes are not allowed")
        return Node(type: type, attrs: attrs, content: content, marks: marks, text: text)
    }

    /// The string indices of characters `lo..<hi` of this text node.
    ///
    /// Offsets are in characters, and a `String` finds a character offset by
    /// walking grapheme clusters from one end. A string with one byte per
    /// character doesn't need the walk; any other walks from the nearer end.
    func textRange(_ lo: Int, _ hi: Int) -> Range<String.Index> {
        let s = text ?? ""
        let utf8 = s.utf8
        if utf8.count == nodeSize {
            let start = utf8.index(utf8.startIndex, offsetBy: lo)
            return start..<utf8.index(start, offsetBy: hi - lo)
        }
        if lo > nodeSize / 2 {
            let end = s.index(s.endIndex, offsetBy: hi - nodeSize)
            return s.index(end, offsetBy: lo - hi)..<end
        }
        let start = s.index(s.startIndex, offsetBy: lo)
        return start..<s.index(start, offsetBy: hi - lo)
    }

    /// For text nodes: the characters `lo..<hi` as a node of their own. Cutting
    /// at character boundaries keeps the characters either side of the cut, so
    /// the length is known and needs no count.
    func cutText(_ lo: Int, _ hi: Int) -> Node {
        if lo == 0 && hi == nodeSize { return self }
        precondition(hi > lo, "Empty text nodes are not allowed")
        return Node(type: type, attrs: attrs, content: content, marks: marks,
                    text: String((text ?? "")[textRange(lo, hi)]), textCount: hi - lo)
    }

    /// For text nodes: this node with `other`'s text added to its end. Lengths
    /// are not additive — a combining mark or regional indicator can join the
    /// character before it — but a join can only reach this node's last
    /// character, so that is all that needs counting again.
    func appendingText(_ other: Node) -> Node {
        let a = text ?? "", b = other.text ?? ""
        let count: Int
        if let last = a.utf8.last, let first = b.utf8.first, last < 0x80, first < 0x80, last != 0x0D {
            // ASCII either side, and not a CR that a LF would join, can't join.
            count = nodeSize + other.nodeSize
        } else if let last = a.last {
            count = nodeSize - 1 + (String(last) + b).count
        } else {
            count = other.nodeSize
        }
        return Node(type: type, attrs: attrs, content: content, marks: marks, text: a + b, textCount: count)
    }

    /// Create a copy of this node with the given marks in place of its own.
    /// The same as `mark(_:)`.
    public func withMarks(_ marks: [Mark]) -> Node { mark(marks) }

    /// Test whether two nodes represent the same piece of document.
    public func eq(_ other: Node) -> Bool { self == other }

    /// Compare the markup (type, attributes, and marks) of this node to those
    /// of another.
    public func sameMarkup(_ other: Node) -> Bool {
        hasMarkup(other.type, other.attrs, other.marks)
    }

    /// Check whether this node's markup corresponds to the given type, attributes,
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

    /// Test whether replacing the children between indices `from` and `to` with
    /// `replacement` (optionally only its children from `start` to `end`) would
    /// leave this node's content valid, marks included.
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
            // `Schema.text` traps on this; JSON is untrusted, so it fails.
            if text.isEmpty {
                throw ModelError.invalidJSON("Empty text node in JSON")
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
