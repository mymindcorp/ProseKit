public import DocumentModel

public extension Transform {
    /// Add the given mark to the inline content between `from` and `to`.
    @discardableResult
    func addMark(_ from: Int, _ to: Int, _ mark: Mark) throws -> Self {
        // No separate steps to remove the marks this one excludes:
        // `AddMarkStep.apply` drops them, and its `invert` puts them back.
        var added: [any Step] = []
        doc.nodesBetween(from, to, { node, pos, parent, _ in
            guard node.isInline, let parent else { return true }
            if !mark.isInSet(node.marks) && parent.type.allowsMarkType(mark.type) {
                pushMarkStep(&added, adding: true, Swift.max(pos, from), Swift.min(pos + node.nodeSize, to), mark)
            }
            return true
        })
        for s in added { try step(s) }
        return self
    }

    /// Remove a specific mark from the inline content between `from` and `to`.
    @discardableResult
    func removeMark(_ from: Int, _ to: Int, _ mark: Mark) throws -> Self {
        try removeMarkRanges(from, to) { node in
            mark.isInSet(node.marks) ? [mark] : []
        }
    }
}

public extension Transform {
    /// Remove all marks of the given type between `from` and `to`.
    @discardableResult
    func removeMark(_ from: Int, _ to: Int, _ markType: MarkType) throws -> Self {
        try removeMarkRanges(from, to) { node in
            var toRemove: [Mark] = []
            var set = node.marks
            while let found = markType.isInSet(set) {
                toRemove.append(found)
                set = found.removeFromSet(set)
            }
            return toRemove
        }
    }

    /// Remove all marks between `from` and `to`.
    @discardableResult
    func removeAllMarks(_ from: Int, _ to: Int) throws -> Self {
        try removeMarkRanges(from, to) { $0.marks }
    }

    private func removeMarkRanges(_ from: Int, _ to: Int, _ toRemoveFor: (Node) -> [Mark]) throws -> Self {
        struct Matched { var style: Mark; var from: Int; var to: Int; var step: Int }
        var matched: [Matched] = []
        var stepCount = 0
        doc.nodesBetween(from, to, { node, pos, _, _ in
            guard node.isInline, node.isAtom else { return true }
            stepCount += 1
            let toRemove = toRemoveFor(node)
            if !toRemove.isEmpty {
                let end = Swift.min(pos + node.nodeSize, to)
                for style in toRemove {
                    if let idx = matched.firstIndex(where: { $0.step == stepCount - 1 && $0.style == style }) {
                        matched[idx].to = end
                        matched[idx].step = stepCount
                    } else {
                        matched.append(Matched(style: style, from: Swift.max(pos, from), to: end, step: stepCount))
                    }
                }
            }
            return true
        })
        for m in matched { try step(RemoveMarkStep(m.from, m.to, m.style)) }
        return self
    }
}
