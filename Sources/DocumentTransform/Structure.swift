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
    // Track whether there is sibling content before/after the range at deeper
    // levels: at a shallower depth the lifted content must be inserted *beside*
    // that content (not replace it), so a lift that would push content before a
    // required node (e.g. a paragraph before a mandatory heading) is rejected.
    var contentBefore = 0
    var contentAfter = 0
    while true {
        let node = range.from.node(depth)
        let index = range.from.index(depth) + contentBefore
        let endIndex = range.to.indexAfter(depth) - contentAfter
        if depth < range.depth && node.canReplace(index, endIndex, replacement: content) { return depth }
        if depth == 0 || node.type.spec.isolating || !canCut(node, index, endIndex) { break }
        if index != 0 { contentBefore = 1 }
        if endIndex < node.childCount { contentAfter = 1 }
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
    func clearIncompatible(_ pos: Int, _ parentType: NodeType, _ match: ContentMatch? = nil, clearNewlines: Bool = true) throws -> Self {
        guard let node = doc.nodeAt(pos) else { return self }
        var match = match ?? parentType.contentMatch
        var replSteps: [Step] = []
        var cur = pos + 1
        // Code/`pre` blocks keep literal newlines; other textblocks turn them into
        // spaces (matching ProseMirror, so converting a code block to a paragraph
        // doesn't leave stray newline characters).
        let keepNewlines = parentType.spec.whitespace == .pre || parentType.spec.code
        for i in 0..<node.childCount {
            let child = node.child(i)
            let end = cur + child.nodeSize
            if let allowed = match.matchType(child.type) {
                match = allowed
                for m in child.marks where !parentType.allowsMarkType(m.type) {
                    try step(RemoveMarkStep(cur, end, m))
                }
                if clearNewlines, !keepNewlines, child.isText, let text = child.text {
                    let space = Slice(content: Fragment.from(parentType.schema.text(" ", parentType.allowedMarks(child.marks))), openStart: 0, openEnd: 0)
                    for (k, ch) in Array(text).enumerated() where ch == "\n" || ch == "\r" {
                        replSteps.append(ReplaceStep(cur + k, cur + k + 1, space))
                    }
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
        guard depth >= 1, depth <= resolved.depth else {
            throw TransformError.failed("Split depth \(depth) out of range at position \(pos)")
        }
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
        let rFrom = doc.resolve(from)
        let rTo = doc.resolve(to)
        if fitsTrivially(rFrom, rTo, slice) {
            return try step(ReplaceStep(from, to, slice))
        }

        // Depths at which the range covers whole nodes — candidate levels to
        // expand the replacement out to so the slice's structure is preserved.
        var targetDepths = coveredDepths(rFrom, rTo)
        if targetDepths.last == 0 { targetDepths.removeLast() } // can't replace the whole doc
        // Negative depths mean "replace from before(-d) to `to`" without expanding
        // the right side over the whole node.
        var preferredTarget = -(rFrom.depth + 1)
        targetDepths.insert(preferredTarget, at: 0)
        var pos = rFrom.pos - 1
        var d = rFrom.depth
        while d > 0 {
            let spec = rFrom.node(d).type.spec
            if spec.defining || spec.isolating { break }
            if targetDepths.contains(d) { preferredTarget = d }
            else if rFrom.before(d) == pos { targetDepths.insert(-d, at: 1) }
            d -= 1; pos -= 1
        }
        let preferredTargetIndex = targetDepths.firstIndex(of: preferredTarget) ?? 0

        // The chain of left-edge nodes of the slice (deepest = openStart).
        var leftNodes: [Node] = []
        var preferredDepth = slice.openStart
        var content = slice.content
        var i = 0
        while let node = content.firstChild {
            leftNodes.append(node)
            if i == slice.openStart { break }
            content = node.content
            i += 1
        }
        // Back up preferredDepth to cover defining textblocks above it.
        var dd = preferredDepth - 1
        while dd >= 0 {
            let leftNode = leftNodes[dd]
            let def = leftNode.type.spec.defining
            if def && !leftNode.sameMarkup(rFrom.node(abs(preferredTarget) - 1)) { preferredDepth = dd }
            else if def || !leftNode.type.isTextblock { break }
            dd -= 1
        }

        // Try fitting each slice depth into each target depth, preferred first.
        var j = slice.openStart
        while j >= 0 {
            let openDepth = (j + preferredDepth + 1) % (slice.openStart + 1)
            if openDepth < leftNodes.count {
                let insert = leftNodes[openDepth]
                for k in 0..<targetDepths.count {
                    var targetDepth = targetDepths[(k + preferredTargetIndex) % targetDepths.count]
                    var expand = true
                    if targetDepth < 0 { expand = false; targetDepth = -targetDepth }
                    let parent = rFrom.node(targetDepth - 1)
                    let index = rFrom.index(targetDepth - 1)
                    if parent.canReplaceWith(index, index, insert.type, insert.marks) {
                        let newContent = closeFragment(slice.content, 0, slice.openStart, openDepth, nil)
                        return try replace(rFrom.before(targetDepth), expand ? rTo.after(targetDepth) : to,
                                           Slice(content: newContent, openStart: openDepth, openEnd: slice.openEnd))
                    }
                }
            }
            j -= 1
        }

        // Fall back to a plain replace, widening the range until a step lands.
        let startSteps = steps.count
        var f = from, t = to
        var k = targetDepths.count - 1
        while k >= 0 {
            _ = try? replace(f, t, slice)
            if steps.count > startSteps { break }
            let depth = targetDepths[k]
            if depth >= 0 { f = rFrom.before(depth); t = rTo.after(depth) }
            k -= 1
        }
        return self
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

    /// Delete the given range. Where deleting the inner content would leave an
    /// empty parent, the deletion is expanded outward to drop that parent too
    /// (so deleting the only paragraph in a list item removes the item). Mirrors
    /// ProseMirror's `deleteRange`; every depth access is bounded by the shallower
    /// of `from`/`to`, so it never traps when `to` resolves shallower than `from`.
    @discardableResult
    func deleteRange(_ from: Int, _ to: Int) throws -> Self {
        var from = from
        var to = to
        var rFrom = doc.resolve(from)
        var rTo = doc.resolve(to)

        // When the range spans from the start of one textblock to the start of
        // another, move out of the start of both blocks before deleting.
        if rFrom.parent.isTextblock, rTo.parent.isTextblock,
           rFrom.start() != rTo.start(), rFrom.pos == rFrom.start(), rTo.pos == rTo.start() {
            let shared = rFrom.sharedDepth(to)
            var isolated = false
            var d = rFrom.depth
            while d > shared { if rFrom.node(d).type.spec.isolating { isolated = true }; d -= 1 }
            d = rTo.depth
            while d > shared { if rTo.node(d).type.spec.isolating { isolated = true }; d -= 1 }
            if !isolated {
                d = rFrom.depth
                while d > 0, from == rFrom.start(d) { from = rFrom.before(d); d -= 1 }
                d = rTo.depth
                while d > 0, to == rTo.start(d) { to = rTo.before(d); d -= 1 }
                rFrom = doc.resolve(from)
                rTo = doc.resolve(to)
            }
        }

        let covered = coveredDepths(rFrom, rTo)
        for (i, depth) in covered.enumerated() {
            let last = i == covered.count - 1
            if (last && depth == 0) || rFrom.node(depth).type.contentMatch.validEnd {
                return try delete(rFrom.start(depth), rTo.end(depth))
            }
            if depth > 0,
               last || rFrom.node(depth - 1).canReplace(rFrom.index(depth - 1), rTo.indexAfter(depth - 1)) {
                return try delete(rFrom.before(depth), rTo.after(depth))
            }
        }
        var d = 1
        while d <= rFrom.depth, d <= rTo.depth {
            if from - rFrom.start(d) == rFrom.depth - d, to > rFrom.end(d), rTo.end(d) - to != rTo.depth - d,
               rFrom.start(d - 1) == rTo.start(d - 1),
               rFrom.node(d - 1).canReplace(rFrom.index(d - 1), rTo.index(d - 1)) {
                return try delete(rFrom.before(d), to)
            }
            d += 1
        }
        return try delete(from, to)
    }
}

/// The list of depths, deepest first, at which `from`/`to` cover whole nodes —
/// i.e. the range runs exactly from a node's start to its end. (ProseMirror's
/// `coveredDepths`.) Bounded by `min(from.depth, to.depth)`.
/// Re-close a slice's content to a new open depth, filling required nodes so the
/// (now shallower) open fragment is valid. (ProseMirror's `closeFragment`.)
private func closeFragment(_ fragment: Fragment, _ depth: Int, _ oldOpen: Int, _ newOpen: Int, _ parent: Node?) -> Fragment {
    var fragment = fragment
    if depth < oldOpen, let first = fragment.firstChild {
        fragment = fragment.replaceChild(0, first.copy(content: closeFragment(first.content, depth + 1, oldOpen, newOpen, first)))
    }
    if depth > newOpen, let parent {
        let match = parent.contentMatchAt(0)
        let start = (match.fillBefore(fragment) ?? .empty).append(fragment)
        let end = match.matchFragment(start)?.fillBefore(.empty, toEnd: true) ?? .empty
        fragment = start.append(end)
    }
    return fragment
}

private func coveredDepths(_ from: ResolvedPos, _ to: ResolvedPos) -> [Int] {
    var result: [Int] = []
    let minDepth = min(from.depth, to.depth)
    var d = minDepth
    while d >= 0 {
        let start = from.start(d)
        if start < from.pos - (from.depth - d) ||
            to.end(d) > to.pos + (to.depth - d) ||
            from.node(d).type.spec.isolating ||
            to.node(d).type.spec.isolating { break }
        if start == to.start(d) ||
            (d == from.depth && d == to.depth && from.parent.inlineContent && to.parent.inlineContent &&
             d > 0 && to.start(d - 1) == start - 1) {
            result.append(d)
        }
        d -= 1
    }
    return result
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
