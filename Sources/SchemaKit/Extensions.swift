import Foundation
public import DocumentModel
public import EditorStateKit
public import EditorCommands
public import EditorInputRules
import DocumentTransform

// The basic StarterKit extensions, using Tiptap node/mark names.

// MARK: - Core nodes

public final class DocumentExtension: NodeExtension {
    public let name = "doc"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "block+") }
}

public final class TextExtension: NodeExtension {
    public let name = "text"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(group: "inline") }
}

public final class ParagraphExtension: NodeExtension {
    public let name = "paragraph"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "inline*", group: "block") }
    public var html: HTMLSpec { HTMLSpec(tag: "p") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        return ["setParagraph": setBlockType(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        return ["Mod-Alt-0": setBlockType(type)]
    }
}

public final class HeadingExtension: NodeExtension {
    public let name = "heading"
    public let levels: [Int]
    public init(levels: [Int] = [1, 2, 3, 4, 5, 6]) { self.levels = levels }
    public var nodeSpec: NodeSpec {
        NodeSpec(content: "inline*", group: "block", attrs: ["level": AttributeSpec(default: .int(1))], defining: true)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "h", parseTags: ["h1", "h2", "h3", "h4", "h5", "h6"]) }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType, let para = ctx.schema.nodes["paragraph"] else { return [:] }
        var cmds: [String: Command] = [:]
        for level in levels {
            cmds["toggleHeading\(level)"] = toggleBlockType(type, para, ["level": .int(level)])
        }
        return cmds
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType, let para = ctx.schema.nodes["paragraph"] else { return [:] }
        var ks: [String: Command] = [:]
        for level in levels {
            ks["Mod-Alt-\(level)"] = toggleBlockType(type, para, ["level": .int(level)])
        }
        return ks
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.nodeType else { return [] }
        return levels.filter { (1...6).contains($0) }.map { level in
            textblockTypeInputRule("^(#{\(level)})\\s$", type) { _ in
                ["level": .int(level)]
            }
        }
    }
}

public final class BlockquoteExtension: NodeExtension {
    public let name = "blockquote"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "block+", group: "block", defining: true) }
    public var html: HTMLSpec { HTMLSpec(tag: "blockquote") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        return ["toggleBlockquote": toggleWrap(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        var shortcuts: [String: Command] = ["Mod-Shift-b": toggleWrap(type)]
        if let paragraph = ctx.schema.nodes["paragraph"] {
            // Shift-Enter exits the quote into a fresh paragraph after it.
            shortcuts["Shift-Enter"] = exitToParagraph(type, paragraph)
        }
        return shortcuts
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.nodeType else { return [] }
        return [wrappingInputRule("^\\s*>\\s$", type)]
    }
}

/// Exit the enclosing block of `blockType` (code block / blockquote): insert an
/// empty paragraph immediately after it and place the cursor there. No-op (false)
/// when the selection isn't inside such a block, so it can chain with the
/// default Shift-Enter (hard break).
func exitToParagraph(_ blockType: NodeType, _ paragraphType: NodeType) -> Command {
    { state, dispatch, _ in
        let after: Int
        if let selected = state.selection as? NodeSelection,
           selected.node.type.name == "codeBlock" || selected.node.type.name == "blockquote" {
            // Node selections resolve outside the selected block. Prefer it
            // over an enclosing quote, and let its own shortcut handle exit.
            guard selected.node.type === blockType else { return false }
            after = selected.to
        } else {
            let from = state.selection.resolvedFrom
            var depth = from.depth
            while depth > 0, from.node(depth).type !== blockType {
                // A shortcut for an outer quote must yield to the inner code
                // block's exit command, regardless of extension registration order.
                let name = from.node(depth).type.name
                if name == "codeBlock" || name == "blockquote" { return false }
                depth -= 1
            }
            guard depth > 0, from.node(depth).type === blockType else { return false }
            after = from.after(depth)
        }
        guard let paragraph = paragraphType.createAndFill() else { return false }
        let tr = state.tr
        // Exit immediately after this block, or decline. Fitting may discard
        // or move a forbidden paragraph, making the requested caret invalid.
        guard (try? tr.step(ReplaceStep(after, after,
            Slice(content: Fragment.from(paragraph), openStart: 0, openEnd: 0)))) != nil else { return false }
        tr.setSelection(Selection.near(tr.doc.resolve(after + 1)))
        dispatch?(tr.scrollIntoView())
        return true
    }
}

public final class CodeBlockExtension: NodeExtension {
    public let name = "codeBlock"
    public init() {}
    public var nodeSpec: NodeSpec {
        // `language` is consumed by the renderer's syntax-highlighting hook.
        NodeSpec(content: "text*", marks: "", group: "block",
                 attrs: ["language": AttributeSpec(default: .null)], code: true, defining: true)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "pre") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType, let para = ctx.schema.nodes["paragraph"] else { return [:] }
        return ["toggleCodeBlock": toggleBlockType(type, para)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType, let para = ctx.schema.nodes["paragraph"] else { return [:] }
        return [
            "Mod-Alt-c": toggleBlockType(type, para),
            // Indent/outdent inside a code block; falls through (returns false)
            // elsewhere so list/table Tab handling still applies.
            "Tab": indentCodeBlock(type),
            "Shift-Tab": outdentCodeBlock(type),
            // Shift-Enter exits the code block into a fresh paragraph after it.
            "Shift-Enter": exitToParagraph(type, para),
        ]
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.nodeType else { return [] }
        // Typing the third backtick at the start of a block turns it into a code block.
        return [textblockTypeInputRule("^```$", type)]
    }
}

private let codeBlockIndent = "  " // two spaces

/// Insert indentation at the cursor when it sits in a code block.
private func indentCodeBlock(_ type: NodeType) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        guard sel.empty, sel.resolvedFrom.parent.type === type else { return false }
        if let dispatch, let tr = try? state.tr.insertText(codeBlockIndent, sel.from, sel.to) {
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

/// Remove up to one indent level from the start of the current line in a code block.
private func outdentCodeBlock(_ type: NodeType) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        let from = sel.resolvedFrom
        guard sel.empty, from.parent.type === type else { return false }
        let blockStart = from.start()
        let before = state.doc.textBetween(blockStart, sel.from)
        let lineStartOffset = before.lastIndex(where: { $0.isNewline }).map { before.distance(from: before.startIndex, to: before.index(after: $0)) } ?? 0
        let lineStart = blockStart + lineStartOffset
        let probe = state.doc.textBetween(lineStart, min(lineStart + codeBlockIndent.count, from.end()))
        var remove = 0
        for ch in probe { if ch == " " { remove += 1 } else { break } }
        if remove == 0, probe.first == "\t" { remove = 1 }
        guard remove > 0 else { return false }
        if let dispatch, let tr = try? state.tr.delete(lineStart, lineStart + remove) {
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

public final class HorizontalRuleExtension: NodeExtension {
    public let name = "horizontalRule"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(group: "block") }
    public var html: HTMLSpec { HTMLSpec(tag: "hr") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        return ["setHorizontalRule": { state, dispatch, _ in
            guard let node = try? type.create() else { return false }
            let tr = state.tr.replaceSelectionWith(node)
            guard containsInsertedNode(tr, node) else { return false }
            dispatch?(tr.scrollIntoView())
            return true
        }]
    }
}

public final class HardBreakExtension: NodeExtension {
    public let name = "hardBreak"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(group: "inline", inline: true, selectable: false) }
    public var html: HTMLSpec { HTMLSpec(tag: "br") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        return ["setHardBreak": setHardBreak(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        return ["Shift-Enter": setHardBreak(type)]
    }
    private func setHardBreak(_ type: NodeType) -> Command {
        { state, dispatch, _ in
            guard let node = try? type.create() else { return false }
            let tr = state.tr.replaceSelectionWith(node, inheritMarks: false)
            guard containsInsertedNode(tr, node) else { return false }
            dispatch?(tr.scrollIntoView())
            return true
        }
    }
}

// MARK: - Lists

public final class ListItemExtension: NodeExtension {
    public let name = "listItem"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "paragraph block*", defining: true) }
    public var html: HTMLSpec { HTMLSpec(tag: "li") }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let item = ctx.nodeType else { return [:] }
        return [
            "Enter": splitListItem(item),
            "Tab": listItemShortcut(item, sinkListItem(item)),
            "Shift-Tab": listItemShortcut(item, liftListItem(item)),
        ]
    }
}

public final class BulletListExtension: NodeExtension {
    public let name = "bulletList"
    public init() {}
    /// `tight` records how the list was written: a tight list has no blank
    /// lines between its items, and renders without a paragraph inside each
    /// one. Markdown makes the distinction and HTML shows it, so the document
    /// has to carry it or a round trip loses it.
    public var nodeSpec: NodeSpec {
        NodeSpec(content: "listItem+", group: "block",
                 attrs: ["tight": AttributeSpec(default: .bool(false))])
    }
    public var html: HTMLSpec { HTMLSpec(tag: "ul") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType, let item = ctx.schema.nodes["listItem"] else { return [:] }
        return ["toggleBulletList": toggleList(type, item)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType, let item = ctx.schema.nodes["listItem"] else { return [:] }
        return ["Mod-Shift-8": toggleList(type, item)]
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.nodeType else { return [] }
        return [wrappingInputRule("^\\s*([-+*])\\s$", type)]
    }
}

public final class OrderedListExtension: NodeExtension {
    public let name = "orderedList"
    public init() {}
    public var nodeSpec: NodeSpec {
        NodeSpec(content: "listItem+", group: "block",
                 attrs: ["order": AttributeSpec(default: .int(1)),
                         "tight": AttributeSpec(default: .bool(false))])
    }
    public var html: HTMLSpec { HTMLSpec(tag: "ol") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType, let item = ctx.schema.nodes["listItem"] else { return [:] }
        return ["toggleOrderedList": toggleList(type, item)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType, let item = ctx.schema.nodes["listItem"] else { return [:] }
        return ["Mod-Shift-7": toggleList(type, item)]
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.nodeType else { return [] }
        return [InputRule("^(\\d+)\\.\\s$") { state, match, start, end in
            guard let digits = match[1], let order = Int(digits) else { return nil }
            let tr = state.tr
            guard (try? tr.delete(start, end)) != nil,
                  let range = tr.doc.resolve(start).blockRange(),
                  let wrapping = findWrappingForRange(range, type, ["order": .int(order)]),
                  (try? tr.wrap(range, wrapping)) != nil else { return nil }
            // Join only when the typed number continues the preceding list.
            // A restart or another starting number belongs to a separate list.
            if start > 0, let before = tr.doc.resolve(start - 1).nodeBefore,
               before.type === type, canJoin(tr.doc, start - 1) {
                let next = (before.attrs["order"]?.intValue ?? 1).addingReportingOverflow(before.childCount)
                if !next.overflow, next.partialValue == order {
                    _ = try? tr.join(start - 1)
                }
            }
            return tr
        }]
    }
}

// MARK: - Marks

public final class BoldExtension: MarkExtension {
    public let name = "bold"
    public init() {}
    public var markSpec: MarkSpec { MarkSpec() }
    public var html: HTMLSpec { HTMLSpec(tag: "strong", parseTags: ["b"]) }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["toggleBold": toggleMark(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["Mod-b": toggleMark(type)]
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.markType else { return [] }
        return [markInputRule("(?:^|\\s)(\\*\\*(?<text>[^*]+)\\*\\*)$", type), markInputRule("(?:^|\\s)(__([^_]+)__)$", type)]
    }
}

public final class ItalicExtension: MarkExtension {
    public let name = "italic"
    public init() {}
    public var markSpec: MarkSpec { MarkSpec() }
    public var html: HTMLSpec { HTMLSpec(tag: "em", parseTags: ["i"]) }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["toggleItalic": toggleMark(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["Mod-i": toggleMark(type)]
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.markType else { return [] }
        return [markInputRule("(?:^|\\s)(\\*([^*]+)\\*)$", type), markInputRule("(?:^|\\s)(_([^_]+)_)$", type)]
    }
}

public final class StrikeExtension: MarkExtension {
    public let name = "strike"
    public init() {}
    public var markSpec: MarkSpec { MarkSpec() }
    public var html: HTMLSpec { HTMLSpec(tag: "s", parseTags: ["del", "strike"]) }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["toggleStrike": toggleMark(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["Mod-Shift-s": toggleMark(type)]
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.markType else { return [] }
        return [markInputRule("(?:~~)([^~]+)(?:~~)$", type)]
    }
}

public final class UnderlineExtension: MarkExtension {
    public let name = "underline"
    public init() {}
    public var markSpec: MarkSpec { MarkSpec() }
    public var html: HTMLSpec { HTMLSpec(tag: "u") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["toggleUnderline": toggleMark(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["Mod-u": toggleMark(type)]
    }
}

public final class HighlightExtension: MarkExtension {
    public let name = "highlight"
    public init() {}
    /// `color` is a named highlight style (e.g. "yellow", "green"); nil uses the
    /// theme's default highlight color.
    public var markSpec: MarkSpec { MarkSpec(attrs: ["color": AttributeSpec(default: .null)]) }
    public var html: HTMLSpec { HTMLSpec(tag: "mark") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["toggleHighlight": toggleMark(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["Mod-Shift-h": toggleMark(type)]
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.markType else { return [] }
        return [markInputRule("(?:==)([^=]+)(?:==)$", type)]
    }
}

/// Apply a highlight of a specific named color over the selection (replacing any
/// existing highlight there).
public func setHighlight(_ markType: MarkType, color: String?) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        if sel.empty { return false }
        let tr = state.tr
        var attrs: Attrs = [:]
        if let color { attrs["color"] = .string(color) }
        for range in sel.ranges {
            _ = try? tr.removeMark(range.from.pos, range.to.pos, markType)
            _ = try? tr.addMark(range.from.pos, range.to.pos, markType.create(attrs))
        }
        guard sel.ranges.contains(where: { tr.doc.rangeHasMark($0.from.pos, $0.to.pos, markType) }) else { return false }
        dispatch?(tr.scrollIntoView())
        return true
    }
}

public final class CodeExtension: MarkExtension {
    public let name = "code"
    public init() {}
    public var markSpec: MarkSpec { MarkSpec(excludes: "_", code: true) }
    public var html: HTMLSpec { HTMLSpec(tag: "code") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["toggleCode": toggleMark(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["Mod-e": toggleMark(type)]
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.markType else { return [] }
        return [markInputRule("(?:`)([^`]+)(?:`)$", type)]
    }
}

public final class LinkExtension: MarkExtension {
    public let name = "link"
    public init() {}
    public var markSpec: MarkSpec {
        MarkSpec(attrs: ["href": AttributeSpec(default: .null), "title": AttributeSpec(default: .null)], inclusive: false)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "a") }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.markType else { return [] }
        // Autolink: typing whitespace right after a URL turns it into a link.
        // The handler must re-insert the typed character (rules replace the
        // default insertion).
        return [InputRule("(?:^|\\s)((?:https?://|www\\.)[^\\s]+)(\\s)$", inCodeMark: false) { state, match, start, end in
            guard let url = match[1], let typed = match[2] else { return nil }
            let full = match[0] ?? ""
            guard let urlRange = full.range(of: url) else { return nil }
            let from = start + full.distance(from: full.startIndex, to: urlRange.lowerBound)
            let to = from + url.count
            guard to == end else { return nil }
            // Input-rule matching substitutes placeholders for inline nodes.
            // Those placeholders are not characters in a URL destination.
            var onlyText = true
            state.doc.nodesBetween(from, to, { node, _, _, _ in
                if node.isInline && !node.isText { onlyText = false }
                return true
            })
            guard onlyText else { return nil }
            let href = url.hasPrefix("www.") ? "https://" + url : url
            let tr = state.tr
            _ = try? tr.addMark(from, to, type.create(["href": .string(href)]))
            _ = try? tr.insertText(typed, end)
            return tr
        }]
    }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["unsetLink": unsetLink(type)]
    }
}

/// Add (or replace) a link over the selection with the given href.
public func setLink(_ markType: MarkType, href: String, title: String? = nil) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        if sel.empty { return false }
        let tr = state.tr
        var attrs: Attrs = ["href": .string(href)]
        if let title { attrs["title"] = .string(title) }
        for range in sel.ranges {
            _ = try? tr.removeMark(range.from.pos, range.to.pos, markType) // replace any existing link
            _ = try? tr.addMark(range.from.pos, range.to.pos, markType.create(attrs))
        }
        guard sel.ranges.contains(where: { tr.doc.rangeHasMark($0.from.pos, $0.to.pos, markType) }) else { return false }
        dispatch?(tr.scrollIntoView())
        return true
    }
}

/// Remove any link mark over the selection.
public func unsetLink(_ markType: MarkType) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        if sel.empty { return false }
        if let dispatch {
            let tr = state.tr
            for range in sel.ranges {
                _ = try? tr.removeMark(range.from.pos, range.to.pos, markType)
            }
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

// MARK: - Subscript / Superscript

public final class SubscriptExtension: MarkExtension {
    public let name = "subscript"
    public init() {}
    // Subscript and superscript are mutually exclusive (text can't be both).
    public var markSpec: MarkSpec { MarkSpec(excludes: "subscript superscript") }
    public var html: HTMLSpec { HTMLSpec(tag: "sub") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["toggleSubscript": toggleMark(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["Mod-,": toggleMark(type)]
    }
}

public final class SuperscriptExtension: MarkExtension {
    public let name = "superscript"
    public init() {}
    public var markSpec: MarkSpec { MarkSpec(excludes: "subscript superscript") }
    public var html: HTMLSpec { HTMLSpec(tag: "sup") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["toggleSuperscript": toggleMark(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["Mod-.": toggleMark(type)]
    }
}

// MARK: - Text / background color

public final class TextColorExtension: MarkExtension {
    public let name = "textColor"
    public init() {}
    /// `color` is a CSS color string (named or hex) applied as the text's
    /// foreground; nil renders the default text color.
    public var markSpec: MarkSpec { MarkSpec(attrs: ["color": AttributeSpec(default: .null)]) }
    public var html: HTMLSpec { HTMLSpec(tag: "span") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["unsetTextColor": unsetColor(type)]
    }
}

public final class BackgroundColorExtension: MarkExtension {
    public let name = "backgroundColor"
    public init() {}
    /// `color` is a CSS color string painted behind the text.
    public var markSpec: MarkSpec { MarkSpec(attrs: ["color": AttributeSpec(default: .null)]) }
    public var html: HTMLSpec { HTMLSpec(tag: "span") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["unsetBackgroundColor": unsetColor(type)]
    }
}

/// Apply a color mark (text or background) of the given CSS color over the
/// selection, replacing any existing color of that type. A nil color removes it.
public func setColor(_ markType: MarkType, _ color: String?) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        if sel.empty { return false }
        let tr = state.tr
        for range in sel.ranges {
            _ = try? tr.removeMark(range.from.pos, range.to.pos, markType)
            if let color { _ = try? tr.addMark(range.from.pos, range.to.pos, markType.create(["color": .string(color)])) }
        }
        guard color == nil || sel.ranges.contains(where: { tr.doc.rangeHasMark($0.from.pos, $0.to.pos, markType) }) else { return false }
        dispatch?(tr.scrollIntoView())
        return true
    }
}

/// Remove a color mark over the selection.
public func unsetColor(_ markType: MarkType) -> Command { setColor(markType, nil) }

// MARK: - StarterKit

/// A reasonable default set of basic extensions, mirroring Tiptap's StarterKit.
public func starterKit() -> [any Extension] {
    [
        DocumentExtension(),
        ParagraphExtension(),
        TextExtension(),
        HeadingExtension(),
        BlockquoteExtension(),
        CodeBlockExtension(),
        HorizontalRuleExtension(),
        HardBreakExtension(),
        BulletListExtension(),
        OrderedListExtension(),
        ListItemExtension(),
        BoldExtension(),
        ItalicExtension(),
        StrikeExtension(),
        UnderlineExtension(),
        HighlightExtension(),
        SubscriptExtension(),
        SuperscriptExtension(),
        TextColorExtension(),
        BackgroundColorExtension(),
        CodeExtension(),
        LinkExtension(),
        TypographyExtension(),
    ]
}

/// Contributes the gap cursor plugin: arrow keys can place a caret in "gaps"
/// (between two tables, before a leading table, after a trailing hr) where no
/// text position exists; typing there materializes a paragraph.
public final class GapCursorExtension: Extension {
    public let name = "gapCursor"
    public init() {}
    public func plugins(_ ctx: ExtensionContext) -> [Plugin] { [gapCursor()] }
}

/// The starter kit plus tables, task lists, collapsible details, LaTeX math,
/// images (both `image` and the always-full-width `imageBlock`), wiki-links,
/// mentions, search, the slash menu, collaborator cursors, the gap cursor, and
/// suggestion mode.
/// Pass the `*AsyncSuggestions` variants for a DB/index-backed `[[` or `@` lookup
/// (each takes precedence over its synchronous counterpart).
public func fullKit(wikiLinkSuggestions: (@Sendable (String) -> [String])? = nil,
                    wikiLinkAsyncSuggestions: (@Sendable (String) async -> [String])? = nil,
                    mentionSuggestions: (@Sendable (String) -> [String])? = nil,
                    mentionAsyncSuggestions: (@Sendable (String) async -> [String])? = nil,
                    tableOptions: TableOptions = TableOptions(),
                    taskListOptions: TaskListOptions = TaskListOptions()) -> [any Extension] {
    starterKit() + tableExtensions(options: tableOptions) + taskListExtensions(options: taskListOptions)
        + detailsExtensions()
        + mathematicsExtensions()
        + [ImageExtension(), imageBlockExtension(), WikiLinkExtension(suggestions: wikiLinkSuggestions,
                                               asyncSuggestions: wikiLinkAsyncSuggestions),
           MentionExtension(suggestions: mentionSuggestions,
                            asyncSuggestions: mentionAsyncSuggestions), SearchExtension(),
           SlashMenuExtension(), CollabCursorExtension(), GapCursorExtension(),
           SuggestionModeExtension()]
}
