import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands

// A port of prosemirror-schema-list's list manipulation commands.

/// Toggle the selection between being a list of the given type and not.
public func toggleList(_ listType: NodeType, _ itemType: NodeType) -> Command {
    { state, dispatch, host in
        if isNodeActive(state, listType) {
            return liftListItem(itemType)(state, dispatch, host)
        }
        // Directly wrappable (e.g. a paragraph) → wrap as usual.
        if wrapInList(listType)(state, nil, host) {
            return wrapInList(listType)(state, dispatch, host)
        }
        // Not directly wrappable: the current block can't be the list item's
        // first child — a heading, say, since the item's content requires a
        // leading paragraph. Convert the selected textblock(s) to paragraphs
        // first, then wrap, composing both into one undoable transaction.
        guard let paragraph = listType.schema.nodes["paragraph"] else { return false }
        var convertTr: Transaction?
        guard setBlockType(paragraph)(state, { convertTr = $0 }, host), let convert = convertTr else { return false }
        let converted = state.apply(convert)
        var wrapTr: Transaction?
        guard wrapInList(listType)(converted, { wrapTr = $0 }, host), let wrap = wrapTr else { return false }
        if let dispatch {
            let tr = state.tr
            for step in convert.steps { _ = try? tr.step(step) }
            for step in wrap.steps { _ = try? tr.step(step) }
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

/// Wrap the selection in a list of the given type.
public func wrapInList(_ listType: NodeType, _ attrs: Attrs = [:]) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        let from = sel.resolvedFrom, to = sel.resolvedTo
        guard var range = from.blockRange(to) else { return false }
        var outerRange = range
        var doJoin = false
        if range.depth >= 2, from.node(range.depth - 1).type.compatibleContent(listType), range.startIndex == 0 {
            if from.index(range.depth - 1) == 0 { return false }
            let insert = state.doc.resolve(range.start - 2)
            outerRange = NodeRange(insert, insert, range.depth)
            if range.endIndex < range.parent.childCount {
                range = NodeRange(from, state.doc.resolve(to.end(range.depth)), range.depth)
            }
            doJoin = true
        }
        guard let wrap = findWrappingForRange(outerRange, listType, attrs, range) else { return false }
        if let dispatch {
            dispatch(doWrapInList(state.tr, range, wrap, doJoin, listType).scrollIntoView())
        }
        return true
    }
}

private func doWrapInList(_ tr: Transaction, _ range: NodeRange, _ wrappers: [NodeTypeWithAttrs], _ joinBefore: Bool, _ listType: NodeType) -> Transaction {
    var content = Fragment.empty
    var i = wrappers.count - 1
    while i >= 0 {
        if let wrapped = try? wrappers[i].type.create(wrappers[i].attrs, content: content) {
            content = Fragment.from(wrapped)
        } else if let inner = content.firstChild {
            content = Fragment.from(inner) // couldn't wrap (e.g. a required attr) — keep going
        } // else: nothing to wrap yet; leave content empty
        i -= 1
    }
    _ = try? tr.step(ReplaceAroundStep(range.start - (joinBefore ? 2 : 0), range.end, range.start, range.end,
                                   Slice(content: content, openStart: 0, openEnd: 0), wrappers.count, structure: true))
    var found = 0
    for (idx, w) in wrappers.enumerated() where w.type === listType { found = idx + 1 }
    let splitDepth = wrappers.count - found
    var splitPos = range.start + wrappers.count - (joinBefore ? 2 : 0)
    let parent = range.parent
    var idx = range.startIndex
    let end = range.endIndex
    var first = true
    while idx < end {
        if !first && canSplit(tr.doc, splitPos, splitDepth) {
            _ = try? tr.split(splitPos, splitDepth)
            splitPos += 2 * splitDepth
        }
        splitPos += parent.child(idx).nodeSize
        idx += 1
        first = false
    }
    return tr
}

/// Split a list item, creating a new item.
public func splitListItem(_ itemType: NodeType, _ itemAttrs: Attrs? = nil) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        if let ns = sel as? NodeSelection, ns.node.isBlock { return false }
        let from = sel.resolvedFrom, to = sel.resolvedTo
        if from.depth < 2 || !from.sameParent(to) { return false }
        let grandParent = from.node(-1)
        if grandParent.type !== itemType { return false }

        if from.parent.content.size == 0 && from.node(-1).childCount == from.indexAfter(-1) {
            // In an empty block. If this is a nested list, split the wrapping list
            // item; otherwise bail out and let the next command handle lifting.
            if from.depth == 3 || from.node(-3).type !== itemType || from.index(-2) != from.node(-2).childCount - 1 {
                return false
            }
            if let dispatch {
                var wrap = Fragment.empty
                let depthBefore = from.index(-1) != 0 ? 1 : (from.index(-2) != 0 ? 2 : 3)
                // Empty copies of the structure from the outer list item down to
                // the cursor's parent.
                var d = from.depth - depthBefore
                while d >= from.depth - 3 {
                    wrap = Fragment.from(from.node(d).copy(content: wrap))
                    d -= 1
                }
                let depthAfter = from.indexAfter(-1) < from.node(-2).childCount ? 1
                    : (from.indexAfter(-2) < from.node(-3).childCount ? 2 : 3)
                wrap = wrap.append(Fragment.from(try! itemType.createAndFill()!))
                let start = from.before(from.depth - (depthBefore - 1))
                let tr = state.tr
                _ = try? tr.replace(start, from.after(-depthAfter), Slice(content: wrap, openStart: 4 - depthBefore, openEnd: 0))
                var sel = -1
                tr.doc.nodesBetween(start, tr.doc.content.size, { node, pos, _, _ in
                    if sel > -1 { return false }
                    if node.isTextblock && node.content.size == 0 { sel = pos + 1 }
                    return true
                })
                if sel > -1 { tr.setSelection(Selection.near(tr.doc.resolve(sel))) }
                dispatch(tr.scrollIntoView())
            }
            return true
        }

        let nextType: NodeType? = to.pos == from.end() ? grandParent.contentMatchAt(0).defaultType : nil
        let tr = state.tr
        _ = try? tr.delete(from.pos, to.pos)
        var types: [NodeTypeWithAttrs?]? = nil
        if let nextType {
            types = [itemAttrs != nil ? NodeTypeWithAttrs(itemType, itemAttrs!) : nil, NodeTypeWithAttrs(nextType)]
        } else if let itemAttrs {
            // Splitting mid-text: still force the new (lower) item's attrs
            // (e.g. a task split in the middle starts unchecked).
            types = [NodeTypeWithAttrs(itemType, itemAttrs), nil]
        }
        let splitPos = from.pos
        if !canSplit(tr.doc, splitPos, 2, types) { return false }
        if let dispatch {
            _ = try? tr.split(splitPos, 2, types)
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

/// Sink the selected list items one level deeper (indent).
public func sinkListItem(_ itemType: NodeType) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        let from = sel.resolvedFrom, to = sel.resolvedTo
        guard let range = from.blockRange(to, pred: { $0.childCount != 0 && $0.firstChild?.type === itemType }) else { return false }
        let startIndex = range.startIndex
        if startIndex == 0 { return false }
        let parent = range.parent
        let nodeBefore = parent.child(startIndex - 1)
        if nodeBefore.type !== itemType { return false }
        if let dispatch {
            let nestedBefore = nodeBefore.lastChild?.type === parent.type
            let innerInner = nestedBefore ? Fragment.from(try! itemType.create()) : Fragment.empty
            let inner = Fragment.from(try! parent.type.create([:], content: innerInner))
            let slice = Slice(content: Fragment.from(try! itemType.create([:], content: inner)),
                              openStart: nestedBefore ? 3 : 1, openEnd: 0)
            let before = range.start, after = range.end
            let tr = state.tr
            _ = try? tr.step(ReplaceAroundStep(before - (nestedBefore ? 3 : 1), after, before, after, slice, 1, structure: true))
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

/// Lift the selected list items out of their list (outdent).
public func liftListItem(_ itemType: NodeType) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        let from = sel.resolvedFrom, to = sel.resolvedTo
        guard let range = from.blockRange(to, pred: { $0.childCount != 0 && $0.firstChild?.type === itemType }) else { return false }
        if dispatch == nil { return true }
        if from.node(range.depth - 1).type === itemType {
            return liftToOuterList(state, dispatch!, itemType, range)
        }
        return liftOutOfList(state, dispatch!, range)
    }
}

private func liftToOuterList(_ state: EditorState, _ dispatch: Dispatch, _ itemType: NodeType, _ range0: NodeRange) -> Bool {
    var range = range0
    let tr = state.tr
    let end = range.end
    let endOfList = range.to.end(range.depth)
    if end < endOfList {
        // Siblings after the lifted items must become children of the last item:
        // wrap them in an empty copy of the surrounding list inside a new item.
        _ = try? tr.step(ReplaceAroundStep(end - 1, endOfList, end, endOfList,
            Slice(content: Fragment.from(try! itemType.create([:], content: range.parent.copy(content: .empty))), openStart: 1, openEnd: 0), 1, structure: true))
        range = NodeRange(tr.doc.resolve(range.from.pos), tr.doc.resolve(endOfList), range.depth)
    }
    guard let target = liftTarget(range) else { return false }
    _ = try? tr.lift(range, target)
    let afterPos = tr.mapping.map(end, -1) - 1
    let after = tr.doc.resolve(afterPos)
    if canJoin(tr.doc, afterPos), after.nodeBefore?.type === after.nodeAfter?.type {
        _ = try? tr.join(afterPos)
    }
    dispatch(tr.scrollIntoView())
    return true
}

private func liftOutOfList(_ state: EditorState, _ dispatch: Dispatch, _ range: NodeRange) -> Bool {
    let tr = state.tr
    let list = range.parent
    var pos = range.end
    var i = range.endIndex - 1
    let e = range.startIndex
    while i > e {
        pos -= list.child(i).nodeSize
        _ = try? tr.delete(pos - 1, pos + 1)
        i -= 1
    }
    let start = tr.doc.resolve(range.start)
    guard let item = start.nodeAfter else { return false }
    if tr.mapping.map(range.end) != range.start + item.nodeSize { return false }
    let atStart = range.startIndex == 0
    let atEnd = range.endIndex == list.childCount
    let parent = start.node(-1)
    let indexBefore = start.index(-1)
    let replacement = item.content.append(atEnd ? .empty : Fragment.from(list))
    if !parent.canReplace(indexBefore + (atStart ? 0 : 1), indexBefore + 1, replacement: replacement) {
        return false
    }
    let startPos = start.pos
    let endPos = startPos + item.nodeSize
    let sliceContent = (atStart ? Fragment.empty : Fragment.from(list.copy(content: .empty)))
        .append(atEnd ? .empty : Fragment.from(list.copy(content: .empty)))
    _ = try? tr.step(ReplaceAroundStep(startPos - (atStart ? 1 : 0), endPos + (atEnd ? 1 : 0), startPos + 1, endPos - 1,
        Slice(content: sliceContent, openStart: atStart ? 0 : 1, openEnd: atEnd ? 0 : 1), atStart ? 0 : 1, structure: true))
    dispatch(tr.scrollIntoView())
    return true
}
