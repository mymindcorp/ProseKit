import DocumentModel

/// Build a `ReplaceStep` (or `ReplaceAroundStep`) that replaces `from..to` with
/// `slice`, fitting the slice's open ends to the surrounding document
/// structure. Returns `nil` when the replacement is a no-op.
public func replaceStep(_ doc: Node, _ from: Int, _ to: Int? = nil, _ slice: Slice = .empty) -> (any Step)? {
    let to = to ?? from
    if from == to && slice.size == 0 { return nil }
    let resolvedFrom = doc.resolve(from)
    let resolvedTo = doc.resolve(to)
    if fitsTrivially(resolvedFrom, resolvedTo, slice) {
        return ReplaceStep(from, to, slice)
    }
    return Fitter(resolvedFrom, resolvedTo, slice).fit()
}

func fitsTrivially(_ from: ResolvedPos, _ to: ResolvedPos, _ slice: Slice) -> Bool {
    slice.openStart == 0 && slice.openEnd == 0 && from.start() == to.start() &&
        from.parent.canReplace(from.index(), to.index(), replacement: slice.content)
}

private struct Frontier {
    var type: NodeType
    var match: ContentMatch
}

private struct Fittable {
    var sliceDepth: Int
    var frontierDepth: Int
    var parent: Node?
    var inject: Fragment?
    var wrap: [NodeType]?
}

/// A faithful port of ProseMirror's `Fitter` (prosemirror-transform/replace.ts).
final class Fitter {
    let from: ResolvedPos
    let to: ResolvedPos
    var unplaced: Slice
    private var frontier: [Frontier] = []
    private var placed: Fragment = .empty

    init(_ from: ResolvedPos, _ to: ResolvedPos, _ unplaced: Slice) {
        self.from = from
        self.to = to
        self.unplaced = unplaced
        for i in 0...from.depth {
            let node = from.node(i)
            frontier.append(Frontier(type: node.type, match: node.contentMatchAt(from.indexAfter(i))))
        }
        var i = from.depth
        while i > 0 {
            placed = Fragment.from(from.node(i).copy(content: placed))
            i -= 1
        }
    }

    var depth: Int { frontier.count - 1 }

    func fit() -> (any Step)? {
        while unplaced.size != 0 {
            if let fit = findFittable() {
                placeNodes(fit)
            } else if !openMore() {
                dropNode()
            }
        }
        let moveInline = mustMoveInline()
        let placedSize = placed.size - depth - from.depth
        guard let toPos = close(moveInline < 0 ? to : from.doc.resolve(moveInline)) else { return nil }

        var content = placed
        var openStart = from.depth
        var openEnd = toPos.depth
        while openStart != 0 && openEnd != 0 && content.childCount == 1 {
            content = content.firstChild!.content
            openStart -= 1
            openEnd -= 1
        }
        let slice = Slice(content: content, openStart: openStart, openEnd: openEnd)
        if moveInline > -1 {
            return ReplaceAroundStep(from.pos, moveInline, to.pos, to.end(), slice, placedSize)
        }
        if slice.size != 0 || from.pos != toPos.pos {
            return ReplaceStep(from.pos, toPos.pos, slice)
        }
        return nil
    }

    private func findFittable() -> Fittable? {
        var startDepth = unplaced.openStart
        var cur = unplaced.content
        var d = 0
        var openEnd = unplaced.openEnd
        while d < startDepth {
            let node = cur.firstChild!
            if cur.childCount > 1 { openEnd = 0 }
            if node.type.spec.isolating && openEnd <= d {
                startDepth = d
                break
            }
            cur = node.content
            d += 1
        }

        for pass in 1...2 {
            var sliceDepth = pass == 1 ? startDepth : unplaced.openStart
            while sliceDepth >= 0 {
                var parent: Node? = nil
                let fragment: Fragment
                if sliceDepth != 0 {
                    parent = contentAt(unplaced.content, sliceDepth - 1).firstChild
                    fragment = parent!.content
                } else {
                    fragment = unplaced.content
                }
                let first = fragment.firstChild
                var frontierDepth = depth
                while frontierDepth >= 0 {
                    let type = frontier[frontierDepth].type
                    let match = frontier[frontierDepth].match
                    var inject: Fragment? = nil
                    if pass == 1 {
                        if let first {
                            if match.matchType(first.type) != nil {
                                return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent, inject: nil, wrap: nil)
                            } else if let filled = match.fillBefore(Fragment.from(first), toEnd: false), filled.childCount != 0 {
                                inject = filled
                                return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent, inject: inject, wrap: nil)
                            }
                        } else if let parent, type.compatibleContent(parent.type) {
                            return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent, inject: nil, wrap: nil)
                        }
                    } else if let first, let wrap = match.findWrapping(first.type) {
                        return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent, inject: nil, wrap: wrap)
                    }
                    if let parent, match.matchType(parent.type) != nil { break }
                    frontierDepth -= 1
                }
                sliceDepth -= 1
            }
        }
        return nil
    }

    private func openMore() -> Bool {
        let content = unplaced.content
        let openStart = unplaced.openStart
        let openEnd = unplaced.openEnd
        let inner = contentAt(content, openStart)
        guard inner.childCount != 0, let first = inner.firstChild, !first.isLeaf else { return false }
        let newOpenEnd = Swift.max(openEnd, inner.size + openStart >= content.size - openEnd ? openStart + 1 : 0)
        unplaced = Slice(content: content, openStart: openStart + 1, openEnd: newOpenEnd)
        return true
    }

    private func dropNode() {
        let content = unplaced.content
        let openStart = unplaced.openStart
        let openEnd = unplaced.openEnd
        let inner = contentAt(content, openStart)
        if inner.childCount <= 1 && openStart > 0 {
            let openAtEnd = content.size - openStart <= openStart + inner.size
            unplaced = Slice(content: dropFromFragment(content, openStart - 1, 1),
                             openStart: openStart - 1,
                             openEnd: openAtEnd ? openStart - 1 : openEnd)
        } else {
            unplaced = Slice(content: dropFromFragment(content, openStart, 1), openStart: openStart, openEnd: openEnd)
        }
    }

    private func placeNodes(_ fit: Fittable) {
        while depth > fit.frontierDepth { closeFrontierNode() }
        if let wrap = fit.wrap {
            for t in wrap { openFrontierNode(t) }
        }

        let slice = unplaced
        let fragment = fit.parent != nil ? fit.parent!.content : slice.content
        let openStart = slice.openStart - fit.sliceDepth
        var taken = 0
        var add: [Node] = []
        var match = frontier[fit.frontierDepth].match
        let type = frontier[fit.frontierDepth].type
        if let inject = fit.inject {
            for i in 0..<inject.childCount { add.append(inject.child(i)) }
            match = match.matchFragment(inject) ?? match
        }
        var openEndCount = (fragment.size + fit.sliceDepth) - (slice.content.size - slice.openEnd)

        while taken < fragment.childCount {
            let next = fragment.child(taken)
            guard let matches = match.matchType(next.type) else { break }
            taken += 1
            if taken > 1 || openStart == 0 || next.content.size != 0 {
                match = matches
                add.append(closeNodeStart(next.mark(type.allowedMarks(next.marks)),
                                          taken == 1 ? openStart : 0,
                                          taken == fragment.childCount ? openEndCount : -1))
            }
        }
        let toEnd = taken == fragment.childCount
        if !toEnd { openEndCount = -1 }

        placed = addToFragment(placed, fit.frontierDepth, Fragment.from(add))
        frontier[fit.frontierDepth].match = match

        if toEnd && openEndCount < 0, let parent = fit.parent,
           parent.type === frontier[depth].type, frontier.count > 1 {
            closeFrontierNode()
        }

        var i = 0
        var curFrag = fragment
        while i < openEndCount {
            let node = curFrag.lastChild!
            frontier.append(Frontier(type: node.type, match: node.contentMatchAt(node.childCount)))
            curFrag = node.content
            i += 1
        }

        if !toEnd {
            unplaced = Slice(content: dropFromFragment(slice.content, fit.sliceDepth, taken),
                             openStart: slice.openStart, openEnd: slice.openEnd)
        } else if fit.sliceDepth == 0 {
            unplaced = .empty
        } else {
            unplaced = Slice(content: dropFromFragment(slice.content, fit.sliceDepth - 1, 1),
                             openStart: fit.sliceDepth - 1,
                             openEnd: openEndCount < 0 ? slice.openEnd : fit.sliceDepth - 1)
        }
    }

    private func mustMoveInline() -> Int {
        if !to.parent.isTextblock { return -1 }
        let top = frontier[depth]
        if !top.type.isTextblock || contentAfterFits(to, to.depth, top.type, top.match, false) == nil {
            return -1
        }
        if to.depth == depth, let level = findCloseLevel(to), level.depth == depth {
            return -1
        }
        var depthVar = to.depth
        var after = to.after(depthVar)
        while depthVar > 1 {
            depthVar -= 1
            if after == to.end(depthVar) { after += 1 } else { break }
        }
        return after
    }

    private func findCloseLevel(_ to: ResolvedPos) -> (depth: Int, fit: Fragment, move: ResolvedPos)? {
        var i = Swift.min(depth, to.depth)
        scan: while i >= 0 {
            let match = frontier[i].match
            let type = frontier[i].type
            let dropInner = i < to.depth && to.end(i + 1) == to.pos + (to.depth - (i + 1))
            guard let fit = contentAfterFits(to, i, type, match, dropInner) else { i -= 1; continue }
            var d = i - 1
            while d >= 0 {
                let m2 = frontier[d].match
                let t2 = frontier[d].type
                let matches = contentAfterFits(to, d, t2, m2, true)
                if matches == nil || matches!.childCount != 0 { i -= 1; continue scan }
                d -= 1
            }
            return (depth: i, fit: fit, move: dropInner ? to.doc.resolve(to.after(i + 1)) : to)
        }
        return nil
    }

    private func close(_ to: ResolvedPos) -> ResolvedPos? {
        guard let closeLevel = findCloseLevel(to) else { return nil }
        while depth > closeLevel.depth { closeFrontierNode() }
        if closeLevel.fit.childCount != 0 {
            placed = addToFragment(placed, closeLevel.depth, closeLevel.fit)
        }
        let movedTo = closeLevel.move
        var d = closeLevel.depth + 1
        while d <= movedTo.depth {
            let node = movedTo.node(d)
            let add = node.type.contentMatch.fillBefore(node.content, toEnd: true, startIndex: movedTo.index(d))
            openFrontierNode(node.type, attrs: node.attrs, content: add)
            d += 1
        }
        return movedTo
    }

    private func openFrontierNode(_ type: NodeType, attrs: Attrs = [:], content: Fragment? = nil) {
        frontier[depth].match = frontier[depth].match.matchType(type) ?? frontier[depth].match
        let node = (try? type.create(attrs, content: content ?? .empty)) ?? (try! type.create(attrs))
        placed = addToFragment(placed, depth, Fragment.from(node))
        frontier.append(Frontier(type: type, match: type.contentMatch))
    }

    private func closeFrontierNode() {
        let open = frontier.removeLast()
        if let add = open.match.fillBefore(.empty, toEnd: true), add.childCount != 0 {
            placed = addToFragment(placed, frontier.count, add)
        }
    }
}

// MARK: - Fragment helpers

private func dropFromFragment(_ fragment: Fragment, _ depth: Int, _ count: Int) -> Fragment {
    if depth == 0 { return fragment.cutByIndex(count, fragment.childCount) }
    let first = fragment.firstChild!
    return fragment.replaceChild(0, first.copy(content: dropFromFragment(first.content, depth - 1, count)))
}

private func addToFragment(_ fragment: Fragment, _ depth: Int, _ content: Fragment) -> Fragment {
    if depth == 0 { return fragment.append(content) }
    let last = fragment.lastChild!
    return fragment.replaceChild(fragment.childCount - 1, last.copy(content: addToFragment(last.content, depth - 1, content)))
}

private func contentAt(_ fragment: Fragment, _ depth: Int) -> Fragment {
    var frag = fragment
    var i = 0
    while i < depth {
        frag = frag.firstChild!.content
        i += 1
    }
    return frag
}

private func closeNodeStart(_ node: Node, _ openStart: Int, _ openEnd: Int) -> Node {
    if openStart <= 0 { return node }
    var frag = node.content
    if openStart > 1 {
        frag = frag.replaceChild(0, closeNodeStart(frag.firstChild!, openStart - 1, frag.childCount == 1 ? openEnd - 1 : 0))
    }
    if openStart > 0 {
        frag = (node.type.contentMatch.fillBefore(frag) ?? .empty).append(frag)
        if openEnd <= 0 {
            if let m = node.type.contentMatch.matchFragment(frag), let fill = m.fillBefore(.empty, toEnd: true) {
                frag = frag.append(fill)
            }
        }
    }
    return node.copy(content: frag)
}

private func contentAfterFits(_ to: ResolvedPos, _ depth: Int, _ type: NodeType, _ match: ContentMatch, _ open: Bool) -> Fragment? {
    let node = to.node(depth)
    let index = open ? to.indexAfter(depth) : to.index(depth)
    if index == node.childCount && !type.compatibleContent(node.type) { return nil }
    guard let fit = match.fillBefore(node.content, toEnd: true, startIndex: index) else { return nil }
    return invalidMarks(type, node.content, index) ? nil : fit
}

private func invalidMarks(_ type: NodeType, _ fragment: Fragment, _ start: Int) -> Bool {
    var i = start
    while i < fragment.childCount {
        if !type.allowsMarks(fragment.child(i).marks) { return true }
        i += 1
    }
    return false
}
