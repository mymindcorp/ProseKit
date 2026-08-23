import Foundation
import DocumentModel
import DocumentTransform
public import EditorStateKit

/// One entry in the slash (`/`) command menu: a display title, search keywords,
/// and the named command to run when chosen.
public struct SlashCommandItem: Sendable, Equatable {
    public var title: String
    public var keywords: [String]
    public var command: String
    /// An SF Symbol name shown as the row's leading glyph.
    public var icon: String?
    /// A short description shown under the title.
    public var subtitle: String?
    public init(title: String, keywords: [String] = [], command: String, icon: String? = nil, subtitle: String? = nil) {
        self.title = title
        self.keywords = keywords
        self.command = command
        self.icon = icon
        self.subtitle = subtitle
    }

    /// Whether this item matches the typed query (over title + keywords).
    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return title.lowercased().contains(q) || keywords.contains { $0.lowercased().contains(q) }
    }
}

/// The active slash-menu query and the document range of the trigger (`/query`).
public struct SlashMenuState: Equatable {
    public var query: String
    public var from: Int   // position of the `/`
    public var to: Int     // the cursor
}

public let slashMenuKey = PluginKey<SlashMenuState?>("slashMenu")

/// Adds a `/` slash-command menu. Self-contained: it tracks the active query via
/// a plugin and exposes a `SuggestionSource` so the renderer drives the popup
/// generically.
public final class SlashMenuExtension: Extension {
    public let name = "slashMenu"
    /// The commands offered by the menu.
    public let commands: [SlashCommandItem]
    /// When true (default), `/` only opens the menu at the start of a line/block;
    /// when false it also opens after whitespace (Notion-style).
    public let atLineStart: Bool

    public init(commands: [SlashCommandItem] = defaultSlashCommands(), atLineStart: Bool = true) {
        self.commands = commands
        self.atLineStart = atLineStart
    }

    public func plugins(_ ctx: ExtensionContext) -> [Plugin] {
        let atLineStart = self.atLineStart
        return [Plugin(
            key: slashMenuKey.key,
            stateField: PluginStateField(
                initialize: { _, _ in Optional<SlashMenuState>.none as Any },
                apply: { _, _, _, newState in computeSlashMenu(newState, atLineStart: atLineStart) as Any }))]
    }

    public func suggestionSources(_ ctx: ExtensionContext) -> [any SuggestionSource] {
        [SlashSuggestionSource(commands: commands)]
    }
}

/// Drives the slash-menu popup from the tracked query + the configured commands.
@MainActor
final class SlashSuggestionSource: SuggestionSource {
    let commands: [SlashCommandItem]
    nonisolated init(commands: [SlashCommandItem]) { self.commands = commands }

    func context(_ editor: Editor) -> SuggestionContext? {
        editor.slashMenu.map { SuggestionContext(from: $0.from, to: $0.to, query: $0.query) }
    }
    func entries(_ query: String, _ editor: Editor) -> [SuggestionEntry] {
        guard let menu = editor.slashMenu else { return [] }
        // Capture the trigger range now: applying from a tap can move the caret
        // (and clear the live `slashMenu`) before the command runs.
        let from = menu.from, to = menu.to
        return commands.filter { $0.matches(query) }.map { item in
            SuggestionEntry(title: item.title, subtitle: item.subtitle, icon: item.icon) {
                $0.applySlashCommand(item, from: from, to: to)
            }
        }
    }
}

private func computeSlashMenu(_ state: EditorState, atLineStart: Bool) -> SlashMenuState? {
    guard let cursor = (state.selection as? TextSelection)?.cursor else { return nil }
    let parent = cursor.parent
    guard parent.isTextblock, !parent.type.spec.code else { return nil }
    // One character per inline leaf, so an offset into this string IS a document
    // offset. An atom occupies a single position but renders as its whole label
    // (a wiki-link's target, an image's alt), and counting those characters put
    // the trigger's `from` past the end of the document.
    let textBefore = parent.textBetween(0, cursor.parentOffset, leafText: "\u{fffc}")
    guard let slashRange = textBefore.range(of: "/", options: .backwards) else { return nil }
    let slashOffset = textBefore.distance(from: textBefore.startIndex, to: slashRange.lowerBound)
    if atLineStart {
        // The `/` must be the first character of the block.
        if slashOffset != 0 { return nil }
    } else if let charBefore = textBefore[..<slashRange.lowerBound].last, !charBefore.isWhitespace {
        // Otherwise it must start the block or follow whitespace ("and/or" won't trigger).
        return nil
    }
    let query = String(textBefore[slashRange.upperBound...])
    if query.contains(where: { $0.isWhitespace }) { return nil } // a space closes the menu
    let from = cursor.pos - (cursor.parentOffset - slashOffset)
    return SlashMenuState(query: query, from: from, to: cursor.pos)
}

/// The default slash commands (block transforms). The renderer should keep only
/// those whose command is registered for the active schema.
public func defaultSlashCommands() -> [SlashCommandItem] {
    [
        SlashCommandItem(title: "Heading 1", keywords: ["h1", "title", "big"], command: "toggleHeading1", icon: "textformat.size.larger", subtitle: "Big section heading"),
        SlashCommandItem(title: "Heading 2", keywords: ["h2"], command: "toggleHeading2", icon: "textformat.size", subtitle: "Medium heading"),
        SlashCommandItem(title: "Heading 3", keywords: ["h3"], command: "toggleHeading3", icon: "textformat.size.smaller", subtitle: "Small heading"),
        SlashCommandItem(title: "Bullet List", keywords: ["ul", "unordered", "bullet", "list"], command: "toggleBulletList", icon: "list.bullet", subtitle: "A simple bulleted list"),
        SlashCommandItem(title: "Numbered List", keywords: ["ol", "ordered", "number", "list"], command: "toggleOrderedList", icon: "list.number", subtitle: "A numbered list"),
        SlashCommandItem(title: "Task List", keywords: ["todo", "checkbox", "check"], command: "toggleTaskList", icon: "checklist", subtitle: "Track tasks with checkboxes"),
        SlashCommandItem(title: "Quote", keywords: ["blockquote", "citation"], command: "toggleBlockquote", icon: "text.quote", subtitle: "Capture a quotation"),
        SlashCommandItem(title: "Code Block", keywords: ["code", "pre", "snippet"], command: "toggleCodeBlock", icon: "chevron.left.forwardslash.chevron.right", subtitle: "A formatted code snippet"),
        SlashCommandItem(title: "Divider", keywords: ["hr", "rule", "separator", "line"], command: "setHorizontalRule", icon: "minus", subtitle: "A horizontal rule"),
        SlashCommandItem(title: "Details", keywords: ["toggle", "collapse", "accordion", "disclosure", "summary"], command: "toggleDetails", icon: "chevron.right.square", subtitle: "A collapsible section"),
        SlashCommandItem(title: "Equation", keywords: ["math", "latex", "katex", "formula", "tex"], command: "insertBlockMath", icon: "function", subtitle: "A LaTeX formula on its own row"),
        SlashCommandItem(title: "Inline Equation", keywords: ["math", "latex", "katex", "formula", "tex"], command: "insertInlineMath", icon: "x.squareroot", subtitle: "A LaTeX formula within the line"),
    ]
}

public extension Editor {
    /// The active slash-menu state, if the cursor is typing a `/` command.
    var slashMenu: SlashMenuState? { slashMenuKey.getState(state) ?? nil }

    /// Apply a chosen slash command: delete the `/query` text, then run it.
    @discardableResult
    func applySlashCommand(_ item: SlashCommandItem) -> Bool {
        guard let menu = slashMenu else { return false }
        return applySlashCommand(item, from: menu.from, to: menu.to)
    }

    /// Apply a chosen slash command over an explicit trigger range. Use this when
    /// the range was captured before a tap could move the selection.
    @discardableResult
    func applySlashCommand(_ item: SlashCommandItem, from: Int, to: Int) -> Bool {
        let tr = state.tr
        _ = try? tr.delete(min(from, to), max(from, to))
        dispatch(tr)
        return run(item.command)
    }
}
