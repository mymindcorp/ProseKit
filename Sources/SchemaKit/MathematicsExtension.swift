import Foundation
public import DocumentModel
import DocumentTransform
public import EditorStateKit
public import EditorCommands
public import EditorInputRules

// LaTeX math, matching Tiptap's Mathematics extension: two atom nodes — an
// `inlineMath` that sits in a line of text and a `blockMath` that owns its own
// row — each holding its source in a `latex` attribute. The renderer typesets
// that source (see the EditorMath module); the document only ever stores LaTeX.
//
// Written against Tiptap's documented API (node names, `latex` attribute,
// `data-type="inline-math"` / `"block-math"` HTML, and the insert/update/delete
// command set), not ported from its source.
//
// Deviation from Tiptap: `onClick` handlers are a DOM node-view concern and have
// no equivalent here — a host reacts to taps through the renderer instead. The
// `katexOptions` passthrough likewise lives on the renderer, not the schema.

/// An inline LaTeX formula — a leaf atom carrying its `latex` source.
public final class InlineMathExtension: NodeExtension {
    public let name = "inlineMath"
    public init() {}

    public var nodeSpec: NodeSpec {
        NodeSpec(
            group: "inline",
            inline: true,
            atom: true,
            attrs: ["latex": AttributeSpec(default: .string(""))],
            selectable: true,
            draggable: true,
            // Plain-text extraction (copy, search, `getText`) round-trips the
            // source in the same `$…$` form the input rule accepts.
            leafText: { node in "$" + (node.attrs["latex"]?.stringValue ?? "") + "$" })
    }
    // Serialized as `<span data-type="inline-math">` (see EditorSerialization).
    public var html: HTMLSpec { HTMLSpec(tag: "span") }

    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        return [
            "insertInlineMath": insertMath(type, latex: ""),
            "deleteInlineMath": deleteMath(type),
        ]
    }

    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.nodeType else { return [] }
        return [mathInputRule(type, pattern: "(?<!\\$)\\$([^$\\s][^$]*)\\$$")]
    }
}

/// A block-level LaTeX formula — a leaf atom that takes up its own row.
public final class BlockMathExtension: NodeExtension {
    public let name = "blockMath"
    public init() {}

    public var nodeSpec: NodeSpec {
        NodeSpec(
            group: "block",
            atom: true,
            attrs: ["latex": AttributeSpec(default: .string(""))],
            selectable: true,
            draggable: true,
            leafText: { node in "$$" + (node.attrs["latex"]?.stringValue ?? "") + "$$" })
    }
    // Serialized as `<div data-type="block-math">` (see EditorSerialization).
    public var html: HTMLSpec { HTMLSpec(tag: "div") }

    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        return [
            "insertBlockMath": insertMath(type, latex: ""),
            "deleteBlockMath": deleteMath(type),
        ]
    }

    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.nodeType else { return [] }
        // `$$…$$` only converts when it makes up the whole block, so a `$$` inside
        // a sentence stays text.
        return [mathInputRule(type, pattern: "^\\$\\$([^$]+)\\$\\$$")]
    }
}

/// The mathematics extensions (inline + block).
public func mathematicsExtensions() -> [any Extension] {
    [InlineMathExtension(), BlockMathExtension()]
}

// MARK: - Commands

/// Insert a math node with the given source. With `pos` nil the node replaces
/// the current selection; otherwise it's inserted at that document position.
public func insertMath(_ type: NodeType, latex: String, pos: Int? = nil) -> Command {
    { state, dispatch, _ in
        guard let node = try? type.create(["latex": .string(latex)]) else { return false }
        let tr = state.tr
        if let pos {
            guard pos >= 0, pos <= state.doc.content.size else { return false }
            guard (try? tr.insert(pos, node)) != nil else { return false }
        } else {
            tr.replaceSelectionWith(node)
        }
        guard containsInsertedNode(tr, node) else { return false }
        dispatch?(tr.scrollIntoView())
        return true
    }
}

/// Rewrite the `latex` of the math node at `pos` — or, with `pos` nil, of the
/// node the selection covers or sits directly after.
public func updateMath(_ type: NodeType, latex: String, pos: Int? = nil) -> Command {
    { state, dispatch, _ in
        guard let target = pos ?? mathNodePos(state, type) else { return false }
        guard let node = state.doc.nodeAt(target), node.type === type else { return false }
        if let dispatch, let tr = try? state.tr.setNodeAttribute(target, "latex", .string(latex)) {
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

/// Delete the math node at `pos` — or, with `pos` nil, the one the selection
/// covers or sits directly after.
public func deleteMath(_ type: NodeType, pos: Int? = nil) -> Command {
    { state, dispatch, _ in
        guard let target = pos ?? mathNodePos(state, type) else { return false }
        guard let node = state.doc.nodeAt(target), node.type === type else { return false }
        if let dispatch, let tr = try? state.tr.delete(target, target + node.nodeSize) {
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

/// The position of the math node the selection addresses: the node a
/// `NodeSelection` covers, else the one immediately before or after the cursor.
private func mathNodePos(_ state: EditorState, _ type: NodeType) -> Int? {
    if let sel = state.selection as? NodeSelection { return sel.node.type === type ? sel.from : nil }
    let from = state.selection.resolvedFrom
    if let after = from.nodeAfter, after.type === type { return from.pos }
    if state.selection.empty, let before = from.nodeBefore, before.type === type { return from.pos - before.nodeSize }
    return nil
}

/// Turn a typed `$…$` (or `$$…$$`) into a math node holding the enclosed source.
private func mathInputRule(_ type: NodeType, pattern: String) -> InputRule {
    // Never inside a code span: a literal `$x$` there must stay text, not
    // become a math node.
    InputRule(pattern, inCodeMark: false) { state, match, start, end in
        let from = state.doc.resolve(start)
        let to = state.doc.resolve(end)
        guard from.sameParent(to) else { return nil }
        if !type.isInline, from.parentOffset != 0 || end != from.end() { return nil }
        // Input-rule matching flattens inline atoms into placeholders. They
        // aren't LaTeX source and must not disappear into the replacement.
        var onlyText = true
        from.parent.nodesBetween(from.parentOffset, to.parentOffset, { node, _, _, _ in
            if !node.isText { onlyText = false }
            return false
        })
        guard onlyText else { return nil }
        guard let latex = match[1]?.trimmingCharacters(in: .whitespaces), !latex.isEmpty,
              let node = try? type.create(["latex": .string(latex)]) else { return nil }
        let tr = state.tr
        // A block formula replaces the textblock it was typed in, not just the
        // text — the rule only fires when the match fills the block, and
        // replacing the text alone left the emptied paragraph sitting above the
        // formula (Tiptap Mathematics 3.23.0).
        let (replaceFrom, replaceTo) = type.isInline ? (start, end) : (from.before(), from.after())
        guard (try? tr.replaceWith(replaceFrom, replaceTo, node)) != nil,
              containsInsertedNode(tr, node) else { return nil }
        if !type.isInline {
            // The paragraph the caret was in is gone, and the mapped selection
            // lands *on* the formula, where the next keystroke would replace
            // it. Put the caret where typing carries on: the start of the next
            // textblock, or — when the formula is the last thing in its parent
            // — a gap cursor after it, which typing turns into a paragraph.
            let after = tr.doc.resolve(min(replaceFrom + node.nodeSize, tr.doc.content.size))
            if let next = Selection.findFrom(after, 1, textOnly: true) {
                tr.setSelection(next)
            } else if GapCursor.valid(after) {
                tr.setSelection(GapCursor(after))
            }
        }
        return tr
    }
}

// MARK: - Migrating `$…$` text

/// The pattern `migrateMathStrings` looks for: a LaTeX expression wrapped in
/// single `$`s, with no `$` or newline inside.
public let mathMigrationPattern = "\\$([^$\\n]+)\\$"

/// Add steps to `tr` replacing every `$…$` run in the document with an
/// `inlineMath` node. Returns the transaction for chaining; unchanged when the
/// schema has no `inlineMath` or the document has no math strings.
///
/// Replacements run back-to-front so earlier positions stay valid.
@discardableResult
public func addMathMigrationSteps(_ doc: Node, _ tr: Transaction, pattern: String = mathMigrationPattern,
                                  schema: Schema) -> Transaction {
    guard let type = schema.nodes["inlineMath"],
          let regex = try? NSRegularExpression(pattern: pattern),
          regex.numberOfCaptureGroups >= 1 else { return tr }
    // (from, to, latex) for every match, in document order.
    var found: [(from: Int, to: Int, latex: String)] = []
    doc.descendants { node, pos, _, _ in
        // Skip code, where `$` is literal. Whether a formula fits depends on
        // its actual position, not the content match at the start of the block.
        guard node.isTextblock, !node.type.spec.code else { return true }
        let text = node.textBetween(0, node.content.size, blockSeparator: nil, leafText: "\u{fffc}")
        let ns = text as NSString
        // Regex ranges use UTF-16 and can split a grapheme. Only boundaries
        // represented by document positions can safely become replacements.
        var offsets: [Int: Int] = [0: 0]
        var utf16Offset = 0
        // Count positions within each source node. Concatenation can join
        // graphemes across mark boundaries, but their document sizes do not
        // change when the text is flattened for matching.
        node.descendants { child, childPos, _, _ in
            if let source = child.text {
                offsets[utf16Offset] = childPos
                for (offset, character) in source.enumerated() {
                    utf16Offset += String(character).utf16.count
                    offsets[utf16Offset] = childPos + offset + 1
                }
            } else if child.isLeaf {
                offsets[utf16Offset] = childPos
                utf16Offset += 1 // textBetween's U+FFFC placeholder
                offsets[utf16Offset] = childPos + child.nodeSize
            }
            return true
        }
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let capture = m.range(at: 1)
            guard capture.location != NSNotFound, m.range.length > 0,
                  let localFrom = offsets[m.range.location],
                  let localTo = offsets[NSMaxRange(m.range)] else { continue }
            let latex = ns.substring(with: capture)
            guard !latex.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // The flattened string uses placeholders for every inline leaf.
            // A match must consist entirely of prose text: never consume an
            // image, hard break, existing formula, or literal inline code.
            var eligible = true
            node.nodesBetween(localFrom, localTo, { child, _, _, _ in
                if !child.isText || child.marks.contains(where: { $0.type.spec.code }) { eligible = false }
                return false
            })
            guard eligible else { continue }
            found.append((from: pos + 1 + localFrom, to: pos + 1 + localTo, latex: latex))
        }
        return true
    }
    for match in found.reversed() {
        guard let node = try? type.create(["latex": .string(match.latex)]) else { continue }
        // An inline migration must fit at this exact location. Fitting may
        // otherwise discard the formula while still deleting its source text.
        _ = try? tr.step(ReplaceStep(match.from, match.to,
            Slice(content: Fragment.from(node), openStart: 0, openEnd: 0)))
    }
    return tr
}

// MARK: - Editor conveniences

public extension Editor {
    /// Insert an inline formula, replacing the selection (or at `pos`).
    @discardableResult
    func insertInlineMath(latex: String, at pos: Int? = nil) -> Bool {
        guard let type = schema.nodes["inlineMath"] else { return false }
        return run(SchemaKit.insertMath(type, latex: latex, pos: pos))
    }

    /// Rewrite the source of the addressed inline formula.
    @discardableResult
    func updateInlineMath(latex: String, at pos: Int? = nil) -> Bool {
        guard let type = schema.nodes["inlineMath"] else { return false }
        return run(SchemaKit.updateMath(type, latex: latex, pos: pos))
    }

    /// Delete the addressed inline formula.
    @discardableResult
    func deleteInlineMath(at pos: Int? = nil) -> Bool {
        guard let type = schema.nodes["inlineMath"] else { return false }
        return run(SchemaKit.deleteMath(type, pos: pos))
    }

    /// Insert a block formula, replacing the selection (or at `pos`).
    @discardableResult
    func insertBlockMath(latex: String, at pos: Int? = nil) -> Bool {
        guard let type = schema.nodes["blockMath"] else { return false }
        return run(SchemaKit.insertMath(type, latex: latex, pos: pos))
    }

    /// Rewrite the source of the addressed block formula.
    @discardableResult
    func updateBlockMath(latex: String, at pos: Int? = nil) -> Bool {
        guard let type = schema.nodes["blockMath"] else { return false }
        return run(SchemaKit.updateMath(type, latex: latex, pos: pos))
    }

    /// Delete the addressed block formula.
    @discardableResult
    func deleteBlockMath(at pos: Int? = nil) -> Bool {
        guard let type = schema.nodes["blockMath"] else { return false }
        return run(SchemaKit.deleteMath(type, pos: pos))
    }

    /// Convert every `$…$` run in the document into an `inlineMath` node — for
    /// documents written before the math nodes existed. Returns whether anything
    /// changed. Run it once the initial document is loaded (in a collaborative
    /// session, once the provider has synced).
    @discardableResult
    func migrateMathStrings(pattern: String = mathMigrationPattern) -> Bool {
        let tr = addMathMigrationSteps(state.doc, state.tr, pattern: pattern, schema: schema)
        guard tr.docChanged else { return false }
        dispatch(tr)
        return true
    }
}
