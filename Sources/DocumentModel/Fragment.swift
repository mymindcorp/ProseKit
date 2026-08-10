import Foundation

/// A fragment represents a node's collection of child nodes.
///
/// Like nodes, fragments are persistent data structures, and you should not
/// mutate them or their content. Rather, you create new instances whenever
/// needed. The API tries to make this easy.
public struct Fragment: Hashable, Sendable {
    /// The child nodes in this fragment.
    public let content: [Node]
    /// The total size of the content in this fragment (the sum of node sizes).
    public let size: Int

    init(_ content: [Node], size: Int? = nil) {
        self.content = content
        if let size {
            self.size = size
        } else {
            self.size = content.reduce(0) { $0 + $1.nodeSize }
        }
    }

    public static func == (lhs: Fragment, rhs: Fragment) -> Bool {
        if lhs.size != rhs.size || lhs.content.count != rhs.content.count { return false }
        // COW fast path: when both fragments share the same backing storage
        // (e.g. an unchanged sibling copied during an edit), they're equal in
        // O(1) — which lets renderers diff documents without walking every node.
        let shared = unsafe lhs.content.withUnsafeBufferPointer { a in
            unsafe rhs.content.withUnsafeBufferPointer { b in unsafe a.baseAddress != nil && a.baseAddress == b.baseAddress }
        }
        if shared { return true }
        return lhs.content == rhs.content
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(content)
    }

    /// The empty fragment.
    public static let empty = Fragment([], size: 0)

    /// The number of child nodes in this fragment.
    public var childCount: Int { content.count }

    /// Get the child node at the given index. Raises a fatal error when the
    /// index is out of range.
    public func child(_ index: Int) -> Node {
        precondition(index >= 0 && index < content.count, "Index \(index) out of range for fragment")
        return content[index]
    }

    /// Get the child node at the given index, if it exists.
    public func maybeChild(_ index: Int) -> Node? {
        guard index >= 0 && index < content.count else { return nil }
        return content[index]
    }

    public var firstChild: Node? { content.first }
    public var lastChild: Node? { content.last }

    /// Invoke a callback for all descendant nodes between the given two
    /// positions (relative to start of this fragment). Returning `false` from
    /// the callback prevents descending into a node.
    public func nodesBetween(
        _ from: Int,
        _ to: Int,
        _ f: (_ node: Node, _ start: Int, _ parent: Node?, _ index: Int) -> Bool,
        nodeStart: Int = 0,
        parent: Node? = nil
    ) -> Void {
        var pos = 0
        var i = 0
        while pos < to {
            let child = content[i]
            let end = pos + child.nodeSize
            if end > from && f(child, nodeStart + pos, parent, i) && !child.content.content.isEmpty {
                let start = pos + 1
                child.content.nodesBetween(
                    max(0, from - start),
                    min(child.content.size, to - start),
                    f,
                    nodeStart: nodeStart + start,
                    parent: child)
            }
            pos = end
            i += 1
        }
    }

    /// Call the given callback for every descendant node.
    public func descendants(_ f: (_ node: Node, _ pos: Int, _ parent: Node?, _ index: Int) -> Bool) {
        nodesBetween(0, size, f)
    }

    /// Extract the text between `from` and `to`.
    public func textBetween(_ from: Int, _ to: Int, blockSeparator: String? = nil, leafText: String? = nil) -> String {
        var text = ""
        var first = true
        nodesBetween(from, to, { node, pos, _, _ in
            var nodeText = ""
            if node.isText {
                let s = node.text ?? ""
                let count = s.count
                let lo = max(0, max(from, pos) - pos)
                let hi = max(0, min(count, to - pos))
                if lo == 0 && hi >= count {
                    nodeText = s
                } else if lo < hi {
                    let start = s.index(s.startIndex, offsetBy: lo)
                    let end = s.index(start, offsetBy: hi - lo)
                    nodeText = String(s[start..<end])
                }
            } else if node.isLeaf {
                if let leafText {
                    nodeText = leafText
                } else if let lt = node.type.spec.leafText {
                    nodeText = lt(node)
                }
            }
            if node.isLeaf || node.isText {
                if let blockSeparator, !first, node.isBlock { text += blockSeparator }
                text += nodeText
                first = false
            } else if node.isBlock, let blockSeparator {
                if !first { text += blockSeparator }
                first = false
            }
            return true
        })
        return text
    }

    /// Create a new fragment containing the combined content of this fragment
    /// and the other.
    public func append(_ other: Fragment) -> Fragment {
        if other.content.isEmpty { return self }
        if content.isEmpty { return other }
        var merged = content
        var last = merged.removeLast()
        var rest = other.content
        if let first = rest.first, last.isText, first.isText, Mark.sameSet(last.marks, first.marks) {
            last = last.withText((last.text ?? "") + (first.text ?? ""))
            rest.removeFirst()
        }
        merged.append(last)
        merged.append(contentsOf: rest)
        return Fragment(merged, size: size + other.size)
    }

    /// Cut out the sub-fragment between the two given positions.
    public func cut(_ from: Int, _ to: Int? = nil) -> Fragment {
        let to = to ?? size
        if from == 0 && to == size { return self }
        var result: [Node] = []
        var newSize = 0
        if to > from {
            var pos = 0
            var i = 0
            while pos < to {
                let child = content[i]
                let end = pos + child.nodeSize
                if end > from {
                    var c = child
                    if pos < from || end > to {
                        if c.isText {
                            let s = c.text ?? ""
                            let lo = max(0, from - pos)
                            // `child.nodeSize` is the same count, already measured.
                            let hi = min(child.nodeSize, to - pos)
                            let start = s.index(s.startIndex, offsetBy: lo)
                            let end = s.index(start, offsetBy: max(0, hi - lo))
                            c = c.withText(String(s[start..<end]))
                        } else {
                            c = c.cut(max(0, from - pos - 1), min(c.content.size, to - pos - 1))
                        }
                    }
                    result.append(c)
                    newSize += c.nodeSize
                }
                pos = end
                i += 1
            }
        }
        return Fragment(result, size: newSize)
    }

    /// Create a fragment containing only the children between the given
    /// indices.
    public func cutByIndex(_ from: Int, _ to: Int) -> Fragment {
        if from == to { return .empty }
        if from == 0 && to == content.count { return self }
        return Fragment(Array(content[from..<to]))
    }

    /// Create a new fragment in which the node at the given index is replaced
    /// by the given node.
    public func replaceChild(_ index: Int, _ node: Node) -> Fragment {
        let cur = content[index]
        if cur == node { return self }
        var copy = content
        let newSize = size + node.nodeSize - cur.nodeSize
        copy[index] = node
        return Fragment(copy, size: newSize)
    }

    /// Create a new fragment by prepending the given node.
    public func addToStart(_ node: Node) -> Fragment {
        Fragment([node] + content, size: size + node.nodeSize)
    }

    /// Create a new fragment by appending the given node.
    public func addToEnd(_ node: Node) -> Fragment {
        Fragment(content + [node], size: size + node.nodeSize)
    }

    /// Find the first position at which this fragment and the other differ, or
    /// `nil` if they are the same.
    public func findDiffStart(_ other: Fragment, pos: Int = 0) -> Int? {
        var pos = pos
        var i = 0
        while true {
            if i == content.count || i == other.content.count {
                return content.count == other.content.count ? nil : pos
            }
            let a = content[i], b = other.content[i]
            if a == b { pos += a.nodeSize; i += 1; continue }
            if !a.sameMarkup(b) { return pos }
            if a.isText && a.text != b.text {
                let ac = Array(a.text!), bc = Array(b.text!)
                var j = 0
                while j < ac.count && j < bc.count && ac[j] == bc[j] { j += 1 }
                return pos + j
            }
            if a.content.size != 0 || b.content.size != 0 {
                if let inner = a.content.findDiffStart(b.content, pos: pos + 1) {
                    return inner
                }
            }
            pos += a.nodeSize
            i += 1
        }
    }

    /// Find the first position, searching from the end, at which this fragment
    /// and the other differ.
    public func findDiffEnd(_ other: Fragment, pos: Int? = nil, otherPos: Int? = nil) -> (a: Int, b: Int)? {
        var posA = pos ?? size
        var posB = otherPos ?? other.size
        var iA = content.count
        var iB = other.content.count
        while true {
            if iA == 0 || iB == 0 {
                return iA == iB ? nil : (a: posA, b: posB)
            }
            let a = content[iA - 1], b = other.content[iB - 1]
            if a == b { posA -= a.nodeSize; posB -= b.nodeSize; iA -= 1; iB -= 1; continue }
            if !a.sameMarkup(b) { return (a: posA, b: posB) }
            if a.isText && a.text != b.text {
                let ac = Array(a.text!), bc = Array(b.text!)
                var same = 0
                let minLen = min(ac.count, bc.count)
                while same < minLen && ac[ac.count - 1 - same] == bc[bc.count - 1 - same] { same += 1 }
                return (a: posA - same, b: posB - same)
            }
            if a.content.size != 0 || b.content.size != 0 {
                if let inner = a.content.findDiffEnd(b.content, pos: posA - 1, otherPos: posB - 1) {
                    return inner
                }
            }
            posA -= a.nodeSize
            posB -= b.nodeSize
            iA -= 1
            iB -= 1
        }
    }

    /// Find the index and offset corresponding to the given relative position.
    /// When `round` is positive, positions that fall exactly between two nodes
    /// resolve to the later index.
    func findIndex(_ pos: Int, round: Int = -1) -> (index: Int, offset: Int) {
        if pos == 0 { return (0, 0) }
        if pos == size { return (content.count, size) }
        precondition(pos >= 0 && pos <= size, "Position \(pos) outside of fragment (\(size))")
        var curPos = 0
        var i = 0
        while true {
            let cur = content[i]
            let end = curPos + cur.nodeSize
            if end >= pos {
                if end == pos || round > 0 { return (i + 1, end) }
                return (i, curPos)
            }
            curPos = end
            i += 1
        }
    }

    public var isEmpty: Bool { content.isEmpty }

    public func toJSON() -> [AttributeValue] {
        content.map { .object($0.toJSON()) }
    }

    public static func fromJSON(_ schema: Schema, _ value: [AttributeValue]?) throws(ModelError) -> Fragment {
        guard let value, !value.isEmpty else { return .empty }
        let nodes = try value.map { (v) throws(ModelError) -> Node in
            guard case let .object(o) = v else {
                throw ModelError.invalidJSON("Invalid fragment child JSON")
            }
            return try Node.fromJSON(schema, o)
        }
        return Fragment(nodes)
    }

    public static func from(_ nodes: [Node]) -> Fragment {
        if nodes.isEmpty { return .empty }
        // Merge adjacent text nodes that share markup, matching ProseMirror's
        // Fragment.fromArray (keeps documents in canonical, joined form).
        var joined: [Node]?
        for i in nodes.indices {
            let node = nodes[i]
            if i > 0, node.isText, nodes[i - 1].sameMarkup(node) {
                if joined == nil { joined = Array(nodes[0..<i]) }
                let prev = joined![joined!.count - 1]
                joined![joined!.count - 1] = prev.withText((prev.text ?? "") + (node.text ?? ""))
            } else {
                joined?.append(node)
            }
        }
        return Fragment(joined ?? nodes)
    }

    public static func from(_ node: Node) -> Fragment {
        Fragment([node])
    }
}
