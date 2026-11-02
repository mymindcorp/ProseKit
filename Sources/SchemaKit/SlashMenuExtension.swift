import Foundation
import DocumentModel
import DocumentTransform
public import EditorStateKit
public import EditorCommands

/// One entry in the slash (`/`) command menu: a display title, search keywords,
/// and what to run when chosen — a named command, or a `Command` of its own.
public struct SlashCommandItem: Sendable, Equatable {
    public let title: String
    public let keywords: [String]
    /// The named command to run, or — when `run` is given — the item's identifier.
    public let command: String
    /// An SF Symbol name shown as the row's leading glyph.
    public let icon: String?
    /// A short description shown under the title.
    public let subtitle: String?
    /// The group the row is listed under ("Lists", "Math"…). Rows of one section
    /// should be adjacent: a header is drawn wherever the section changes.
    public let section: String?
    /// Whatever else a custom presenter should draw for this row (a badge, a
    /// shortcut hint). The built-in popup ignores it.
    public let metadata: [String: String]
    /// A command run in place of the named one, for an action the host defines
    /// itself (insert a template, open a picker…). It runs after the `/query`
    /// is deleted; returning false leaves the query in place.
    public let run: Command?
    public init(title: String, keywords: [String] = [], command: String, icon: String? = nil, subtitle: String? = nil,
                section: String? = nil, metadata: [String: String] = [:]) {
        self.init(title: title, keywords: keywords, command: command, icon: icon, subtitle: subtitle, section: section,
                  metadata: metadata, run: nil)
    }

    /// An item with its own action. `id` takes the place of a command name: it
    /// identifies the item, and is what `==` compares, since closures can't be.
    public init(title: String, keywords: [String] = [], id: String, icon: String? = nil, subtitle: String? = nil,
                section: String? = nil, metadata: [String: String] = [:], run: @escaping Command) {
        self.init(title: title, keywords: keywords, command: id, icon: icon, subtitle: subtitle, section: section,
                  metadata: metadata, run: run)
    }

    private init(title: String, keywords: [String], command: String, icon: String?, subtitle: String?,
                 section: String?, metadata: [String: String], run: Command?) {
        self.title = title
        self.keywords = keywords
        self.command = command
        self.icon = icon
        self.subtitle = subtitle
        self.section = section
        self.metadata = metadata
        self.run = run
    }

    /// The same item filed under another section — for regrouping the defaults.
    public func inSection(_ section: String?) -> SlashCommandItem {
        SlashCommandItem(title: title, keywords: keywords, command: command, icon: icon, subtitle: subtitle,
                         section: section, metadata: metadata, run: run)
    }

    public static func == (lhs: SlashCommandItem, rhs: SlashCommandItem) -> Bool {
        lhs.title == rhs.title && lhs.keywords == rhs.keywords && lhs.command == rhs.command
            && lhs.icon == rhs.icon && lhs.subtitle == rhs.subtitle && lhs.section == rhs.section
            && lhs.metadata == rhs.metadata && (lhs.run == nil) == (rhs.run == nil)
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
    public let query: String
    public let from: Int   // position of the `/`
    public let to: Int     // the cursor
}

public let slashMenuKey = PluginKey<SlashMenuState?>("slashMenu")

/// How the slash menu behaves and what it offers. Start from
/// `defaultSlashCommands()` to add to, remove from, or reorder the built-in rows.
public struct SlashMenuOptions: Sendable {
    /// The commands offered by the menu, in the order shown.
    public var commands: [SlashCommandItem]
    /// When true (default), `/` only opens the menu at the start of a line/block;
    /// when false it also opens after whitespace (Notion-style).
    public var atLineStart: Bool
    /// Hide rows whose command couldn't run where the `/` was typed (a list
    /// command inside a table cell that can't hold one, say). Off by default:
    /// it dry-runs every matching row on each keystroke while the menu is open.
    /// Rows naming a command the editor doesn't have are hidden either way.
    public var hidesUnavailable: Bool
    /// Whether an item matches the typed query; nil uses `SlashCommandItem.matches`.
    public var matches: (@Sendable (_ item: SlashCommandItem, _ query: String) -> Bool)?

    public init(commands: [SlashCommandItem] = defaultSlashCommands(), atLineStart: Bool = true,
                hidesUnavailable: Bool = false,
                matches: (@Sendable (_ item: SlashCommandItem, _ query: String) -> Bool)? = nil) {
        self.commands = commands
        self.atLineStart = atLineStart
        self.hidesUnavailable = hidesUnavailable
        self.matches = matches
    }
}

/// Adds a `/` slash-command menu. Self-contained: it tracks the active query via
/// a plugin and exposes a `SuggestionSource` so the renderer drives the popup
/// generically.
public final class SlashMenuExtension: Extension {
    public let name = "slashMenu"
    public let options: SlashMenuOptions
    /// The commands offered by the menu.
    public var commands: [SlashCommandItem] { options.commands }
    /// Whether `/` only opens the menu at the start of a block.
    public var atLineStart: Bool { options.atLineStart }

    public init(options: SlashMenuOptions) {
        self.options = options
    }

    public convenience init(commands: [SlashCommandItem] = defaultSlashCommands(), atLineStart: Bool = true) {
        self.init(options: SlashMenuOptions(commands: commands, atLineStart: atLineStart))
    }

    public func plugins(_ ctx: ExtensionContext) -> [Plugin] {
        let atLineStart = options.atLineStart
        return [Plugin(
            key: slashMenuKey.key,
            stateField: PluginStateField(
                initialize: { _, _ in Optional<SlashMenuState>.none as Any },
                apply: { _, _, _, newState in computeSlashMenu(newState, atLineStart: atLineStart) as Any }))]
    }

    public func suggestionSources(_ ctx: ExtensionContext) -> [any SuggestionSource] {
        [SlashSuggestionSource(options: options)]
    }
}

/// Drives the slash-menu popup from the tracked query + the configured commands.
@MainActor
final class SlashSuggestionSource: SuggestionSource {
    let options: SlashMenuOptions
    nonisolated init(options: SlashMenuOptions) { self.options = options }

    func context(_ editor: Editor) -> SuggestionContext? {
        editor.slashMenu.map { SuggestionContext(from: $0.from, to: $0.to, query: $0.query, trigger: "/") }
    }
    func entries(_ query: String, _ editor: Editor) -> [SuggestionEntry] {
        guard let menu = editor.slashMenu else { return [] }
        // Capture the trigger range now: applying from a tap can move the caret
        // (and clear the live `slashMenu`) before the command runs.
        let from = menu.from, to = menu.to
        let matches = options.matches ?? { $0.matches($1) }
        let offered = options.commands.filter { item in
            guard item.run != nil || editor.namedCommand(item.command) != nil, matches(item, query) else { return false }
            return !options.hidesUnavailable || editor.canApplySlashCommand(item, from: from, to: to)
        }
        let entries = offered.map { item in
            SuggestionEntry(title: item.title, subtitle: item.subtitle, icon: item.icon, section: item.section,
                            id: item.command, metadata: item.metadata) {
                $0.applySlashCommand(item, from: from, to: to)
            }
        }
        return guardSuggestionEntries(entries, in: editor)
    }
}

private func computeSlashMenu(_ state: EditorState, atLineStart: Bool) -> SlashMenuState? {
    guard let cursor = (state.selection as? TextSelection)?.cursor else { return nil }
    let parent = cursor.parent
    guard parent.isTextblock, !parent.type.spec.code else { return nil }
    // Use placeholders so the display label of an inline leaf cannot be
    // mistaken for typed trigger text.
    let textBefore = parent.textBetween(0, cursor.parentOffset, blockSeparator: nil, leafText: "\u{fffc}")
    guard let slashRange = textBefore.range(of: "/", options: .backwards) else { return nil }
    guard let slashOffset = suggestionTriggerOffset(parent,
        utf16Offset: textBefore[..<slashRange.lowerBound].utf16.count) else { return nil }
    if atLineStart {
        // The `/` must be the first character of the block.
        if slashOffset != 0 { return nil }
    } else if let charBefore = textBefore[..<slashRange.lowerBound].last, !charBefore.isWhitespace {
        // Otherwise it must start the block or follow whitespace ("and/or" won't trigger).
        return nil
    }
    let query = String(textBefore[slashRange.upperBound...])
    if query.contains(where: { $0.isWhitespace }) { return nil } // a space closes the menu
    guard !suggestionCrossesHardBreak(parent, from: slashOffset, to: cursor.parentOffset) else { return nil }
    let from = cursor.pos - (cursor.parentOffset - slashOffset)
    return SlashMenuState(query: query, from: from, to: cursor.pos)
}

/// The default slash commands (block transforms), grouped into sections. Rows
/// whose command the editor doesn't have are left out of the menu.
public func defaultSlashCommands() -> [SlashCommandItem] {
    [
        SlashCommandItem(title: "Heading 1", keywords: ["h1", "title", "big"], command: "toggleHeading1", icon: "textformat.size.larger", subtitle: "Big section heading", section: "Text"),
        SlashCommandItem(title: "Heading 2", keywords: ["h2"], command: "toggleHeading2", icon: "textformat.size", subtitle: "Medium heading", section: "Text"),
        SlashCommandItem(title: "Heading 3", keywords: ["h3"], command: "toggleHeading3", icon: "textformat.size.smaller", subtitle: "Small heading", section: "Text"),
        SlashCommandItem(title: "Quote", keywords: ["blockquote", "citation"], command: "toggleBlockquote", icon: "text.quote", subtitle: "Capture a quotation", section: "Text"),
        SlashCommandItem(title: "Bullet List", keywords: ["ul", "unordered", "bullet", "list"], command: "toggleBulletList", icon: "list.bullet", subtitle: "A simple bulleted list", section: "Lists"),
        SlashCommandItem(title: "Numbered List", keywords: ["ol", "ordered", "number", "list"], command: "toggleOrderedList", icon: "list.number", subtitle: "A numbered list", section: "Lists"),
        SlashCommandItem(title: "Task List", keywords: ["todo", "checkbox", "check"], command: "toggleTaskList", icon: "checklist", subtitle: "Track tasks with checkboxes", section: "Lists"),
        SlashCommandItem(title: "Code Block", keywords: ["code", "pre", "snippet"], command: "toggleCodeBlock", icon: "chevron.left.forwardslash.chevron.right", subtitle: "A formatted code snippet", section: "Blocks"),
        SlashCommandItem(title: "Divider", keywords: ["hr", "rule", "separator", "line"], command: "setHorizontalRule", icon: "minus", subtitle: "A horizontal rule", section: "Blocks"),
        SlashCommandItem(title: "Details", keywords: ["toggle", "collapse", "accordion", "disclosure", "summary"], command: "toggleDetails", icon: "chevron.right.square", subtitle: "A collapsible section", section: "Blocks"),
        SlashCommandItem(title: "Equation", keywords: ["math", "latex", "katex", "formula", "tex"], command: "insertBlockMath", icon: "function", subtitle: "A LaTeX formula on its own row", section: "Math"),
        SlashCommandItem(title: "Inline Equation", keywords: ["math", "latex", "katex", "formula", "tex"], command: "insertInlineMath", icon: "x.squareroot", subtitle: "A LaTeX formula within the line", section: "Math"),
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
        let prepare = removeSuggestionRange(from: from, to: to)
        if let run = item.run { return chain([prepare, run]) }
        return run(item.command, after: prepare)
    }

    /// Whether the item would run if chosen now over the given trigger range —
    /// a dry run against the document with the `/query` already removed.
    func canApplySlashCommand(_ item: SlashCommandItem, from: Int, to: Int) -> Bool {
        guard let command = item.run ?? namedCommand(item.command) else { return false }
        var prepared: Transaction?
        guard removeSuggestionRange(from: from, to: to)(state, { prepared = $0 }, nil),
              let prepared else { return false }
        return command(state.apply(prepared), nil, host as? any CommandHost)
    }
}
