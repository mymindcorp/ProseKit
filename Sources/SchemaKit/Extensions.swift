import DocumentModel
import EditorStateKit
import EditorCommands
import EditorInputRules

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
        let maxLevel = levels.max() ?? 6
        return [textblockTypeInputRule("^(#{1,\(maxLevel)})\\s$", type) { m in
            ["level": .int((m[1] ?? "").count)]
        }]
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
        let from = state.selection.resolvedFrom
        var depth = from.depth
        while depth > 0, from.node(depth).type !== blockType { depth -= 1 }
        guard depth > 0, from.node(depth).type === blockType, let paragraph = paragraphType.createAndFill() else { return false }
        if let dispatch {
            let after = from.after(depth)
            let tr = state.tr
            _ = try? tr.insert(after, paragraph)
            tr.setSelection(TextSelection.create(tr.doc, after + 1))
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

public final class CodeBlockExtension: NodeExtension {
    public let name = "codeBlock"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true) }
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
        let lineStartOffset = before.lastIndex(of: "\n").map { before.distance(from: before.startIndex, to: before.index(after: $0)) } ?? 0
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
            dispatch?(state.tr.replaceSelectionWith((try? type.create())!).scrollIntoView())
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
            dispatch?(state.tr.replaceSelectionWith((try? type.create())!, inheritMarks: false).scrollIntoView())
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
            "Tab": sinkListItem(item),
            "Shift-Tab": liftListItem(item),
        ]
    }
}

public final class BulletListExtension: NodeExtension {
    public let name = "bulletList"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "listItem+", group: "block") }
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
    public var nodeSpec: NodeSpec { NodeSpec(content: "listItem+", group: "block", attrs: ["order": AttributeSpec(default: .int(1))]) }
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
        return [wrappingInputRule("^(\\d+)\\.\\s$", type)]
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
    public var markSpec: MarkSpec { MarkSpec() }
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

public final class CodeExtension: MarkExtension {
    public let name = "code"
    public init() {}
    public var markSpec: MarkSpec { MarkSpec(excludes: "_") }
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
        return [InputRule("(?:^|\\s)((?:https?://|www\\.)[^\\s]+)(\\s)$") { state, match, start, end in
            guard let url = match[1], let typed = match[2] else { return nil }
            let full = match[0] ?? ""
            guard let urlRange = full.range(of: url) else { return nil }
            let from = start + full.distance(from: full.startIndex, to: urlRange.lowerBound)
            let to = from + url.count
            guard to == end else { return nil }
            let href = url.hasPrefix("www.") ? "https://" + url : url
            let tr = state.tr
            _ = try? tr.addMark(from, to, type.create(["href": .string(href)]))
            _ = try? tr.insertText(typed, end)
            return tr
        }]
    }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.markType else { return [:] }
        return ["unsetLink": { state, dispatch, _ in
            let sel = state.selection
            if sel.empty { return false }
            if let dispatch {
                let tr = state.tr
                _ = try? tr.removeMark(sel.from, sel.to, type)
                dispatch(tr.scrollIntoView())
            }
            return true
        }]
    }
}

// MARK: - StarterKit

/// A reasonable default set of basic extensions, mirroring Tiptap's StarterKit.
public func starterKit() -> [Extension] {
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

/// The starter kit plus tables, task lists, images, wiki-links, and search.
public func fullKit(wikiLinkSuggestions: ((String) -> [String])? = nil,
                    mentionSuggestions: ((String) -> [String])? = nil) -> [Extension] {
    starterKit() + tableExtensions() + taskListExtensions()
        + [ImageExtension(), WikiLinkExtension(suggestions: wikiLinkSuggestions),
           MentionExtension(suggestions: mentionSuggestions), SearchExtension(),
           SlashMenuExtension(), CollabCursorExtension(), GapCursorExtension(),
           SuggestionModeExtension()]
}
