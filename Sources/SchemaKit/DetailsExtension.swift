public import DocumentModel
import DocumentTransform
public import EditorStateKit
public import EditorCommands

// Collapsible sections, matching Tiptap's Details extension: a `details` node
// holding exactly a `detailsSummary` (the always-visible title) and a
// `detailsContent` (the collapsible body) — the document shape of HTML's
// `<details>`/`<summary>`.
//
// Deviation from Tiptap: the open/closed state is always a document attribute
// (`open`) rather than view-only state behind Tiptap's `persist` option, since
// there is no DOM node view here to hold it — the renderer reads the attribute.

public final class DetailsExtension: NodeExtension {
    public let name = "details"
    public init() {}
    public var nodeSpec: NodeSpec {
        NodeSpec(content: "detailsSummary detailsContent", group: "block",
                 attrs: ["open": AttributeSpec(default: .bool(false))],
                 defining: true, isolating: true, allowGapCursor: false)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "details") }

    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let details = ctx.nodeType,
              let summary = ctx.schema.nodes["detailsSummary"],
              let content = ctx.schema.nodes["detailsContent"],
              let paragraph = ctx.schema.nodes["paragraph"] else { return [:] }
        return [
            "setDetails": setDetails(details, summary, content),
            "unsetDetails": unsetDetails(details, paragraph),
            "toggleDetails": toggleDetails(details, summary, content, paragraph),
            "toggleDetailsOpen": toggleDetailsOpen(details),
        ]
    }

    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let details = ctx.nodeType,
              let summary = ctx.schema.nodes["detailsSummary"],
              let content = ctx.schema.nodes["detailsContent"],
              let paragraph = ctx.schema.nodes["paragraph"] else { return [:] }
        return ["Mod-Alt-d": toggleDetails(details, summary, content, paragraph)]
    }
}

public final class DetailsSummaryExtension: NodeExtension {
    public let name = "detailsSummary"
    public init() {}
    public var nodeSpec: NodeSpec {
        NodeSpec(content: "inline*", selectable: false, defining: true, isolating: true)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "summary") }

    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let summary = ctx.nodeType,
              let details = ctx.schema.nodes["details"],
              let paragraph = ctx.schema.nodes["paragraph"] else { return [:] }
        return [
            // Enter never splits the summary — it opens the section and drops the
            // cursor into the body, like Tiptap's summary handling.
            "Enter": enterDetailsContent(summary, details),
            // Backspace at the very start of the summary unwraps the section.
            "Backspace": backspaceOutOfSummary(summary, details, paragraph),
        ]
    }
}

public final class DetailsContentExtension: NodeExtension {
    public let name = "detailsContent"
    public init() {}
    public var nodeSpec: NodeSpec {
        NodeSpec(content: "block+", selectable: false, defining: true)
    }
    // Serialized as `<div data-type="detailsContent">` (see EditorSerialization).
    public var html: HTMLSpec { HTMLSpec(tag: "div") }
}

// MARK: - Commands

/// Wrap the selected block(s) in a collapsible `details` section: the blocks
/// become its content and the cursor lands in the (empty) summary. No-op when
/// the selection is already inside a `details`.
public func setDetails(_ detailsType: NodeType, _ summaryType: NodeType, _ contentType: NodeType) -> Command {
    { state, dispatch, _ in
        if isNodeActive(state, detailsType) { return false }
        let sel = state.selection
        guard let range = sel.resolvedFrom.blockRange(sel.resolvedTo) else { return false }
        let slice = state.doc.slice(range.start, range.end)
        // The selected blocks must be valid content for a `detailsContent`, so
        // build it with `createChecked`: `matchFragment` alone says the content
        // could still be *continued*, not that it is complete, and `create`
        // doesn't look at content at all. See the same note in `setFigure`.
        guard slice.openStart == 0, slice.openEnd == 0,
              let content = try? contentType.createChecked([:], content: slice.content),
              let summary = summaryType.createAndFill(),
              // A new section opens, so its content is visible right away.
              let details = try? detailsType.createChecked(["open": .bool(true)],
                                                           content: Fragment.from([summary, content]))
        else { return false }
        guard range.parent.canReplace(range.startIndex, range.endIndex, replacement: Fragment.from(details)) else { return false }
        guard let dispatch else { return true }
        let tr = state.tr
        guard (try? tr.step(ReplaceStep(range.start, range.end,
            Slice(content: Fragment.from(details), openStart: 0, openEnd: 0)))) != nil else { return false }
        // details(+1) → summary(+1) → its (empty) content.
        tr.setSelection(Selection.near(tr.doc.resolve(range.start + 2)))
        dispatch(tr.scrollIntoView())
        return true
    }
}

/// Unwrap the `details` section around the selection: its summary becomes a
/// leading paragraph (dropped when empty) and its content is lifted out.
public func unsetDetails(_ detailsType: NodeType, _ paragraphType: NodeType) -> Command {
    { state, dispatch, _ in
        guard let target = selectedNodeOrAncestor(state, detailsType) else { return false }
        let details = target.node
        guard details.childCount == 2 else { return false }
        let summary = details.child(0), content = details.child(1)
        var blocks: [Node] = []
        if summary.content.size > 0 {
            guard let para = try? paragraphType.createChecked([:], content: summary.content) else { return false }
            blocks.append(para)
        }
        for i in 0..<content.childCount { blocks.append(content.child(i)) }
        if blocks.isEmpty, let empty = paragraphType.createAndFill() { blocks = [empty] }
        let start = target.pos, end = target.pos + details.nodeSize
        let tr = state.tr
        guard (try? tr.step(ReplaceStep(start, end,
            Slice(content: Fragment.from(blocks), openStart: 0, openEnd: 0)))) != nil else { return false }
        // The replacement's map treats all inner text as deleted. For the
        // selection, map only the wrappers that actually disappeared; the
        // summary's paragraph conversion preserves its content positions.
        let contentStart = start + 1 + summary.nodeSize
        let removed = summary.content.size > 0
            ? [start, 1, 0, contentStart, 1, 0, end - 2, 2, 0]
            : [start, summary.nodeSize + 2, 0, end - 2, 2, 0]
        tr.setSelection(state.selection.map(tr.doc, StepMap(removed)))
        dispatch?(tr.scrollIntoView())
        return true
    }
}

/// Wrap the selection in a `details` section, or unwrap the one it's already in.
public func toggleDetails(_ detailsType: NodeType, _ summaryType: NodeType,
                          _ contentType: NodeType, _ paragraphType: NodeType) -> Command {
    { state, dispatch, host in
        if isNodeActive(state, detailsType) {
            return unsetDetails(detailsType, paragraphType)(state, dispatch, host)
        }
        return setDetails(detailsType, summaryType, contentType)(state, dispatch, host)
    }
}

/// Flip the `open` attribute of the `details` node containing the selection.
public func toggleDetailsOpen(_ detailsType: NodeType) -> Command {
    { state, dispatch, _ in
        guard let target = selectedNodeOrAncestor(state, detailsType) else { return false }
        if let dispatch {
            let open = target.node.attrs["open"]?.boolValue ?? false
            if let tr = setDetailsOpen(state, pos: target.pos, open: !open) { dispatch(tr) }
        }
        return true
    }
}

/// Set the `open` attribute of the `details` node at a document position — the
/// renderer's disclosure-triangle action. Closing a section whose body holds the
/// selection also moves the cursor to the end of the summary, so the caret never
/// ends up in content the renderer no longer draws.
public func setDetailsOpen(_ state: EditorState, pos: Int, open: Bool) -> Transaction? {
    guard let node = state.doc.nodeAt(pos), node.type.name == "details",
          let tr = try? state.tr.setNodeAttribute(pos, "open", .bool(open)) else { return nil }
    if !open, node.childCount > 0 {
        let summaryEnd = pos + node.child(0).nodeSize // = pos + 1 + summarySize - 1
        let sel = state.selection
        let end = pos + node.nodeSize
        let anchorHidden = sel.anchor > summaryEnd && sel.anchor < end
        let headHidden = sel.head > summaryEnd && sel.head < end
        if anchorHidden || headHidden {
            tr.setSelection(Selection.near(tr.doc.resolve(summaryEnd), -1))
        }
    }
    return tr
}

/// Enter inside a summary: open the section and move the cursor to the start of
/// its content.
func enterDetailsContent(_ summaryType: NodeType, _ detailsType: NodeType) -> Command {
    { state, dispatch, _ in
        let from = state.selection.resolvedFrom
        guard from.parent.type === summaryType, let depth = ancestorDepth(from, detailsType) else { return false }
        if let dispatch {
            let detailsPos = from.before(depth)
            let tr = state.tr
            if !(from.node(depth).attrs["open"]?.boolValue ?? false) {
                _ = try? tr.setNodeAttribute(detailsPos, "open", .bool(true))
            }
            // Start before the first body block so `near` can select an atom
            // or descend into a textblock without skipping a leaf node.
            let contentStart = detailsPos + 1 + from.node(depth).child(0).nodeSize
            tr.setSelection(Selection.near(tr.doc.resolve(min(contentStart + 1, tr.doc.content.size))))
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

/// Backspace at the start of a summary unwraps the whole section.
func backspaceOutOfSummary(_ summaryType: NodeType, _ detailsType: NodeType, _ paragraphType: NodeType) -> Command {
    { state, dispatch, host in
        let sel = state.selection
        let from = sel.resolvedFrom
        guard sel.empty, from.parent.type === summaryType, from.parentOffset == 0 else { return false }
        return unsetDetails(detailsType, paragraphType)(state, dispatch, host)
    }
}


/// The details extensions (section + summary + content).
public func detailsExtensions() -> [any Extension] {
    [DetailsExtension(), DetailsSummaryExtension(), DetailsContentExtension()]
}
