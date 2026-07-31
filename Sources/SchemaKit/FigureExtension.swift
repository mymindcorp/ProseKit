import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands

// A captioned block — the document shape of HTML's `<figure>`/`<figcaption>`,
// which is how essentially every article on the web marks up an illustration.
// Without it, pasting one keeps the image and silently loses its caption.
//
// There is no Tiptap Figure extension to follow, so the node shape is taken
// from the HTML elements themselves: a `figure` holding one or more blocks and
// an optional trailing `figcaption`. Keeping the caption last (rather than
// allowing HTML's "first or last" placement) means one canonical document for a
// given figure, so serializing is unambiguous.
//
// NOT part of `starterKit`/`fullKit`: registering it changes the schema, and a
// document containing `figure` nodes can't be opened — or collaborated on — by a
// host whose schema lacks them. Add it explicitly:
//
//     let editor = Editor(extensions: fullKit() + figureExtensions())

/// A captioned block: content, then an optional caption.
public final class FigureExtension: NodeExtension {
    public let name = "figure"
    public init() {}

    public var nodeSpec: NodeSpec {
        // `figcaption` is deliberately in no group, so `block+` can't match it
        // and the caption can only ever be the last child.
        NodeSpec(content: "block+ figcaption?", group: "block",
                 defining: true, isolating: true)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "figure") }

    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let figure = ctx.nodeType,
              let caption = ctx.schema.nodes["figcaption"],
              let paragraph = ctx.schema.nodes["paragraph"] else { return [:] }
        return [
            "setFigure": setFigure(figure, caption),
            "unsetFigure": unsetFigure(figure, paragraph),
            "toggleFigure": toggleFigure(figure, caption, paragraph),
        ]
    }
}

/// A figure's caption — a textblock, so it edits like any other line of prose.
public final class FigcaptionExtension: NodeExtension {
    public let name = "figcaption"
    public init() {}

    public var nodeSpec: NodeSpec {
        NodeSpec(content: "inline*", selectable: false, defining: true, isolating: true)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "figcaption") }
}

/// The figure nodes, for a host that wants them: `fullKit() + figureExtensions()`.
public func figureExtensions() -> [any Extension] {
    [FigureExtension(), FigcaptionExtension()]
}

// MARK: - Commands

/// Wrap the blocks around the selection in a figure, and put the cursor in its
/// (empty) caption — the part a writer fills in next.
public func setFigure(_ figureType: NodeType, _ captionType: NodeType) -> Command {
    { state, dispatch, _ in
        guard ancestorDepth(state.selection.resolvedFrom, figureType) == nil,
              let range = state.selection.resolvedFrom.blockRange(state.selection.resolvedTo)
        else { return false }
        let parent = range.parent
        let blocks = (range.startIndex..<range.endIndex).map { parent.child($0) }
        guard !blocks.isEmpty, let caption = captionType.createAndFill(),
              let figure = try? figureType.create([:], content: Fragment.from(blocks + [caption]))
        else { return false }
        guard let dispatch else { return true }
        let tr = state.tr
        guard (try? tr.replaceWith(range.start, range.end, figure)) != nil else { return false }
        // figure(+1) → past its blocks → caption(+1).
        let body = blocks.reduce(0) { $0 + $1.nodeSize }
        let inCaption = min(range.start + 1 + body + 1, tr.doc.content.size)
        tr.setSelection(Selection.near(tr.doc.resolve(inCaption)))
        dispatch(tr.scrollIntoView())
        return true
    }
}

/// Unwrap the figure around the selection: its blocks are lifted out and its
/// caption becomes a trailing paragraph (dropped when empty).
public func unsetFigure(_ figureType: NodeType, _ paragraphType: NodeType) -> Command {
    { state, dispatch, _ in
        let from = state.selection.resolvedFrom
        guard let depth = ancestorDepth(from, figureType) else { return false }
        let figure = from.node(depth)
        var blocks: [Node] = []
        for i in 0..<figure.childCount {
            let child = figure.child(i)
            if child.type.name == "figcaption" {
                if child.content.size > 0,
                   let para = try? paragraphType.create([:], content: child.content) {
                    blocks.append(para)
                }
            } else {
                blocks.append(child)
            }
        }
        if blocks.isEmpty, let empty = paragraphType.createAndFill() { blocks = [empty] }
        guard let dispatch else { return true }
        let start = from.before(depth), end = from.after(depth)
        let tr = state.tr
        guard (try? tr.replaceWith(start, end, Fragment.from(blocks))) != nil else { return false }
        tr.setSelection(Selection.near(tr.doc.resolve(min(tr.mapping.map(from.pos), tr.doc.content.size))))
        dispatch(tr.scrollIntoView())
        return true
    }
}

/// Wrap the selection in a figure, or unwrap the one it's already in.
public func toggleFigure(_ figureType: NodeType, _ captionType: NodeType,
                         _ paragraphType: NodeType) -> Command {
    { state, dispatch, host in
        if isNodeActive(state, figureType) {
            return unsetFigure(figureType, paragraphType)(state, dispatch, host)
        }
        return setFigure(figureType, captionType)(state, dispatch, host)
    }
}
