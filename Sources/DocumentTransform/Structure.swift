import DocumentModel

/// A pair of a node type and the attributes to create it with, used by the
/// structural transform helpers.
public struct NodeTypeWithAttrs {
    public var type: NodeType
    public var attrs: Attrs
    public init(_ type: NodeType, _ attrs: Attrs = [:]) {
        self.type = type
        self.attrs = attrs
    }
}

// MARK: - Lift

/// Try to find a target depth to which the content in the given range can be
/// lifted up.
public func liftTarget(_ range: NodeRange) -> Int? {
    let parent = range.parent
    let content = parent.content.cutByIndex(range.startIndex, range.endIndex)
    var depth = range.depth
    while true {
        let node = range.from.node(depth)
        let index = range.from.index(depth)
        let endIndex = range.to.indexAfter(depth)
        if depth < range.depth && node.canReplace(index, endIndex, replacement: content) { return depth }
        if depth == 0 || node.type.spec.isolating || !canCut(node, index, endIndex) { break }
        depth -= 1
    }
    return nil
}

private func canCut(_ node: Node, _ start: Int, _ end: Int) -> Bool {
    (start == 0 || node.canReplace(start, node.childCount)) &&
        (end == node.childCount || node.canReplace(0, end))
}

// MARK: - Wrapping

/// Try to find a valid way to wrap the content in the given range in a node of
/// the given type.
public func findWrappingForRange(_ range: NodeRange, _ nodeType: NodeType, _ attrs: Attrs = [:], _ innerRange: NodeRange? = nil) -> [NodeTypeWithAttrs]? {
    let inner = innerRange ?? range
    guard let around = findWrappingOutside(range, nodeType),
          let insideTypes = findWrappingInside(inner, nodeType) else { return nil }
    var result = around.map { NodeTypeWithAttrs($0) }
    result.append(NodeTypeWithAttrs(nodeType, attrs))
    result.append(contentsOf: insideTypes.map { NodeTypeWithAttrs($0) })
    return result
}

private func findWrappingOutside(_ range: NodeRange, _ type: NodeType) -> [NodeType]? {
    let parent = range.parent
    let startIndex = range.startIndex
    let endIndex = range.endIndex
    guard let around = parent.contentMatchAt(startIndex).findWrapping(type) else { return nil }
    let outer = around.first ?? type
    return parent.canReplaceWith(startIndex, endIndex, outer) ? around : nil
}

private func findWrappingInside(_ range: NodeRange, _ type: NodeType) -> [NodeType]? {
    let parent = range.parent
    let inner = parent.child(range.startIndex)
    guard let inside = type.contentMatch.findWrapping(inner.type) else { return nil }
    let lastType = inside.last ?? type
    var innerMatch: ContentMatch? = lastType.contentMatch
    var i = range.startIndex
    while let m = innerMatch, i < range.endIndex {
        innerMatch = m.matchType(parent.child(i).type)
        i += 1
    }
    guard let final = innerMatch, final.validEnd else { return nil }
    return inside
}

// MARK: - Transform structure methods

public extension Transform {
    /// Split the content in the given range off from its parent, by up to
    /// `target` depth levels.
    @discardableResult
    func lift(_ range: NodeRange, _ target: Int) throws -> Self {
        let from = range.from, to = range.to, depth = range.depth
        let gapStart = from.before(depth + 1)
        let gapEnd = to.after(depth + 1)
        var start = gapStart, end = gapEnd

        var before = Fragment.empty
        var openStart = 0
        var splitting = false
        var d = depth
        while d > target {
            if splitting || from.index(d) > 0 {
                splitting = true
                before = Fragment.from(from.node(d).copy(content: before))
                openStart += 1
            } else {
                start -= 1
            }
            d -= 1
        }
        var after = Fragment.empty
        var openEnd = 0
        splitting = false
        d = depth
        while d > target {
            if splitting || to.after(d + 1) < to.end(d) {
                splitting = true
                after = Fragment.from(to.node(d).copy(content: after))
                openEnd += 1
            } else {
                end += 1
            }
            d -= 1
        }
        return try step(ReplaceAroundStep(start, end, gapStart, gapEnd,
            Slice(content: before.append(after), openStart: openStart, openEnd: openEnd),
            before.size - openStart, structure: true))
    }

    /// Wrap the content in the given range in the given set of wrappers.
    @discardableResult
    func wrap(_ range: NodeRange, _ wrappers: [NodeTypeWithAttrs]) throws -> Self {
        var content = Fragment.empty
        var i = wrappers.count - 1
        while i >= 0 {
            if content.size != 0 {
                let match = wrappers[i].type.contentMatch.matchFragment(content)
                if match == nil || match?.validEnd != true {
                    throw TransformError.failed("Wrapper type given to Transform.wrap does not form valid content of its parent wrapper")
                }
            }
            content = Fragment.from(try wrappers[i].type.create(wrappers[i].attrs, content: content))
            i -= 1
        }
        let start = range.start, end = range.end
        return try step(ReplaceAroundStep(start, end, start, end, Slice(content: content, openStart: 0, openEnd: 0), wrappers.count, structure: true))
    }

    /// Set the type of all textblocks (partly) between `from` and `to` to the
    /// given node type with the given attributes.
    @discardableResult
    func setBlockType(_ from: Int, _ to: Int? = nil, _ type: NodeType, _ attrs: Attrs = [:]) throws -> Self {
        let to = to ?? from
        if !type.isTextblock { throw TransformError.failed("Type given to setBlockType should be a textblock") }
        let mapFrom = steps.count
        doc.nodesBetween(from, to, { node, pos, _, _ in
            let mappedPos = self.mapping.slice(mapFrom).map(pos, 1)
            if node.isTextblock && !node.hasMarkup(type, attrs) && canChangeType(self.doc, mappedPos, type) {
                _ = try? self.clearIncompatible(self.mapping.slice(mapFrom).map(pos, 1), type)
                let mapping = self.mapping.slice(mapFrom)
                let startM = mapping.map(pos, 1)
                let endM = mapping.map(pos + node.nodeSize, 1)
                let newNode = (try? type.create(attrs, content: .empty, marks: node.marks)) ?? node
                _ = try? self.step(ReplaceAroundStep(startM, endM, startM + 1, endM - 1,
                    Slice(content: Fragment.from(newNode), openStart: 0, openEnd: 0), 1, structure: true))
                return false
            }
            return true
        })
        return self
    }

    /// Change the type, attributes, and/or marks of the node at `pos`.
    @discardableResult
    func setNodeMarkup(_ pos: Int, _ type: NodeType? = nil, _ attrs: Attrs = [:], _ marks: [Mark]? = nil) throws -> Self {
        guard let node = doc.nodeAt(pos) else { throw TransformError.failed("No node at given position") }
        let type = type ?? node.type
        let newNode = try type.create(attrs, content: .empty, marks: marks ?? node.marks)
        if node.isLeaf {
            return try replaceWith(pos, pos + node.nodeSize, newNode)
        }
        if !type.validContent(node.content) {
            throw TransformError.failed("Invalid content for node type \(type.name)")
        }
        return try step(ReplaceAroundStep(pos, pos + node.nodeSize, pos + 1, pos + node.nodeSize - 1,
            Slice(content: Fragment.from(newNode), openStart: 0, openEnd: 0), 1, structure: true))
    }

    /// Set a single attribute on the node at `pos`.
    @discardableResult
    func setNodeAttribute(_ pos: Int, _ attr: String, _ value: AttributeValue) throws -> Self {
        try step(AttrStep(pos, attr, value))
    }

    /// Set a single attribute on the document node.
    @discardableResult
    func setDocAttribute(_ attr: String, _ value: AttributeValue) throws -> Self {
        try step(DocAttrStep(attr, value))
    }

    /// Add a mark to the node at `pos`.
    @discardableResult
    func addNodeMark(_ pos: Int, _ mark: Mark) throws -> Self {
        try step(AddNodeMarkStep(pos, mark))
    }

    /// Remove a mark (or mark of a type) from the node at `pos`.
    @discardableResult
    func removeNodeMark(_ pos: Int, _ mark: Mark) throws -> Self {
        try step(RemoveNodeMarkStep(pos, mark))
    }

    /// Remove content/marks from a node that aren't valid given a (new) parent
    /// type, fixing up content to be valid.
    @discardableResult
    func clearIncompatible(_ pos: Int, _ parentType: NodeType, _ match: ContentMatch? = nil) throws -> Self {
        guard let node = doc.nodeAt(pos) else { return self }
        var match = match ?? parentType.contentMatch
        var replSteps: [Step] = []
        var cur = pos + 1
        for i in 0..<node.childCount {
            let child = node.child(i)
            let end = cur + child.nodeSize
            if let allowed = match.matchType(child.type) {
                match = allowed
                for m in child.marks where !parentType.allowsMarkType(m.type) {
                    try step(RemoveMarkStep(cur, end, m))
                }
            } else {
                replSteps.append(ReplaceStep(cur, end, .empty))
            }
            cur = end
        }
        if !match.validEnd {
            let fill = match.fillBefore(.empty, toEnd: true) ?? .empty
            try replace(cur, cur, Slice(content: fill, openStart: 0, openEnd: 0))
        }
        var i = replSteps.count - 1
        while i >= 0 {
            try step(replSteps[i])
            i -= 1
        }
        return self
    }

    /// Split the node at the given position, up to `depth` levels.
    @discardableResult
    func split(_ pos: Int, _ depth: Int = 1, _ typesAfter: [NodeTypeWithAttrs?]? = nil) throws -> Self {
        let resolved = doc.resolve(pos)
        var before = Fragment.empty
        var after = Fragment.empty
        var d = resolved.depth
        let e = resolved.depth - depth
        var i = depth - 1
        while d > e {
            before = Fragment.from(resolved.node(d).copy(content: before))
            let typeAfter = (typesAfter != nil && i >= 0 && i < typesAfter!.count) ? typesAfter![i] : nil
            if let typeAfter {
                after = Fragment.from(try typeAfter.type.create(typeAfter.attrs, content: after))
            } else {
                after = Fragment.from(resolved.node(d).copy(content: after))
            }
            d -= 1
            i -= 1
        }
        return try step(ReplaceStep(pos, pos, Slice(content: before.append(after), openStart: depth, openEnd: depth), structure: true))
    }

    /// Join the blocks around the given position.
    @discardableResult
    func join(_ pos: Int, _ depth: Int = 1) throws -> Self {
        try step(ReplaceStep(pos - depth, pos + depth, .empty, structure: true))
    }

    // MARK: - Range replacement

    /// Replace a range while preserving as much surrounding structure as
    /// possible, expanding the replaced range outward if that allows the slice
    /// to fit better.
    @discardableResult
    func replaceRange(_ from: Int, _ to: Int, _ slice: Slice) throws -> Self {
        if slice.size == 0 { return try deleteRange(from, to) }
        let resolvedFrom = doc.resolve(from)
        let resolvedTo = doc.resolve(to)
        if fitsTrivially(resolvedFrom, resolvedTo, slice) {
            return try step(ReplaceStep(from, to, slice))
        }
        // Fall back to the generic replace (Fitter handles structure).
        return try replace(from, to, slice)
    }

    /// Replace the given range with a single node.
    @discardableResult
    func replaceRangeWith(_ from: Int, _ to: Int, _ node: Node) throws -> Self {
        if !node.isInline && from == to,
           let point = insertPoint(doc, from, node.type) {
            return try replaceWith(point, point, node)
        }
        return try replaceWith(from, to, node)
    }

    /// Delete the given range, joining content where that produces a valid
    /// result.
    @discardableResult
    func deleteRange(_ from: Int, _ to: Int) throws -> Self {
        // A plain structural delete already joins content correctly across node
        // boundaries (the Fitter handles it). An earlier "covered depths"
        // expansion here was a no-op loop that read `resolvedTo` at depths it
        // doesn't have — trapping (array out-of-bounds) whenever `to` resolves to
        // a shallower depth than `from`, e.g. deleting a selection running from
        // inside a nested block out to a top-level position.
        try delete(from, to)
    }
}

private func canChangeType(_ doc: Node, _ pos: Int, _ type: NodeType) -> Bool {
    let resolved = doc.resolve(pos)
    let index = resolved.index()
    return resolved.parent.canReplaceWith(index, index + 1, type)
}

// MARK: - Free helpers

/// Test whether the blocks before and after the given position can be joined.
public func canJoin(_ doc: Node, _ pos: Int) -> Bool {
    let resolved = doc.resolve(pos)
    let index = resolved.index()
    return joinable(resolved.nodeBefore, resolved.nodeAfter) && resolved.parent.canReplace(index, index + 1)
}

private func joinable(_ a: Node?, _ b: Node?) -> Bool {
    guard let a, let b, !a.isLeaf else { return false }
    return a.canAppend(b)
}

/// Find an ancestor boundary, starting at the given position, that can be
/// joined in the given direction.
public func joinPoint(_ doc: Node, _ pos: Int, _ dir: Int = -1) -> Int? {
    let resolved = doc.resolve(pos)
    var pos = pos
    var d = resolved.depth
    while true {
        var before: Node?
        var after: Node?
        var index = resolved.index(d)
        if d == resolved.depth {
            before = resolved.nodeBefore
            after = resolved.nodeAfter
        } else if dir > 0 {
            before = resolved.node(d + 1)
            index += 1
            after = resolved.node(d).maybeChild(index)
        } else {
            before = resolved.node(d).maybeChild(index - 1)
            after = resolved.node(d + 1)
        }
        if let before, !before.isTextblock, joinable(before, after), resolved.node(d).canReplace(index, index + 1) {
            return pos
        }
        if d == 0 { break }
        pos = dir < 0 ? resolved.before(d) : resolved.after(d)
        d -= 1
    }
    return nil
}

/// Find a position at which the given node type can be inserted near `pos`.
public func insertPoint(_ doc: Node, _ pos: Int, _ nodeType: NodeType) -> Int? {
    let resolved = doc.resolve(pos)
    if resolved.parent.canReplaceWith(resolved.index(), resolved.index(), nodeType) { return pos }
    if resolved.parentOffset == 0 {
        var d = resolved.depth - 1
        while d >= 0 {
            let index = resolved.index(d)
            if resolved.node(d).canReplaceWith(index, index, nodeType) { return resolved.before(d + 1) }
            if index > 0 { return nil }
            d -= 1
        }
    }
    if resolved.parentOffset == resolved.parent.content.size {
        var d = resolved.depth - 1
        while d >= 0 {
            let index = resolved.indexAfter(d)
            if resolved.node(d).canReplaceWith(index, index, nodeType) { return resolved.after(d + 1) }
            if index < resolved.node(d).childCount { return nil }
            d -= 1
        }
    }
    return nil
}

/// Test whether splitting at the given position is allowed.
public func canSplit(_ doc: Node, _ pos: Int, _ depth: Int = 1, _ typesAfter: [NodeTypeWithAttrs?]? = nil) -> Bool {
    let resolved = doc.resolve(pos)
    let base = resolved.depth - depth
    let innerType = (typesAfter?.last ?? nil)?.type ?? resolved.parent.type
    if base < 0 || resolved.parent.type.spec.isolating ||
        !resolved.parent.canReplace(resolved.index(), resolved.parent.childCount) ||
        !innerType.validContent(resolved.parent.content.cutByIndex(resolved.index(), resolved.parent.childCount)) {
        return false
    }
    var d = resolved.depth - 1
    var i = depth - 2
    while d > base {
        let node = resolved.node(d)
        let index = resolved.index(d)
        if node.type.spec.isolating { return false }
        var rest = node.content.cutByIndex(index, node.childCount)
        let overrideChild = (typesAfter != nil && i + 1 >= 0 && i + 1 < typesAfter!.count) ? typesAfter![i + 1] : nil
        if let overrideChild, let created = try? overrideChild.type.create(overrideChild.attrs) {
            rest = rest.replaceChild(0, created)
        }
        let after = ((typesAfter != nil && i >= 0 && i < typesAfter!.count) ? typesAfter![i] : nil)?.type ?? node.type
        if !node.canReplace(index + 1, node.childCount) || !after.validContent(rest) { return false }
        d -= 1
        i -= 1
    }
    let index = resolved.indexAfter(base)
    let baseType = (typesAfter != nil && !typesAfter!.isEmpty) ? typesAfter![0] : nil
    return resolved.node(base).canReplaceWith(index, index, baseType?.type ?? resolved.node(base + 1).type)
}
