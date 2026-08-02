public import DocumentModel
public import DocumentTransform
import EditorStateKit

// MARK: - Block reordering

/// Move the top-level block at `fromIndex` so it lands at drop-gap `toIndex`
/// (0...childCount, the position *before* the child at that index). A no-op when
/// the gap is adjacent to the source. Pure transform — no view dependency — so a
/// drag handle, a menu command, or a script can all reuse it.
public func moveBlock(_ fromIndex: Int, _ toIndex: Int) -> Command {
    { state, dispatch, _ in
        let doc = state.doc
        guard fromIndex >= 0, fromIndex < doc.childCount,
              toIndex >= 0, toIndex <= doc.childCount,
              toIndex != fromIndex, toIndex != fromIndex + 1 else { return false }
        func startPos(_ index: Int) -> Int {
            (0..<min(index, doc.childCount)).reduce(0) { $0 + doc.child($1).nodeSize }
        }
        let node = doc.child(fromIndex)
        let from = startPos(fromIndex), to = from + node.nodeSize
        let target = startPos(toIndex)
        guard let dispatch else { return true } // dry run (can-perform check)
        let tr = state.tr
        guard (try? tr.delete(from, to)) != nil else { return false }
        let insertAt = tr.mapping.map(target)
        guard (try? tr.insert(insertAt, node)) != nil else { return false }
        dispatch(tr.scrollIntoView())
        return true
    }
}

// MARK: - Deletion

/// Delete the selection, if there is one.
public let deleteSelection: Command = { state, dispatch, _ in
    if state.selection.empty { return false }
    dispatch?(state.tr.deleteSelection().scrollIntoView())
    return true
}

private func atBlockStart(_ state: EditorState, _ host: (any CommandHost)?) -> ResolvedPos? {
    guard let sel = state.selection as? TextSelection, let cursor = sel.cursor else { return nil }
    if let host, let end = host.endOfTextblock("backward", state) {
        if !end { return nil }
    } else if cursor.parentOffset > 0 {
        return nil
    }
    return cursor
}

private func atBlockEnd(_ state: EditorState, _ host: (any CommandHost)?) -> ResolvedPos? {
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
public let joinBackward: Command = { state, dispatch, host in
    guard let cursor = atBlockStart(state, host) else { return false }
    guard let cut = findCutBefore(cursor) else {
        // At the start of the document or an isolating boundary — try lift.
        guard let range = cursor.blockRange(), let target = liftTarget(range) else { return false }
        if let dispatch, let tr = try? state.tr.lift(range, target) { dispatch(tr.scrollIntoView()) }
        return true
    }
    let before = cut.nodeBefore
    if deleteBarrier(state, cut, dispatch, -1) { return true }
    if cursor.parent.content.size == 0, let before, (textblockAt(before, "end") || NodeSelection.isSelectable(before)) {
        var depth = cursor.depth
        while true {
            if let delStep = replaceStep(state.doc, cursor.before(depth), cursor.after(depth), .empty) as? ReplaceStep,
               delStep.slice.size < delStep.to - delStep.from {
                if let dispatch, let tr = try? state.tr.step(delStep) {
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
        if let dispatch, let tr = try? state.tr.delete(cut.pos - before.nodeSize, cut.pos) { dispatch(tr.scrollIntoView()) }
        return true
    }
    return false
}

/// Symmetric of `joinBackward`, joining the block after the cursor.
public let joinForward: Command = { state, dispatch, host in
    guard let cursor = atBlockEnd(state, host) else { return false }
    guard let cut = findCutAfter(cursor) else { return false }
    let after = cut.nodeAfter
    if deleteBarrier(state, cut, dispatch, 1) { return true }
    if cursor.parent.content.size == 0, let after, (textblockAt(after, "start") || NodeSelection.isSelectable(after)) {
        if let delStep = replaceStep(state.doc, cursor.before(cursor.depth), cursor.after(cursor.depth), .empty) as? ReplaceStep,
           delStep.slice.size < delStep.to - delStep.from {
            if let dispatch, let tr = try? state.tr.step(delStep) { dispatch(tr.scrollIntoView()) }
            return true
        }
    }
    if let after, after.isAtom, cut.depth == cursor.depth - 1 {
        if let dispatch, let tr = try? state.tr.delete(cut.pos, cut.pos + after.nodeSize) { dispatch(tr.scrollIntoView()) }
        return true
    }
    return false
}

private func joinMaybeClear(_ state: EditorState, _ pos: ResolvedPos, _ dispatch: Dispatch?) -> Bool {
    guard let before = pos.nodeBefore, let after = pos.nodeAfter, before.type.compatibleContent(after.type) else { return false }
    let index = pos.index()
    if before.content.size == 0 && pos.parent.canReplace(index - 1, index) {
        if let dispatch, let tr = try? state.tr.delete(pos.pos - before.nodeSize, pos.pos) { dispatch(tr.scrollIntoView()) }
        return true
    }
    if !pos.parent.canReplace(index, index + 1) || !(after.isTextblock || canJoin(state.doc, pos.pos)) {
        return false
    }
    if let dispatch {
        let tr = state.tr
        _ = try? tr.clearIncompatible(pos.pos, before.type, before.contentMatchAt(before.childCount))
        _ = try? tr.join(pos.pos)
        dispatch(tr.scrollIntoView())
    }
    return true
}

private func deleteBarrier(_ state: EditorState, _ cut: ResolvedPos, _ dispatch: Dispatch?, _ dir: Int) -> Bool {
    guard let before = cut.nodeBefore, let after = cut.nodeAfter else { return false }
    let isolated = before.type.spec.isolating || after.type.spec.isolating
    if !isolated && joinMaybeClear(state, cut, dispatch) { return true }

    let canDelAfter = !isolated && cut.parent.canReplace(cut.index(), cut.index() + 1)
    // Try moving the after-block *into* the before-block (e.g. a paragraph
    // following a blockquote joins inside it), wrapping it as needed.
    let match = before.contentMatchAt(before.childCount)
    if canDelAfter, let conn = match.findWrapping(after.type),
       match.matchType(conn.first ?? after.type)?.validEnd == true {
        if let dispatch {
            let end = cut.pos + after.nodeSize
            var wrap = Fragment.empty
            var i = conn.count - 1
            while i >= 0 {
                guard let node = try? conn[i].create(content: wrap) else { return true }
                wrap = Fragment.from(node); i -= 1
            }
            wrap = Fragment.from(before.copy(content: wrap))
            let tr = state.tr
            _ = try? tr.step(ReplaceAroundStep(cut.pos - 1, end, cut.pos, end,
                                               Slice(content: wrap, openStart: 1, openEnd: 0), conn.count, structure: true))
            let joinAt = tr.doc.resolve(end + 2 * conn.count)
            if let na = joinAt.nodeAfter, na.type === before.type, canJoin(tr.doc, joinAt.pos) {
                _ = try? tr.join(joinAt.pos)
            }
            dispatch(tr.scrollIntoView())
        }
        return true
    }
    // Try lifting the after-block out.
    let selAfter = (after.type.spec.isolating || (dir > 0 && isolated)) ? nil : Selection.findFrom(cut, 1)
    if let selAfter, let range = selAfter.resolvedFrom.blockRange(selAfter.resolvedTo),
       let target = liftTarget(range), target >= cut.depth {
        if let dispatch, let tr = try? state.tr.lift(range, target) { dispatch(tr.scrollIntoView()) }
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
                if let tr = try? state.tr.step(step) { dispatch(tr.scrollIntoView()) }
            }
            return true
        }
    }
    return false
}

/// When the cursor is at the start of a textblock and there is a selectable
/// node before it, select that node.
public let selectNodeBackward: Command = { state, dispatch, host in
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
public let selectNodeForward: Command = { state, dispatch, host in
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
    let nodeSel = sel as? NodeSelection
    let point: Int?
    if let nodeSel {
        // A selected (non-textblock) node joins with its previous sibling.
        if nodeSel.node.isTextblock || !canJoin(state.doc, sel.from) { return false }
        point = sel.from
    } else {
        point = joinPoint(state.doc, sel.from, -1)
    }
    guard let p = point else { return false }
    if let dispatch, let tr = try? state.tr.join(p) {
        if nodeSel != nil { tr.setSelection(NodeSelection.create(tr.doc, p - state.doc.resolve(p).nodeBefore!.nodeSize)) }
        dispatch(tr.scrollIntoView())
    }
    return true
}

/// Join the selected block, or the closest ancestor block, with the one above.
public let joinUp: Command = { state, dispatch, _ in joinUpCommand(state, dispatch) }

/// Join the selected block, or the closest ancestor block, with the one below.
public let joinDown: Command = { state, dispatch, _ in
    let sel = state.selection
    let point: Int?
    if let nodeSel = sel as? NodeSelection {
        if nodeSel.node.isTextblock || !canJoin(state.doc, sel.to) { return false }
        point = sel.to
    } else {
        point = joinPoint(state.doc, sel.to, 1)
    }
    guard let p = point else { return false }
    if let dispatch, let tr = try? state.tr.join(p) { dispatch(tr.scrollIntoView()) }
    return true
}

/// Lift the selected block, or the closest ancestor block, out of its parent.
public let lift: Command = { state, dispatch, _ in
    let sel = state.selection
    guard let range = sel.resolvedFrom.blockRange(sel.resolvedTo), let target = liftTarget(range) else { return false }
    if let dispatch, let tr = try? state.tr.lift(range, target) { dispatch(tr.scrollIntoView()) }
    return true
}

// MARK: - Code blocks

/// If the selection is in a node whose type has a truthy `code` spec, insert a
/// newline.
public let newlineInCode: Command = { state, dispatch, _ in
    let head = state.selection.resolvedHead
    let anchor = state.selection.resolvedAnchor
    guard head.parent.type.spec.code, head.sameParent(anchor) else { return false }
    if let dispatch, let tr = try? state.tr.insertText("\n") { dispatch(tr.scrollIntoView()) }
    return true
}

private func defaultBlockAt(_ match: ContentMatch) -> NodeType? {
    for type in match.edgeTypes where type.isTextblock && !type.hasRequiredAttrs {
        return type
    }
    return nil
}

/// When in a code block at the end, exit by creating a default block below.
public let exitCode: Command = { state, dispatch, _ in
    let sel = state.selection
    let from = sel.resolvedFrom, to = sel.resolvedTo
    guard from.parent.type.spec.code, to.pos == from.end() else { return false }
    let above = from.node(-1)
    let after = from.indexAfter(-1)
    guard let type = defaultBlockAt(above.contentMatchAt(after)),
          above.canReplaceWith(after, after, type), let filled = type.createAndFill() else { return false }
    if let dispatch {
        let pos = from.after()
        guard let tr = try? state.tr.replaceWith(pos, pos, filled) else { return false }
        tr.setSelection(Selection.near(tr.doc.resolve(pos), 1))
        dispatch(tr.scrollIntoView())
    }
    return true
}

// MARK: - Block creation / splitting

/// If a block node is selected, create an empty paragraph before (if it's at
/// the start of the doc) or after it.
public let createParagraphNear: Command = { state, dispatch, _ in
    let sel = state.selection
    let from = sel.resolvedFrom, to = sel.resolvedTo
    if from.parent.inlineContent || to.parent.inlineContent { return false }
    guard let type = defaultBlockAt(to.parent.contentMatchAt(to.indexAfter())),
          let filled = type.createAndFill() else { return false }
    if let dispatch {
        // Insert before the node when it's at the start of its parent and has
        // siblings after it; otherwise insert after.
        let pos = (from.pos == from.start() && to.indexAfter() < to.parent.childCount) ? from.pos : to.pos
        guard let tr = try? state.tr.insert(pos, filled) else { return false }
        tr.setSelection(TextSelection.create(tr.doc, pos + 1))
        dispatch(tr.scrollIntoView())
    }
    return true
}

/// If the cursor is in an empty textblock that can be lifted, lift it.
public let liftEmptyBlock: Command = { state, dispatch, _ in
    guard let sel = state.selection as? TextSelection, let cursor = sel.cursor else { return false }
    if cursor.parent.content.size != 0 { return false }
    if cursor.depth > 1, cursor.after() != cursor.end(cursor.depth - 1) {
        let before = cursor.before()
        if canSplit(state.doc, before) {
            if let dispatch, let tr = try? state.tr.split(before) { dispatch(tr.scrollIntoView()) }
            return true
        }
    }
    guard let range = cursor.blockRange(), let target = liftTarget(range) else { return false }
    if let dispatch, let tr = try? state.tr.lift(range, target) { dispatch(tr.scrollIntoView()) }
    return true
}

/// Split the parent block of the selection.
public let splitBlock: Command = splitBlockAs(nil)

/// Build a split command, optionally choosing the type of the new block.
public func splitBlockAs(_ splitNode: (@Sendable (_ node: Node, _ atEnd: Bool) -> NodeTypeWithAttrs?)?) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        let from = sel.resolvedFrom, to = sel.resolvedTo
        if sel is NodeSelection, (sel as! NodeSelection).node.isBlock {
            guard from.parentOffset > 0, canSplit(state.doc, from.pos) else { return false }
            if let dispatch, let tr = try? state.tr.split(from.pos) { dispatch(tr.scrollIntoView()) }
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
                _ = try? tr.split(realFrom, 1, typesAfter)
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
public let selectParentNode: Command = { state, dispatch, _ in
    let sel = state.selection
    var pos: Int?
    let same = sel.resolvedFrom.sharedDepth(sel.to)
    if same == 0 { return false }
    pos = sel.resolvedFrom.before(same)
    if let dispatch, let p = pos { dispatch(state.tr.setSelection(NodeSelection.create(state.doc, p))) }
    return true
}

/// Select the whole document.
public let selectAll: Command = { state, dispatch, _ in
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
                    if has {
                        _ = try? tr.removeMark(range.from.pos, range.to.pos, markType)
                    } else {
                        // Skip leading/trailing whitespace when adding a mark (but
                        // not for whitespace-only selections), matching ProseMirror.
                        var from = range.from.pos, to = range.to.pos
                        let spaceStart = range.from.nodeAfter?.isText == true ? leadingWhitespace(range.from.nodeAfter!.text ?? "") : 0
                        let spaceEnd = range.to.nodeBefore?.isText == true ? trailingWhitespace(range.to.nodeBefore!.text ?? "") : 0
                        if from + spaceStart < to { from += spaceStart; to -= spaceEnd }
                        _ = try? tr.addMark(from, to, markType.create(attrs))
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
        if let dispatch, let tr = try? state.tr.wrap(range, wrappers) { dispatch(tr.scrollIntoView()) }
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
                _ = try? tr.setBlockType(range.from.pos, range.to.pos, nodeType, attrs)
            }
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

private func leadingWhitespace(_ s: String) -> Int {
    var n = 0
    for ch in s { if ch.isWhitespace { n += 1 } else { break } }
    return n
}
private func trailingWhitespace(_ s: String) -> Int {
    var n = 0
    for ch in s.reversed() { if ch.isWhitespace { n += 1 } else { break } }
    return n
}


// MARK: - Textblock-limited joining (prosemirror-commands joinTextblockBackward/Forward)

/// A more limited `joinBackward`: only joins the current textblock to the one
/// before it, when the cursor sits at the start of a textblock.
public let joinTextblockBackward: Command = { state, dispatch, host in
    guard let cursor = atBlockStart(state, host), let cut = findCutBefore(cursor) else { return false }
    return joinTextblocksAround(state, cut, dispatch)
}

/// The forward counterpart of `joinTextblockBackward`.
public let joinTextblockForward: Command = { state, dispatch, host in
    guard let cursor = atBlockEnd(state, host), let cut = findCutAfter(cursor) else { return false }
    return joinTextblocksAround(state, cut, dispatch)
}

private func joinTextblocksAround(_ state: EditorState, _ cut: ResolvedPos, _ dispatch: Dispatch?) -> Bool {
    guard var beforeText = cut.nodeBefore, var afterText = cut.nodeAfter else { return false }
    var beforePos = cut.pos - 1
    while !beforeText.isTextblock {
        if beforeText.type.spec.isolating { return false }
        guard let child = beforeText.lastChild else { return false }
        beforeText = child
        beforePos -= 1
    }
    var afterPos = cut.pos + 1
    while !afterText.isTextblock {
        if afterText.type.spec.isolating { return false }
        guard let child = afterText.firstChild else { return false }
        afterText = child
        afterPos += 1
    }
    // Like upstream: a ReplaceAroundStep is acceptable here — the slice-size
    // guard only applies to plain ReplaceSteps.
    guard let step = replaceStep(state.doc, beforePos, afterPos, .empty) else { return false }
    if let rs = step as? ReplaceStep {
        guard rs.from == beforePos, rs.slice.size < afterPos - beforePos else { return false }
    } else if let ras = step as? ReplaceAroundStep {
        guard ras.from == beforePos else { return false }
    } else {
        return false
    }
    if let dispatch {
        let tr = state.tr
        _ = tr.maybeStep(step)
        tr.setSelection(TextSelection.create(tr.doc, beforePos))
        dispatch(tr.scrollIntoView())
    }
    return true
}

// MARK: - splitBlockKeepMarks

/// Like `splitBlock`, but without resetting the active marks at the cursor.
public let splitBlockKeepMarks: Command = { state, dispatch, host in
    splitBlock(state, dispatch.map { dispatch in
        { tr in
            let marks = state.storedMarks
                ?? (state.selection.resolvedTo.parentOffset > 0 ? state.selection.resolvedFrom.marks() : nil)
            if let marks { tr.ensureMarks(marks) }
            dispatch(tr)
        }
    }, host)
}

// MARK: - selectTextblockStart / selectTextblockEnd

private func selectTextblockSide(_ side: Int) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        let pos = side < 0 ? sel.resolvedFrom : sel.resolvedTo
        var depth = pos.depth
        while pos.node(depth).isInline {
            if depth == 0 { return false }
            depth -= 1
        }
        guard pos.node(depth).isTextblock else { return false }
        dispatch?(state.tr.setSelection(TextSelection.create(
            state.doc, side < 0 ? pos.start(depth) : pos.end(depth))))
        return true
    }
}

/// Move the cursor to the start of the current textblock.
public let selectTextblockStart = selectTextblockSide(-1)
/// Move the cursor to the end of the current textblock.
public let selectTextblockEnd = selectTextblockSide(1)

// MARK: - autoJoin

/// Wrap a command so that, when its transform leaves two joinable nodes of the
/// same type next to each other, they get joined.
public func autoJoin(_ command: @escaping Command,
                     _ isJoinable: @escaping @Sendable (Node, Node) -> Bool) -> Command {
    { state, dispatch, host in
        command(state, dispatch.map { wrapDispatchForJoin($0, isJoinable) }, host)
    }
}

/// `autoJoin` keyed by node type names.
public func autoJoin(_ command: @escaping Command, _ nodeTypes: [String]) -> Command {
    autoJoin(command) { before, _ in nodeTypes.contains(before.type.name) }
}

private func wrapDispatchForJoin(_ dispatch: @escaping Dispatch,
                                 _ isJoinable: @escaping (Node, Node) -> Bool) -> Dispatch {
    { tr in
        guard tr.isGeneric else { return dispatch(tr) }

        var ranges: [Int] = []
        for map in tr.mapping.maps {
            for j in 0..<ranges.count { ranges[j] = map.map(ranges[j]) }
            map.forEach { _, _, from, to in
                ranges.append(from)
                ranges.append(to)
            }
        }

        // Joinable points inside those ranges: check node boundaries in their
        // shared parents.
        var joinable: [Int] = []
        var i = 0
        while i < ranges.count {
            let from = ranges[i], to = ranges[i + 1]
            i += 2
            let resolved = tr.doc.resolve(from)
            let depth = resolved.sharedDepth(to)
            let parent = resolved.node(depth)
            var index = resolved.indexAfter(depth)
            var pos = resolved.after(depth + 1)
            while pos <= to, let after = parent.maybeChild(index) {
                if index > 0, !joinable.contains(pos) {
                    let before = parent.child(index - 1)
                    if before.type === after.type, isJoinable(before, after) {
                        joinable.append(pos)
                    }
                }
                pos += after.nodeSize
                index += 1
            }
        }
        joinable.sort()
        for point in joinable.reversed() where canJoin(tr.doc, point) {
            _ = try? tr.join(point)
        }
        dispatch(tr)
    }
}
