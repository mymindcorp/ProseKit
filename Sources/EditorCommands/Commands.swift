import DocumentModel
import DocumentTransform
import EditorStateKit

// MARK: - Deletion

/// Delete the selection, if there is one.
nonisolated(unsafe) public let deleteSelection: Command = { state, dispatch, _ in
    if state.selection.empty { return false }
    dispatch?(state.tr.deleteSelection().scrollIntoView())
    return true
}

private func atBlockStart(_ state: EditorState, _ host: CommandHost?) -> ResolvedPos? {
    guard let sel = state.selection as? TextSelection, let cursor = sel.cursor else { return nil }
    if let host, let end = host.endOfTextblock("backward", state) {
        if !end { return nil }
    } else if cursor.parentOffset > 0 {
        return nil
    }
    return cursor
}

private func atBlockEnd(_ state: EditorState, _ host: CommandHost?) -> ResolvedPos? {
    guard let sel = state.selection as? TextSelection, let cursor = sel.cursor else { return nil }
    if let host, let end = host.endOfTextblock("forward", state) {
        if !end { return nil }
    } else if cursor.parentOffset < cursor.parent.content.size {
        return nil
    }
    return cursor
}

private func findCutBefore(_ pos: ResolvedPos) -> ResolvedPos? {
    if !pos.parent.type.spec.isolating {
        var i = pos.depth - 1
        while i >= 0 {
            if pos.index(i) > 0 { return pos.doc.resolve(pos.before(i + 1)) }
            if pos.node(i).type.spec.isolating { break }
            i -= 1
        }
    }
    return nil
}

private func findCutAfter(_ pos: ResolvedPos) -> ResolvedPos? {
    if !pos.parent.type.spec.isolating {
        var i = pos.depth - 1
        while i >= 0 {
            let parent = pos.node(i)
            if pos.index(i) + 1 < parent.childCount { return pos.doc.resolve(pos.after(i + 1)) }
            if parent.type.spec.isolating { break }
            i -= 1
        }
    }
    return nil
}

private func textblockAt(_ node: Node?, _ side: String, only: Bool = false) -> Bool {
    var scan = node
    while let n = scan {
        if n.isTextblock { return true }
        if only && n.childCount > 1 { return false }
        scan = side == "start" ? n.firstChild : n.lastChild
    }
    return false
}

/// If the cursor is at the start of a textblock, try to reduce the distance
/// between it and the one before it.
nonisolated(unsafe) public let joinBackward: Command = { state, dispatch, host in
    guard let cursor = atBlockStart(state, host) else { return false }
    guard let cut = findCutBefore(cursor) else {
        // At the start of the document or an isolating boundary — try lift.
        guard let range = cursor.blockRange(), let target = liftTarget(range) else { return false }
        if let dispatch { dispatch(try! state.tr.lift(range, target).scrollIntoView()) }
        return true
    }
    let before = cut.nodeBefore
    if deleteBarrier(state, cut, dispatch, -1) { return true }
    if cursor.parent.content.size == 0, let before, (textblockAt(before, "end") || NodeSelection.isSelectable(before)) {
        var depth = cursor.depth
        while true {
            if let delStep = replaceStep(state.doc, cursor.before(depth), cursor.after(depth), .empty) as? ReplaceStep,
               delStep.slice.size < delStep.to - delStep.from {
                if let dispatch {
                    let tr = try! state.tr.step(delStep)
                    let mapped = tr.mapping.map(cut.pos, -1)
                    if textblockAt(before, "end") {
                        tr.setSelection(Selection.findFrom(tr.doc.resolve(mapped), -1) ?? Selection.atStart(tr.doc))
                    } else {
                        tr.setSelection(NodeSelection.create(tr.doc, cut.pos - before.nodeSize))
                    }
                    dispatch(tr.scrollIntoView())
                }
                return true
            }
            if depth == 1 || cursor.node(depth - 1).childCount > 1 { break }
            depth -= 1
        }
    }
    if let before, before.isAtom, cut.depth == cursor.depth - 1 {
        if let dispatch { dispatch(try! state.tr.delete(cut.pos - before.nodeSize, cut.pos).scrollIntoView()) }
        return true
    }
    return false
}

/// Symmetric of `joinBackward`, joining the block after the cursor.
nonisolated(unsafe) public let joinForward: Command = { state, dispatch, host in
    guard let cursor = atBlockEnd(state, host) else { return false }
    guard let cut = findCutAfter(cursor) else { return false }
    let after = cut.nodeAfter
    if deleteBarrier(state, cut, dispatch, 1) { return true }
    if cursor.parent.content.size == 0, let after, (textblockAt(after, "start") || NodeSelection.isSelectable(after)) {
        if let delStep = replaceStep(state.doc, cursor.before(cursor.depth), cursor.after(cursor.depth), .empty) as? ReplaceStep,
           delStep.slice.size < delStep.to - delStep.from {
            if let dispatch { dispatch(try! state.tr.step(delStep).scrollIntoView()) }
            return true
        }
    }
    if let after, after.isAtom, cut.depth == cursor.depth - 1 {
        if let dispatch { dispatch(try! state.tr.delete(cut.pos, cut.pos + after.nodeSize).scrollIntoView()) }
        return true
    }
    return false
}

private func joinMaybeClear(_ state: EditorState, _ pos: ResolvedPos, _ dispatch: Dispatch?) -> Bool {
    guard let before = pos.nodeBefore, let after = pos.nodeAfter, before.type.compatibleContent(after.type) else { return false }
    let index = pos.index()
    if before.content.size == 0 && pos.parent.canReplace(index - 1, index) {
        if let dispatch { dispatch(try! state.tr.delete(pos.pos - before.nodeSize, pos.pos).scrollIntoView()) }
        return true
    }
    if !pos.parent.canReplace(index, index + 1) || !(after.isTextblock || canJoin(state.doc, pos.pos)) {
        return false
    }
    if let dispatch {
        let tr = state.tr
        try? tr.clearIncompatible(pos.pos, before.type, before.contentMatchAt(before.childCount))
        try? tr.join(pos.pos)
        dispatch(tr.scrollIntoView())
    }
    return true
}

private func deleteBarrier(_ state: EditorState, _ cut: ResolvedPos, _ dispatch: Dispatch?, _ dir: Int) -> Bool {
    guard let before = cut.nodeBefore, let after = cut.nodeAfter else { return false }
    let isolated = before.type.spec.isolating || after.type.spec.isolating
    if !isolated && joinMaybeClear(state, cut, dispatch) { return true }

    let canDelAfter = !isolated && cut.parent.canReplace(cut.index(), cut.index() + 1)
    // Try lifting the after-block out.
    let selAfter = (after.type.spec.isolating || (dir > 0 && isolated)) ? nil : Selection.findFrom(cut, 1)
    if let selAfter, let range = selAfter.resolvedFrom.blockRange(selAfter.resolvedTo),
       let target = liftTarget(range), target >= cut.depth {
        if let dispatch { dispatch(try! state.tr.lift(range, target).scrollIntoView()) }
        return true
    }
    // Try merging the after textblock into the end of the before block.
    if canDelAfter && textblockAt(after, "start", only: true) && textblockAt(before, "end") {
        var at = before
        var wrap: [Node] = []
        while true {
            wrap.append(at)
            if at.isTextblock { break }
            guard let last = at.lastChild else { break }
            at = last
        }
        var afterText = after
        var afterDepth = 1
        while !afterText.isTextblock {
            guard let first = afterText.firstChild else { break }
            afterText = first
            afterDepth += 1
        }
        if at.canReplace(at.childCount, at.childCount, replacement: afterText.content) {
            if let dispatch {
                var end = Fragment.empty
                var i = wrap.count - 1
                while i >= 0 { end = Fragment.from(wrap[i].copy(content: end)); i -= 1 }
                let step = ReplaceAroundStep(cut.pos - wrap.count, cut.pos + after.nodeSize,
                                             cut.pos + afterDepth, cut.pos + after.nodeSize - afterDepth,
                                             Slice(content: end, openStart: wrap.count, openEnd: 0), 0, structure: true)
                dispatch(try! state.tr.step(step).scrollIntoView())
            }
            return true
        }
    }
    return false
}

/// When the cursor is at the start of a textblock and there is a selectable
/// node before it, select that node.
nonisolated(unsafe) public let selectNodeBackward: Command = { state, dispatch, host in
    let sel = state.selection
    guard sel.empty else { return false }
    var cut: ResolvedPos? = sel.resolvedHead
    let head = sel.resolvedHead
    if head.parent.isTextblock {
        if let host, let end = host.endOfTextblock("backward", state) {
            if !end { return false }
        } else if head.parentOffset > 0 {
            return false
        }
        cut = findCutBefore(head)
    }
    guard let node = cut?.nodeBefore, NodeSelection.isSelectable(node) else { return false }
    if let dispatch {
        dispatch(state.tr.setSelection(NodeSelection.create(state.doc, cut!.pos - node.nodeSize)).scrollIntoView())
    }
    return true
}

/// Symmetric of `selectNodeBackward`.
nonisolated(unsafe) public let selectNodeForward: Command = { state, dispatch, host in
    let sel = state.selection
    guard sel.empty else { return false }
    var cut: ResolvedPos? = sel.resolvedHead
    let head = sel.resolvedHead
    if head.parent.isTextblock {
        if let host, let end = host.endOfTextblock("forward", state) {
            if !end { return false }
        } else if head.parentOffset < head.parent.content.size {
            return false
        }
        cut = findCutAfter(head)
    }
    guard let node = cut?.nodeAfter, NodeSelection.isSelectable(node) else { return false }
    if let dispatch {
        dispatch(state.tr.setSelection(NodeSelection.create(state.doc, cut!.pos)).scrollIntoView())
    }
    return true
}

// MARK: - Joining

private func joinUpCommand(_ state: EditorState, _ dispatch: Dispatch?) -> Bool {
    let sel = state.selection
    var nodeSel = sel as? NodeSelection
    var point: Int?
    if let nodeSel, nodeSel.node.isBlock {
        if nodeSel.resolvedFrom.depth == 0 { return false }
        point = joinPoint(state.doc, nodeSel.resolvedFrom.before())
    } else {
        point = joinPoint(state.doc, sel.from, -1)
        nodeSel = nil
    }
    guard let p = point else { return false }
    if let dispatch {
        let tr = try! state.tr.join(p)
        if nodeSel != nil { tr.setSelection(NodeSelection.create(tr.doc, p - state.doc.resolve(p).nodeBefore!.nodeSize)) }
        dispatch(tr.scrollIntoView())
    }
    return true
}

/// Join the selected block, or the closest ancestor block, with the one above.
nonisolated(unsafe) public let joinUp: Command = { state, dispatch, _ in joinUpCommand(state, dispatch) }

/// Join the selected block, or the closest ancestor block, with the one below.
nonisolated(unsafe) public let joinDown: Command = { state, dispatch, _ in
    let sel = state.selection
    var point: Int?
    if let nodeSel = sel as? NodeSelection, nodeSel.node.isBlock {
        point = joinPoint(state.doc, nodeSel.resolvedTo.after(), 1)
    } else {
        point = joinPoint(state.doc, sel.to, 1)
    }
    guard let p = point else { return false }
    if let dispatch { dispatch(try! state.tr.join(p).scrollIntoView()) }
    return true
}

/// Lift the selected block, or the closest ancestor block, out of its parent.
nonisolated(unsafe) public let lift: Command = { state, dispatch, _ in
    let sel = state.selection
    guard let range = sel.resolvedFrom.blockRange(sel.resolvedTo), let target = liftTarget(range) else { return false }
    if let dispatch { dispatch(try! state.tr.lift(range, target).scrollIntoView()) }
    return true
}

// MARK: - Code blocks

/// If the selection is in a node whose type has a truthy `code` spec, insert a
/// newline.
nonisolated(unsafe) public let newlineInCode: Command = { state, dispatch, _ in
    let head = state.selection.resolvedHead
    let anchor = state.selection.resolvedAnchor
    guard head.parent.type.spec.code, head.sameParent(anchor) else { return false }
    if let dispatch { dispatch(try! state.tr.insertText("\n").scrollIntoView()) }
    return true
}

private func defaultBlockAt(_ match: ContentMatch) -> NodeType? {
    for type in match.edgeTypes where type.isTextblock && !type.hasRequiredAttrs {
        return type
    }
    return nil
}

/// When in a code block at the end, exit by creating a default block below.
nonisolated(unsafe) public let exitCode: Command = { state, dispatch, _ in
    let sel = state.selection
    let from = sel.resolvedFrom, to = sel.resolvedTo
    guard from.parent.type.spec.code, to.pos == from.end() else { return false }
    let above = from.node(-1)
    let after = from.indexAfter(-1)
    guard let type = defaultBlockAt(above.contentMatchAt(after)),
          above.canReplaceWith(after, after, type) else { return false }
    if let dispatch {
        let pos = from.after()
        let tr = try! state.tr.replaceWith(pos, pos, type.createAndFill()!)
        tr.setSelection(Selection.near(tr.doc.resolve(pos), 1))
        dispatch(tr.scrollIntoView())
    }
    return true
}

// MARK: - Block creation / splitting

/// If a block node is selected, create an empty paragraph before (if it's at
/// the start of the doc) or after it.
nonisolated(unsafe) public let createParagraphNear: Command = { state, dispatch, _ in
    let sel = state.selection
    let from = sel.resolvedFrom, to = sel.resolvedTo
    if from.parent.inlineContent || to.parent.inlineContent { return false }
    guard let type = defaultBlockAt(to.parent.contentMatchAt(to.indexAfter())) else { return false }
    if let dispatch {
        let side = (!from.parentOffset.isMultiple(of: 1) ? from : to).pos
        // place after
        let pos = to.pos
        let tr = try! state.tr.insert(pos, type.createAndFill()!)
        tr.setSelection(TextSelection.create(tr.doc, pos + 1))
        dispatch(tr.scrollIntoView())
        _ = side
    }
    return true
}

/// If the cursor is in an empty textblock that can be lifted, lift it.
nonisolated(unsafe) public let liftEmptyBlock: Command = { state, dispatch, _ in
    guard let sel = state.selection as? TextSelection, let cursor = sel.cursor else { return false }
    if cursor.parent.content.size != 0 { return false }
    if cursor.depth > 1, cursor.after() != cursor.end(cursor.depth - 1) {
        let before = cursor.before()
        if canSplit(state.doc, before) {
            if let dispatch { dispatch(try! state.tr.split(before).scrollIntoView()) }
            return true
        }
    }
    guard let range = cursor.blockRange(), let target = liftTarget(range) else { return false }
    if let dispatch { dispatch(try! state.tr.lift(range, target).scrollIntoView()) }
    return true
}

/// Split the parent block of the selection.
nonisolated(unsafe) public let splitBlock: Command = splitBlockAs(nil)

/// Build a split command, optionally choosing the type of the new block.
public func splitBlockAs(_ splitNode: ((_ node: Node, _ atEnd: Bool) -> NodeTypeWithAttrs?)?) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        let from = sel.resolvedFrom, to = sel.resolvedTo
        if sel is NodeSelection, (sel as! NodeSelection).node.isBlock {
            guard from.parentOffset > 0, canSplit(state.doc, from.pos) else { return false }
            if let dispatch { dispatch(try! state.tr.split(from.pos).scrollIntoView()) }
            return true
        }
        if !from.parent.isBlock { return false }
        if let dispatch {
            let atEnd = to.parentOffset == to.parent.content.size
            let tr = state.tr
            if sel is TextSelection || sel is AllSelection { tr.deleteSelection() }
            let deflt = from.depth == 0 ? nil : defaultBlockAt(from.node(-1).contentMatchAt(from.indexAfter(-1)))
            var splitType = splitNode?(to.parent, atEnd)
            var typesAfter: [NodeTypeWithAttrs?]? = splitType.map { [$0] }
            if typesAfter == nil && atEnd && deflt != nil {
                typesAfter = [NodeTypeWithAttrs(deflt!)]
            }
            let realFrom = tr.mapping.map(from.pos)
            var can = canSplit(tr.doc, realFrom, 1, typesAfter)
            if !can {
                if typesAfter == nil, let deflt {
                    typesAfter = [NodeTypeWithAttrs(deflt)]
                    can = canSplit(tr.doc, realFrom, 1, typesAfter)
                }
            }
            if can {
                try? tr.split(realFrom, 1, typesAfter)
                if !atEnd, from.parentOffset == 0, from.depth > 0 {
                    // nothing extra
                }
            }
            dispatch(tr.scrollIntoView())
            _ = (deflt, splitType)
            splitType = nil
        }
        return true
    }
}

// MARK: - Selection commands

/// Move the selection to the node wrapping the current selection, if any.
nonisolated(unsafe) public let selectParentNode: Command = { state, dispatch, _ in
    let sel = state.selection
    var pos: Int?
    let same = sel.resolvedFrom.sharedDepth(sel.to)
    if same == 0 { return false }
    pos = sel.resolvedFrom.before(same)
    if let dispatch, let p = pos { dispatch(state.tr.setSelection(NodeSelection.create(state.doc, p))) }
    return true
}

/// Select the whole document.
nonisolated(unsafe) public let selectAll: Command = { state, dispatch, _ in
    dispatch?(state.tr.setSelection(AllSelection(state.doc)))
    return true
}

// MARK: - Marks

/// Whether the given mark type can be applied across the current selection.
private func markApplies(_ doc: Node, _ ranges: [SelectionRange], _ type: MarkType) -> Bool {
    for range in ranges {
        var can = range.from.depth == 0 ? doc.type.allowsMarkType(type) : false
        doc.nodesBetween(range.from.pos, range.to.pos, { node, _, _, _ in
            if can { return false }
            can = node.inlineContent && node.type.allowsMarkType(type)
            return true
        })
        if can { return true }
    }
    return false
}

/// Toggle the given mark over the selection (or stored marks when empty).
public func toggleMark(_ markType: MarkType, _ attrs: Attrs = [:]) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        let empty = sel.empty
        let ranges = sel.ranges
        if (empty && (sel as? TextSelection)?.cursor == nil) || !markApplies(state.doc, ranges, markType) {
            return false
        }
        if let dispatch {
            if empty, let cursor = (sel as? TextSelection)?.cursor {
                let mark = markType.create(attrs)
                if markType.isInSet(state.storedMarks ?? cursor.marks()) != nil {
                    dispatch(state.tr.removeStoredMark(markType))
                } else {
                    dispatch(state.tr.addStoredMark(mark))
                }
            } else {
                var has = true
                let tr = state.tr
                for range in ranges where has {
                    has = state.doc.rangeHasMark(range.from.pos, range.to.pos, markType)
                }
                for range in ranges {
                    let from = range.from.pos, to = range.to.pos
                    if has {
                        try? tr.removeMark(from, to, markType)
                    } else {
                        // trim leading/trailing whitespace-only? keep simple
                        try? tr.addMark(from, to, markType.create(attrs))
                    }
                }
                dispatch(tr.scrollIntoView())
            }
        }
        return true
    }
}

// MARK: - Block type / wrapping

/// Wrap the selection in a node of the given type.
public func wrapIn(_ nodeType: NodeType, _ attrs: Attrs = [:]) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        guard let range = sel.resolvedFrom.blockRange(sel.resolvedTo),
              let wrappers = findWrappingForRange(range, nodeType, attrs) else { return false }
        if let dispatch { dispatch(try! state.tr.wrap(range, wrappers).scrollIntoView()) }
        return true
    }
}

/// Set the type of the textblocks in the selection to the given node type.
public func setBlockType(_ nodeType: NodeType, _ attrs: Attrs = [:]) -> Command {
    { state, dispatch, _ in
        guard nodeType.isTextblock else { return false }
        let ranges = state.selection.ranges
        var applicable = false
        for range in ranges where !applicable {
            let from = range.from.pos, to = range.to.pos
            state.doc.nodesBetween(from, to, { node, pos, _, _ in
                if applicable { return false }
                if node.isTextblock && !node.hasMarkup(nodeType, attrs) {
                    if node.type === nodeType {
                        applicable = true
                    } else {
                        let resolved = state.doc.resolve(pos)
                        let index = resolved.index()
                        applicable = resolved.parent.canReplaceWith(index, index + 1, nodeType)
                    }
                }
                return true
            })
        }
        if !applicable { return false }
        if let dispatch {
            let tr = state.tr
            for range in ranges {
                try? tr.setBlockType(range.from.pos, range.to.pos, nodeType, attrs)
            }
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}
