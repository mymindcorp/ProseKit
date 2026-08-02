public import DocumentModel
public import DocumentTransform

// A port of prosemirror-gapcursor: a cursor at positions that have no normal
// selectable position nearby — between two tables, before a leading atom
// block, after a trailing one — so the user can still place a caret there and
// type (which materializes the gap's default textblock).
//
// View-layer differences from upstream: the DOM widget decoration is replaced
// by the renderer drawing a caret for a `GapCursor` selection, and upstream's
// `view.endOfTextblock` check in the arrow handler is approximated headlessly
// with parent-offset edge checks (exact for single-line blocks, the same
// tradeoff TableInput makes).

/// A gap cursor selection: anchor and head both point at the gap position.
public final class GapCursor: Selection {
    public init(_ pos: ResolvedPos) {
        super.init(pos, pos)
    }

    override public var empty: Bool { true }

    override public func eq(_ other: Selection) -> Bool {
        other is GapCursor && other.head == head
    }

    override public func map(_ doc: Node, _ mapping: any Mappable) -> Selection {
        let pos = doc.resolve(mapping.map(head))
        return GapCursor.valid(pos) ? GapCursor(pos) : Selection.near(pos)
    }

    override public func content() -> Slice { .empty }

    /// Replacing a gap cursor materializes the gap's default textblock: inline
    /// content is wrapped in it (upstream relies on the DOM reader to do this
    /// wrapping; we have no DOM, so the selection does it directly).
    override public func replace(_ tr: Transaction, _ content: Slice = .empty) {
        let pos = head
        guard content.content.childCount > 0 else { return } // deleting a gap is a no-op
        let inline = content.content.firstChild?.isInline == true
        if inline, content.openStart == 0, content.openEnd == 0,
           let deflt = resolvedHead.parent.contentMatchAt(resolvedHead.index()).defaultType,
           let block = deflt.createAndFill([:], content: content.content) {
            if (try? tr.replaceWith(pos, pos, block)) != nil {
                tr.setSelection(TextSelection.create(tr.doc, pos + 1 + content.content.size))
            }
            return
        }
        if (try? tr.replaceRange(pos, pos, content)) != nil {
            tr.setSelection(Selection.near(tr.doc.resolve(min(tr.doc.content.size, pos + content.content.size))))
        }
    }

    override public func replaceWith(_ tr: Transaction, _ node: Node) {
        replace(tr, Slice(content: Fragment.from([node]), openStart: 0, openEnd: 0))
    }

    override public func toJSON() -> [String: AttributeValue] {
        ["type": .string("gapcursor"), "pos": .int(head)]
    }

    override public func getBookmark() -> any SelectionBookmark {
        GapBookmark(pos: anchor)
    }

    /// Whether a gap cursor is allowed at this position: the parent must not be
    /// inline content, both neighbours must be "closed" (no text positions at
    /// the boundary), and the position's default child must be a textblock so
    /// typing can materialize one.
    public static func valid(_ pos: ResolvedPos) -> Bool {
        let parent = pos.parent
        if parent.inlineContent || !closedBefore(pos) || !closedAfter(pos) { return false }
        if let override_ = parent.type.spec.allowGapCursor { return override_ }
        guard let deflt = parent.contentMatchAt(pos.index()).defaultType else { return false }
        return deflt.isTextblock
    }

    /// Search for a valid gap cursor position from `pos` in direction `dir`
    /// (upstream `findGapCursorFrom`).
    public static func findGapCursorFrom(_ start: ResolvedPos, _ dir: Int, _ mustMoveStart: Bool = false) -> ResolvedPos? {
        var posR = start
        var mustMove = mustMoveStart
        search: while true {
            if !mustMove, GapCursor.valid(posR) { return posR }
            var pos = posR.pos
            var next: Node? = nil
            // Scan up from this position.
            var d = posR.depth
            while true {
                let parent = posR.node(d)
                if dir > 0 ? posR.indexAfter(d) < parent.childCount : posR.index(d) > 0 {
                    next = parent.child(dir > 0 ? posR.indexAfter(d) : posR.index(d) - 1)
                    break
                } else if d == 0 {
                    return nil
                }
                pos += dir
                let cur = posR.doc.resolve(pos)
                if GapCursor.valid(cur) { return cur }
                d -= 1
            }

            // And then down into the next node.
            while true {
                let inside: Node? = dir > 0 ? next!.firstChild : next!.lastChild
                guard let inside else {
                    if next!.isAtom, !next!.isText, !NodeSelection.isSelectable(next!) {
                        posR = posR.doc.resolve(pos + next!.nodeSize * dir)
                        mustMove = false
                        continue search
                    }
                    break
                }
                next = inside
                pos += dir
                let cur = posR.doc.resolve(pos)
                if GapCursor.valid(cur) { return cur }
            }

            return nil
        }
    }
}

/// Bookmark for a gap cursor (history restores it through this).
public struct GapBookmark: SelectionBookmark {
    public let pos: Int
    public func map(_ mapping: any Mappable) -> any SelectionBookmark {
        GapBookmark(pos: mapping.map(pos, 1))
    }
    public func resolve(_ doc: Node) -> Selection {
        let resolved = doc.resolve(min(max(0, pos), doc.content.size))
        return GapCursor.valid(resolved) ? GapCursor(resolved) : Selection.near(resolved)
    }
}

private func needsGap(_ node: Node) -> Bool {
    node.type.isAtom || node.type.spec.isolating
}

private func closedBefore(_ pos: ResolvedPos) -> Bool {
    var d = pos.depth
    while d >= 0 {
        let index = pos.index(d)
        let parent = pos.node(d)
        // At the start of this parent: look at the next one up.
        if index == 0 {
            if parent.type.spec.isolating { return true }
            d -= 1
            continue
        }
        // See if the node before (or its last descendant) is closed.
        var before = parent.child(index - 1)
        while true {
            if (before.childCount == 0 && !before.inlineContent) || needsGap(before) { return true }
            if before.inlineContent { return false }
            guard let last = before.lastChild else { return false }
            before = last
        }
    }
    return true // hit start of document
}

private func closedAfter(_ pos: ResolvedPos) -> Bool {
    var d = pos.depth
    while d >= 0 {
        let index = pos.indexAfter(d)
        let parent = pos.node(d)
        if index == parent.childCount {
            if parent.type.spec.isolating { return true }
            d -= 1
            continue
        }
        var after = parent.child(index)
        while true {
            if (after.childCount == 0 && !after.inlineContent) || needsGap(after) { return true }
            if after.inlineContent { return false }
            guard let first = after.firstChild else { return false }
            after = first
        }
    }
    return true
}

/// Create the gap cursor plugin: arrow-key motion into gaps. (Click placement
/// is the view layer's job; it can test positions with `GapCursor.valid`.)
public func gapCursor() -> Plugin {
    Plugin(key: "gapCursor", props: PluginProps(handleKeyDown: { key, state, dispatch in
        switch key {
        case "ArrowLeft": return gapCursorArrow(state, dir: -1, vertical: false, dispatch)
        case "ArrowRight": return gapCursorArrow(state, dir: 1, vertical: false, dispatch)
        case "ArrowUp": return gapCursorArrow(state, dir: -1, vertical: true, dispatch)
        case "ArrowDown": return gapCursorArrow(state, dir: 1, vertical: true, dispatch)
        default: return false
        }
    }))
}

private func gapCursorArrow(_ state: EditorState, dir: Int, vertical: Bool,
                            _ dispatch: ((Transaction) -> Void)?) -> Bool {
    let sel = state.selection
    var start = dir > 0 ? sel.resolvedTo : sel.resolvedFrom
    var mustMove = sel.empty
    if sel is TextSelection {
        // Headless stand-in for upstream's view.endOfTextblock(dir): only treat
        // the cursor as leaving the block at its very start/end.
        let atEdge = dir < 0 ? start.parentOffset == 0 : start.parentOffset == start.parent.content.size
        guard atEdge, start.depth > 0 else { return false }
        mustMove = false
        start = state.doc.resolve(dir > 0 ? start.after() : start.before())
    }
    guard let found = GapCursor.findGapCursorFrom(start, dir, mustMove) else { return false }
    dispatch?(state.tr.setSelection(GapCursor(found)))
    return true
}
