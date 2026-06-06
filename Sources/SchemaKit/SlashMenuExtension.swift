import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit

/// One entry in the slash (`/`) command menu: a display title, search keywords,
/// and the named command to run when chosen.
public struct SlashCommandItem: Sendable, Equatable {
    public var title: String
    public var keywords: [String]
    public var command: String
    public init(title: String, keywords: [String] = [], command: String) {
        self.title = title
        self.keywords = keywords
        self.command = command
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
final class SlashSuggestionSource: SuggestionSource {
    let commands: [SlashCommandItem]
    init(commands: [SlashCommandItem]) { self.commands = commands }

    func context(_ editor: Editor) -> SuggestionContext? {
        editor.slashMenu.map { SuggestionContext(from: $0.from, to: $0.to, query: $0.query) }
    }
    func entries(_ query: String, _ editor: Editor) -> [SuggestionEntry] {
        commands.filter { $0.matches(query) }.map { item in
            SuggestionEntry(title: item.title) { $0.applySlashCommand(item) }
        }
    }
}

private func computeSlashMenu(_ state: EditorState, atLineStart: Bool) -> SlashMenuState? {
    guard let cursor = (state.selection as? TextSelection)?.cursor else { return nil }
    let parent = cursor.parent
    guard parent.isTextblock, !parent.type.spec.code else { return nil }
    let textBefore = parent.textBetween(0, cursor.parentOffset)
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
        SlashCommandItem(title: "Heading 1", keywords: ["h1", "title", "big"], command: "toggleHeading1"),
        SlashCommandItem(title: "Heading 2", keywords: ["h2"], command: "toggleHeading2"),
        SlashCommandItem(title: "Heading 3", keywords: ["h3"], command: "toggleHeading3"),
        SlashCommandItem(title: "Bullet List", keywords: ["ul", "unordered", "bullet", "list"], command: "toggleBulletList"),
        SlashCommandItem(title: "Numbered List", keywords: ["ol", "ordered", "number", "list"], command: "toggleOrderedList"),
        SlashCommandItem(title: "Task List", keywords: ["todo", "checkbox", "check"], command: "toggleTaskList"),
        SlashCommandItem(title: "Quote", keywords: ["blockquote", "citation"], command: "toggleBlockquote"),
        SlashCommandItem(title: "Code Block", keywords: ["code", "pre", "snippet"], command: "toggleCodeBlock"),
        SlashCommandItem(title: "Divider", keywords: ["hr", "rule", "separator", "line"], command: "setHorizontalRule"),
    ]
}

public extension Editor {
    /// The active slash-menu state, if the cursor is typing a `/` command.
    var slashMenu: SlashMenuState? { slashMenuKey.getState(state) ?? nil }

    /// Apply a chosen slash command: delete the `/query` text, then run it.
    @discardableResult
    func applySlashCommand(_ item: SlashCommandItem) -> Bool {
        guard let menu = slashMenu else { return false }
        let tr = state.tr
        _ = try? tr.delete(menu.from, menu.to)
        dispatch(tr)
        return run(item.command)
    }
}
