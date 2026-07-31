import DocumentModel
import EditorStateKit
import EditorCommands

/// Whether the selection sits inside a node of the given type (with matching
/// attrs).
public func isNodeActive(_ state: EditorState, _ type: NodeType, _ attrs: Attrs? = nil) -> Bool {
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
            return lift(state, dispatch, host)
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
