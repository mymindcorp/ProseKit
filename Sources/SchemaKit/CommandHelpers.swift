public import DocumentModel
import DocumentTransform
public import EditorStateKit
public import EditorCommands

/// Whether the selection sits inside a node of the given type (with matching
/// attrs).
public func isNodeActive(_ state: EditorState, _ type: NodeType, _ attrs: Attrs? = nil) -> Bool {
    if let selection = state.selection as? NodeSelection, selection.node.type === type,
       attrs?.allSatisfy({ selection.node.attrs[$0.key] == $0.value }) ?? true {
        return true
    }
    let from = state.selection.resolvedFrom
    var depth = from.depth
    while depth >= 0 {
        let node = from.node(depth)
        if node.type === type {
            if let attrs {
                if attrs.allSatisfy({ node.attrs[$0.key] == $0.value }) { return true }
            } else {
                return true
            }
        }
        depth -= 1
    }
    return false
}

/// Toggle the block type of the selection between `type` and `defaultType`.
public func toggleBlockType(_ type: NodeType, _ defaultType: NodeType, _ attrs: Attrs = [:]) -> Command {
    { state, dispatch, host in
        if isNodeActive(state, type, attrs) {
            return setBlockType(defaultType)(state, dispatch, host)
        }
        return setBlockType(type, attrs)(state, dispatch, host)
    }
}

/// Toggle whether the selection is wrapped in a node of the given type.
public func toggleWrap(_ type: NodeType, _ attrs: Attrs = [:]) -> Command {
    { state, dispatch, host in
        if isNodeActive(state, type) {
            let selection = state.selection
            let range: NodeRange?
            if let selected = selection as? NodeSelection, selected.node.type === type {
                guard !selected.node.isLeaf else { return false }
                range = NodeRange(state.doc.resolve(selected.from + 1),
                                  state.doc.resolve(selected.to - 1), selected.resolvedFrom.depth + 1)
            } else {
                // Lift the target wrapper's children, not a closer list item
                // or other container that happens to hold the selection.
                range = selection.resolvedFrom.blockRange(selection.resolvedTo, pred: { $0.type === type })
            }
            guard let range, let target = liftTarget(range), target == range.depth - 1 else { return false }
            let tr = state.tr
            guard (try? tr.lift(range, target)) != nil else { return false }
            dispatch?(tr.scrollIntoView())
            return true
        }
        return wrapIn(type, attrs)(state, dispatch, host)
    }
}

/// The depth of the nearest ancestor (or self) of the given type, if any.
public func ancestorDepth(_ pos: ResolvedPos, _ type: NodeType) -> Int? {
    var depth = pos.depth
    while depth > 0 {
        if pos.node(depth).type === type { return depth }
        depth -= 1
    }
    return nil
}

/// Resolve the explicitly selected node before looking for an enclosing one.
func selectedNodeOrAncestor(_ state: EditorState, _ type: NodeType) -> (node: Node, pos: Int)? {
    if let selection = state.selection as? NodeSelection, selection.node.type === type {
        return (selection.node, selection.from)
    }
    let from = state.selection.resolvedFrom
    guard let depth = ancestorDepth(from, type) else { return nil }
    return (from.node(depth), from.before(depth))
}

// Fitting can drop a node that the destination forbids, sometimes deleting
// the selected text in the process. Validate the changed ranges rather than
// accepting an identical node that already exists elsewhere in the document.
func containsInsertedNode(_ tr: Transaction, _ node: Node) -> Bool {
    var inserted = false
    for (index, map) in tr.mapping.maps.enumerated() {
        let after = tr.mapping.slice(index + 1)
        map.forEach { _, _, newStart, newEnd in
            let from = after.map(newStart, -1), to = after.map(newEnd, 1)
            tr.doc.nodesBetween(from, to, { candidate, pos, _, _ in
                if candidate.type === node.type, candidate.attrs == node.attrs, candidate.content == node.content,
                   pos >= from, pos + candidate.nodeSize <= to {
                    inserted = true
                }
                return !inserted
            })
        }
    }
    return inserted
}
