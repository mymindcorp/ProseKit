import Foundation

/// You can resolve a position to get more information about it. Objects of this
/// class represent such a resolved position, providing various pieces of
/// context information, and some helper methods.
public struct ResolvedPos: Sendable {
    /// The position that was resolved.
    public let pos: Int
    /// The offset this position has into its parent node.
    public let parentOffset: Int

    /// Each entry describes an ancestor: the node, the index of the child that
    /// the position descends into, and the absolute position just before that
    /// child.
    struct PathEntry: Sendable {
        var node: Node
        var index: Int
        var pos: Int
    }
    let path: [PathEntry]

    init(pos: Int, path: [PathEntry], parentOffset: Int) {
        self.pos = pos
        self.path = path
        self.parentOffset = parentOffset
    }

    /// The number of levels the parent node is from the root. If this position
    /// points directly into the root node, it is 0. If it points into a
    /// top-level paragraph, 1, and so on.
    public var depth: Int { path.count - 1 }

    /// The parent node that the position points into.
    public var parent: Node { node(depth) }

    /// The root node in which the position was resolved.
    public var doc: Node { node(0) }

    /// The ancestor node at the given level.
    public func node(_ depth: Int) -> Node {
        path[resolveDepth(depth)].node
    }

    /// The index into the ancestor at the given level.
    public func index(_ depth: Int? = nil) -> Int {
        path[resolveDepth(depth)].index
    }

    /// The index pointing after this position into the ancestor at the given
    /// level.
    public func indexAfter(_ depth: Int? = nil) -> Int {
        let d = resolveDepth(depth)
        return index(d) + ((d == self.depth && textOffset == 0) ? 0 : 1)
    }

    /// The (absolute) position at the start of the node at the given level.
    public func start(_ depth: Int? = nil) -> Int {
        let d = resolveDepth(depth)
        return d == 0 ? 0 : path[d - 1].pos + 1
    }

    /// The (absolute) position at the end of the node at the given level.
    public func end(_ depth: Int? = nil) -> Int {
        let d = resolveDepth(depth)
        return start(d) + node(d).content.size
    }

    /// The (absolute) position directly before the node at the given level, or,
    /// when `depth` is `self.depth + 1`, the original position.
    public func before(_ depth: Int? = nil) -> Int {
        let d = resolveDepth(depth)
        precondition(d > 0, "There is no position before the top-level node")
        return d == self.depth + 1 ? pos : path[d - 1].pos
    }

    /// The (absolute) position directly after the node at the given level.
    public func after(_ depth: Int? = nil) -> Int {
        let d = resolveDepth(depth)
        precondition(d > 0, "There is no position after the top-level node")
        return d == self.depth + 1 ? pos : path[d - 1].pos + node(d).nodeSize
    }

    /// When this position points into a text node, this returns the distance
    /// between the position and the start of the text node. Will be zero for
    /// positions that point between nodes.
    public var textOffset: Int { pos - path[path.count - 1].pos }

    /// Get the node directly after the position, if any.
    public var nodeAfter: Node? {
        let parent = self.parent
        let index = self.index(depth)
        if index == parent.childCount { return nil }
        let dOff = pos - path[path.count - 1].pos
        let child = parent.child(index)
        return dOff != 0 ? parent.child(index).cut(dOff) : child
    }

    /// Get the node directly before the position, if any.
    public var nodeBefore: Node? {
        let index = self.index(depth)
        let dOff = pos - path[path.count - 1].pos
        if dOff != 0 { return parent.child(index).cut(0, dOff) }
        return index == 0 ? nil : parent.child(index - 1)
    }

    /// Get the marks at this position, factoring in the surrounding marks'
    /// inclusiveness.
    public func marks() -> [Mark] {
        let parent = self.parent
        let index = self.index()

        if parent.content.size == 0 { return Mark.none }
        if textOffset != 0 { return parent.child(index).marks }

        var main = parent.maybeChild(index - 1)
        var other = parent.maybeChild(index)
        if main == nil { swap(&main, &other) }

        guard let mainNode = main else { return Mark.none }
        var marks = mainNode.marks
        var i = 0
        while i < marks.count {
            let mark = marks[i]
            if mark.type.spec.inclusive == false && (other == nil || !mark.isInSet(other!.marks)) {
                marks = mark.removeFromSet(marks)
                // do not advance i since array shrank
            } else {
                i += 1
            }
        }
        return marks
    }

    /// The depth up to which this position and the given (non-resolved)
    /// position share the same parent nodes.
    public func sharedDepth(_ pos: Int) -> Int {
        var depth = self.depth
        while depth > 0 {
            if start(depth) <= pos && end(depth) >= pos { return depth }
            depth -= 1
        }
        return 0
    }

    /// Returns a range based on the place where this position and the given
    /// position diverge around block content.
    public func blockRange(_ other: ResolvedPos? = nil, pred: ((Node) -> Bool)? = nil) -> NodeRange? {
        let other = other ?? self
        if other.pos < pos {
            return other.blockRange(self, pred: pred)
        }
        var d = depth - (parent.inlineContent || pos == other.pos ? 1 : 0)
        while d >= 0 {
            if other.pos <= end(d) && (pred == nil || pred!(node(d))) {
                return NodeRange(self, other, d)
            }
            d -= 1
        }
        return nil
    }

    /// Query whether the given position shares the same parent node.
    public func sameParent(_ other: ResolvedPos) -> Bool {
        pos - parentOffset == other.pos - other.parentOffset
    }

    /// Return the greater of this and the given position.
    public func max(_ other: ResolvedPos) -> ResolvedPos { other.pos > pos ? other : self }
    /// Return the smaller of this and the given position.
    public func min(_ other: ResolvedPos) -> ResolvedPos { other.pos < pos ? other : self }

    private func resolveDepth(_ val: Int?) -> Int {
        guard let val else { return depth }
        return val < 0 ? depth + val : val
    }

    // MARK: - Resolution

    static func resolve(_ doc: Node, _ pos: Int) -> ResolvedPos {
        precondition(pos >= 0 && pos <= doc.content.size, "Position \(pos) out of range")
        var path: [PathEntry] = []
        var start = 0
        var parentOffset = pos
        var node = doc
        while true {
            let (index, offset) = node.content.findIndex(parentOffset)
            let rem = parentOffset - offset
            path.append(PathEntry(node: node, index: index, pos: start + offset))
            if rem == 0 { break }
            node = node.child(index)
            if node.isText { break }
            parentOffset = rem - 1
            start += offset + 1
        }
        return ResolvedPos(pos: pos, path: path, parentOffset: parentOffset)
    }

    static func resolveCached(_ doc: Node, _ pos: Int) -> ResolvedPos {
        resolve(doc, pos)
    }
}

/// Represents a flat range of content, i.e. one that starts and ends in the
/// same node.
public struct NodeRange {
    /// A resolved position along the start of the content.
    public let from: ResolvedPos
    /// A position along the end of the content.
    public let to: ResolvedPos
    /// The depth of the node that this range points into.
    public let depth: Int

    public init(_ from: ResolvedPos, _ to: ResolvedPos, _ depth: Int) {
        self.from = from
        self.to = to
        self.depth = depth
    }

    /// The position at the start of the range.
    public var start: Int { from.before(depth + 1) }
    /// The position at the end of the range.
    public var end: Int { to.after(depth + 1) }
    /// The parent node that the range points into.
    public var parent: Node { from.node(depth) }
    /// The start index of the range in the parent node.
    public var startIndex: Int { from.index(depth) }
    /// The end index of the range in the parent node.
    public var endIndex: Int { to.indexAfter(depth) }
}
