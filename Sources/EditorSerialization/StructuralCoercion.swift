import Foundation
import DocumentModel

// Fitting parsed nodes to what the schema will actually accept.
//
// HTML arrives in fragments. Copying two cells out of a table gives you `<td>`
// elements with no `<table>` around them; copying one bullet gives a bare
// `<li>`. Parsed literally, those produce a `tableCell` or a `listItem` sitting
// directly in the document — which no schema allows.
//
// `NodeType.create` computes attributes but doesn't check content, so building
// such a document succeeds silently and the damage only surfaces later, when
// something downstream assumes the document is well-formed. This pass fits the
// nodes to the container instead, so a fragment paste lands as a real list or a
// real table rather than as an invalid document or as nothing at all.

/// Fit `nodes` into content that `container` accepts.
///
/// Each node is placed by the first of these that works:
///
/// 1. **as-is**, when the content expression already allows it there;
/// 2. **wrapped**, in the shallowest chain of nodes that makes it legal — a
///    stray `listItem` becomes a list, a stray `tableCell` a table with a row;
/// 3. **unwrapped**, splicing its children in and fitting each of those, which
///    is what rescues content from a container that has no place here;
/// 4. **dropped**, only once there is nothing left inside it to keep.
///
/// Adjacent nodes that needed the same wrapping are merged, so two loose `<li>`s
/// become one list of two items rather than two lists.
func fitContent(_ nodes: [Node], into container: NodeType, schema: Schema) -> [Node] {
    var fitter = ContentFitter(container: container, schema: schema)
    for node in nodes { fitter.place(node, depth: 0) }
    return fitter.finish()
}

private struct ContentFitter {
    let container: NodeType
    let schema: Schema

    /// Placed nodes, with the wrapping each one needed (empty when it fitted as
    /// it was). The chain is kept so the next node can be merged into it.
    private var placed: [(node: Node, wrapping: [NodeType])] = []
    private var match: ContentMatch

    /// Unwrapping descends; a document nested past this is malformed by any
    /// measure, and the bound keeps a pathological one from recursing away.
    private static let maxUnwrapDepth = 32

    init(container: NodeType, schema: Schema) {
        self.container = container
        self.schema = schema
        self.match = container.contentMatch
    }

    mutating func place(_ node: Node, depth: Int) {
        // 1. Already legal here.
        if let next = match.matchType(node.type) {
            placed.append((node, []))
            match = next
            return
        }
        // 2. Legal once wrapped. `findWrapping` returns the shallowest chain, so
        //    a `listItem` picks up a list rather than a list inside a blockquote.
        if let wrapping = match.findWrapping(node.type), !wrapping.isEmpty {
            if mergeIntoPrevious(node, wrapping: wrapping) { return }
            if let wrapped = wrap(node, in: wrapping), let next = match.matchType(wrapped.type) {
                placed.append((wrapped, wrapping))
                match = next
                return
            }
        }
        // 3. Legal once whatever the container requires first is put in front of
        //    it. A list item must begin with a paragraph, so a block-level image
        //    at the start of one belongs after an empty paragraph rather than
        //    being dropped for arriving too early.
        if let fill = match.fillBefore(Fragment.from(node)), fill.childCount > 0,
           let next = match.matchFragment(fill)?.matchType(node.type) {
            for i in 0..<fill.childCount { placed.append((fill.child(i), [])) }
            placed.append((node, []))
            match = next
            return
        }
        // 4. Nothing fits, but its children might.
        guard depth < Self.maxUnwrapDepth, node.childCount > 0 else { return }
        for i in 0..<node.childCount { place(node.child(i), depth: depth + 1) }
    }

    /// Close the run, adding whatever the content expression still requires (an
    /// empty paragraph for a `block+` container that received nothing).
    func finish() -> [Node] {
        var out = placed.map(\.node)
        if let fill = match.fillBefore(.empty, toEnd: true) {
            for i in 0..<fill.childCount { out.append(fill.child(i)) }
        }
        return out
    }

    // MARK: - Wrapping

    /// Wrap `content` in `types`, outermost first.
    private func wrap(_ content: Fragment, in types: [NodeType]) -> Node? {
        var fragment = content
        for type in types.reversed() {
            guard let node = (try? type.createChecked([:], content: fragment))
                    ?? type.createAndFill([:], content: fragment) else { return nil }
            fragment = Fragment.from(node)
        }
        return fragment.firstChild
    }

    private func wrap(_ node: Node, in types: [NodeType]) -> Node? {
        wrap(Fragment.from(node), in: types)
    }

    /// Fold `node` into the previously placed node when that one needed exactly
    /// the same wrapping — two loose `<li>`s belong in one list, and two loose
    /// `<td>`s in one row.
    private mutating func mergeIntoPrevious(_ node: Node, wrapping: [NodeType]) -> Bool {
        guard let last = placed.last, last.wrapping.count == wrapping.count,
              zip(last.wrapping, wrapping).allSatisfy({ $0 === $1 }) else { return false }
        // Both were built as the same chain around their content, so merging is
        // concatenating what sits at the bottom of it and rebuilding.
        let levels = wrapping.count - 1
        guard let existing = innermostContent(last.node, levels: levels),
              let innermost = wrapping.last,
              innermost.contentMatch.matchFragment(existing.append(Fragment.from(node)))?.validEnd == true,
              let merged = wrap(existing.append(Fragment.from(node)), in: wrapping) else { return false }
        placed[placed.count - 1] = (merged, wrapping)
        return true
    }

    /// The content of the innermost wrapper, `levels` deep along a chain this
    /// fitter built (so each level has exactly the one child it was given).
    private func innermostContent(_ node: Node, levels: Int) -> Fragment? {
        guard levels > 0 else { return node.content }
        guard let child = node.firstChild else { return nil }
        return innermostContent(child, levels: levels - 1)
    }
}

/// Wrap inline content as a textblock, split around any block-level nodes so
/// each becomes its own sibling rather than an invalid child.
///
/// Both parsers can produce a block node in an inline position: HTML from an
/// `<img>` inside a `<p>`, Markdown from `![alt](src)` in a line of prose. In a
/// schema where images are inline nothing splits, and the run stays one block.
func textblockSplittingBlocks(_ inline: [Node], wrap: ([Node]) -> Node?) -> [Node] {
    guard inline.contains(where: { $0.type.isBlock }) else {
        return [wrap(inline)].compactMap { $0 } // no block nodes → a single textblock
    }
    var out: [Node] = []
    var run: [Node] = []
    func flush() {
        if !run.isEmpty, let block = wrap(run) { out.append(block) }
        run = []
    }
    for node in inline {
        if node.type.isBlock { flush(); out.append(node) } else { run.append(node) }
    }
    flush()
    return out
}

/// Drop the marks a node's parent won't accept, all the way down `nodes`.
///
/// `fitContent` above fits the *shape* of a paste; this fits its formatting.
/// `NodeType.create` computes attributes but checks neither content nor marks,
/// so a `heading` declared `marks: ""` accepted the bold text a parser handed
/// it and only failed at the document's own `check()` — throwing away the whole
/// paste over emphasis the schema merely didn't want. Losing the emphasis and
/// keeping the words is what every parser here would rather do, and it is what
/// the editor does when the same content arrives by any other route.
func conformMarks(_ nodes: [Node], in container: NodeType) -> [Node] {
    guard nodes.contains(where: { hasForbiddenMark($0, in: container) }) else { return nodes }
    return nodes.map { conformed($0, in: container) }
}

/// Whether anything in this subtree carries a mark its parent won't take.
///
/// Read-only and allocation-free, because it is the answer for nearly every
/// document that reaches here: asking first costs one walk, while rebuilding
/// unconditionally would copy every fragment in the paste to discover it had
/// nothing to change.
private func hasForbiddenMark(_ node: Node, in container: NodeType) -> Bool {
    if container.allowedMarks(node.marks).count != node.marks.count { return true }
    for i in 0 ..< node.content.childCount
    where hasForbiddenMark(node.content.child(i), in: node.type) { return true }
    return false
}

/// The rebuild, run only where `hasForbiddenMark` found something. `Fragment.from`
/// rejoins the text nodes a dropped mark leaves adjacent, so the result stays in
/// the canonical form the rest of the model expects.
private func conformed(_ node: Node, in container: NodeType) -> Node {
    var result = node
    let kept = container.allowedMarks(node.marks)
    if kept.count != node.marks.count { result = node.mark(kept) }
    let count = node.content.childCount
    if count > 0 {
        var kids: [Node] = []
        kids.reserveCapacity(count)
        var changed = false
        for i in 0 ..< count {
            let child = node.content.child(i)
            if hasForbiddenMark(child, in: node.type) {
                kids.append(conformed(child, in: node.type))
                changed = true
            } else {
                kids.append(child)
            }
        }
        if changed { result = result.copy(content: Fragment.from(kids)) }
    }
    return result
}
