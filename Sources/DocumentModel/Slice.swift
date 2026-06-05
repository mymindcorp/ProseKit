import Foundation

/// A slice represents a piece cut out of a larger document. It stores not only
/// a fragment, but also the depth up to which nodes on both sides are "open"
/// (cut through).
public struct Slice: Hashable, Sendable {
    /// The slice's content.
    public let content: Fragment
    /// The open depth at the start of the fragment.
    public let openStart: Int
    /// The open depth at the end.
    public let openEnd: Int

    public init(content: Fragment, openStart: Int, openEnd: Int) {
        self.content = content
        self.openStart = openStart
        self.openEnd = openEnd
    }

    /// The size this slice would add when inserted into a document.
    public var size: Int { content.size - openStart - openEnd }

    /// The empty slice.
    public static let empty = Slice(content: .empty, openStart: 0, openEnd: 0)

    /// Insert the given fragment at the given (slice-relative) position,
    /// returning a new slice, or `nil` if it doesn't fit.
    public func insertAt(_ pos: Int, _ fragment: Fragment) -> Slice? {
        guard let newContent = Slice.insertInto(content, pos + openStart, fragment) else { return nil }
        return Slice(content: newContent, openStart: openStart, openEnd: openEnd)
    }

    private static func insertInto(_ content: Fragment, _ dist: Int, _ insert: Fragment) -> Fragment? {
        let (index, offset) = content.findIndex(dist)
        let child = content.maybeChild(index)
        if offset == dist || (child?.isText ?? false) {
            return content.cut(0, dist).append(insert).append(content.cut(dist))
        }
        guard let child, let inner = insertInto(child.content, dist - offset - 1, insert) else { return nil }
        return content.replaceChild(index, child.copy(content: inner))
    }

    /// Remove the (slice-relative) range from this slice's content.
    public func removeBetween(_ from: Int, _ to: Int) -> Slice {
        Slice(content: Slice.removeRange(content, from + openStart, to + openStart),
              openStart: openStart, openEnd: openEnd)
    }

    private static func removeRange(_ content: Fragment, _ from: Int, _ to: Int) -> Fragment {
        let (index, offset) = content.findIndex(from)
        let child = content.maybeChild(index)
        let (indexTo, offsetTo) = content.findIndex(to)
        if offset == from || (child?.isText ?? false) {
            precondition(offsetTo == to || content.child(indexTo).isText, "Removing non-flat range")
            return content.cut(0, from).append(content.cut(to))
        }
        precondition(index == indexTo, "Removing non-flat range")
        return content.replaceChild(index, child!.copy(content: removeRange(child!.content, from - offset - 1, to - offset - 1)))
    }

    public func eq(_ other: Slice) -> Bool { self == other }

    public func toJSON() -> [String: AttributeValue]? {
        if content.isEmpty { return nil }
        var json: [String: AttributeValue] = ["content": .array(content.toJSON())]
        if openStart > 0 { json["openStart"] = .int(openStart) }
        if openEnd > 0 { json["openEnd"] = .int(openEnd) }
        return json
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]?) throws -> Slice {
        guard let json else { return .empty }
        var contentArr: [AttributeValue] = []
        if case let .array(c)? = json["content"] { contentArr = c }
        let openStart = json["openStart"]?.intValue ?? 0
        let openEnd = json["openEnd"]?.intValue ?? 0
        return Slice(content: try Fragment.fromJSON(schema, contentArr), openStart: openStart, openEnd: openEnd)
    }

    /// Create a slice with the maximum possible open depth on both sides given
    /// the fragment.
    public static func maxOpen(_ fragment: Fragment, openIsolating: Bool = true) -> Slice {
        var openStart = 0
        var n = fragment.firstChild
        while let node = n, !node.isLeaf, openIsolating || !node.type.spec.isolating {
            openStart += 1
            n = node.firstChild
        }
        var openEnd = 0
        var m = fragment.lastChild
        while let node = m, !node.isLeaf, openIsolating || !node.type.spec.isolating {
            openEnd += 1
            m = node.lastChild
        }
        return Slice(content: fragment, openStart: openStart, openEnd: openEnd)
    }
}

// MARK: - The replace algorithm (prosemirror-model replace.ts)

enum ReplaceAlgorithm {
    static func replace(_ from: ResolvedPos, _ to: ResolvedPos, _ slice: Slice) throws -> Node {
        if slice.openStart > from.depth {
            throw ModelError.invalidContent("Inserted content deeper than insertion position")
        }
        if from.depth - slice.openStart != to.depth - slice.openEnd {
            throw ModelError.invalidContent("Inconsistent open depths")
        }
        return try replaceOuter(from, to, slice, 0)
    }

    private static func replaceOuter(_ from: ResolvedPos, _ to: ResolvedPos, _ slice: Slice, _ depth: Int) throws -> Node {
        let index = from.index(depth)
        let node = from.node(depth)
        if index == to.index(depth) && depth < from.depth - slice.openStart {
            let inner = try replaceOuter(from, to, slice, depth + 1)
            return node.copy(content: node.content.replaceChild(index, inner))
        } else if slice.content.size == 0 {
            return try close(node, replaceTwoWay(from, to, depth))
        } else if slice.openStart == 0 && slice.openEnd == 0 && from.depth == depth && to.depth == depth {
            // Simple, flat case.
            let parent = from.parent
            let content = parent.content
            return try close(parent, content.cut(0, from.parentOffset).append(slice.content).append(content.cut(to.parentOffset)))
        } else {
            let (start, end) = prepareSliceForReplace(slice, from)
            return try close(node, replaceThreeWay(from, start, end, to, depth))
        }
    }

    private static func checkJoin(_ main: Node, _ sub: Node) throws {
        if !sub.type.compatibleContent(main.type) {
            throw ModelError.invalidContent("Cannot join \(sub.type.name) onto \(main.type.name)")
        }
    }

    private static func joinable(_ before: ResolvedPos, _ after: ResolvedPos, _ depth: Int) throws -> Node {
        let node = before.node(depth)
        try checkJoin(node, after.node(depth))
        return node
    }

    private static func addNode(_ child: Node, _ target: inout [Node]) {
        if let last = target.last, child.isText, child.sameMarkup(last) {
            target[target.count - 1] = last.withText((last.text ?? "") + (child.text ?? ""))
        } else {
            target.append(child)
        }
    }

    private static func addRange(_ start: ResolvedPos?, _ end: ResolvedPos?, _ depth: Int, _ target: inout [Node]) {
        let node = (end ?? start!).node(depth)
        var startIndex = 0
        let endIndex = end != nil ? end!.index(depth) : node.childCount
        if let start {
            startIndex = start.index(depth)
            if start.depth > depth {
                startIndex += 1
            } else if start.textOffset != 0 {
                if let na = start.nodeAfter { addNode(na, &target) }
                startIndex += 1
            }
        }
        var i = startIndex
        while i < endIndex {
            addNode(node.child(i), &target)
            i += 1
        }
        if let end, end.depth == depth, end.textOffset != 0, let nb = end.nodeBefore {
            addNode(nb, &target)
        }
    }

    private static func close(_ node: Node, _ content: Fragment) throws -> Node {
        try node.type.checkContent(content)
        return node.copy(content: content)
    }

    private static func replaceThreeWay(_ from: ResolvedPos, _ start: ResolvedPos, _ end: ResolvedPos, _ to: ResolvedPos, _ depth: Int) throws -> Fragment {
        let openStart: Node? = from.depth > depth ? try joinable(from, start, depth + 1) : nil
        let openEnd: Node? = to.depth > depth ? try joinable(end, to, depth + 1) : nil

        var content: [Node] = []
        addRange(nil, from, depth, &content)
        if let os = openStart, let oe = openEnd, start.index(depth) == end.index(depth) {
            try checkJoin(os, oe)
            let inner = try replaceThreeWay(from, start, end, to, depth + 1)
            addNode(try close(os, inner), &content)
        } else {
            if let os = openStart {
                addNode(try close(os, try replaceTwoWay(from, start, depth + 1)), &content)
            }
            addRange(start, end, depth, &content)
            if let oe = openEnd {
                addNode(try close(oe, try replaceTwoWay(end, to, depth + 1)), &content)
            }
        }
        addRange(to, nil, depth, &content)
        return Fragment(content)
    }

    private static func replaceTwoWay(_ from: ResolvedPos, _ to: ResolvedPos, _ depth: Int) throws -> Fragment {
        var content: [Node] = []
        addRange(nil, from, depth, &content)
        if from.depth > depth {
            let type = try joinable(from, to, depth + 1)
            addNode(try close(type, try replaceTwoWay(from, to, depth + 1)), &content)
        }
        addRange(to, nil, depth, &content)
        return Fragment(content)
    }

    private static func prepareSliceForReplace(_ slice: Slice, _ along: ResolvedPos) -> (start: ResolvedPos, end: ResolvedPos) {
        let extra = along.depth - slice.openStart
        let parent = along.node(extra)
        var node = parent.copy(content: slice.content)
        var i = extra - 1
        while i >= 0 {
            node = along.node(i).copy(content: Fragment.from(node))
            i -= 1
        }
        let start = ResolvedPos.resolve(node, slice.openStart + extra)
        let end = ResolvedPos.resolve(node, node.content.size - slice.openEnd - extra)
        return (start, end)
    }
}
