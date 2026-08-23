import Foundation
public import DocumentModel
import DocumentTransform
public import EditorStateKit
public import EditorCommands
import EditorInputRules

/// State exposed by the mention suggestion plugin: the active `@` query, if
/// the cursor is currently typing one. The view reads this to show a popup.
public struct MentionSuggestion: Equatable {
    /// The text typed after `@` up to the cursor.
    public let query: String
    /// The document position of the `@` trigger.
    public let from: Int
    /// The cursor position.
    public let to: Int
}

public let mentionSuggestionKey = PluginKey<MentionSuggestion?>("mentionSuggestion")

/// A mention is an inline atom node with a stable `id` and an optional display
/// `label`. It renders as `@label` and serializes to
/// `<span data-mention="id">@label</span>`.
public final class MentionExtension: NodeExtension {
    public let name = "mention"
    /// Provides `@` autocomplete candidates for a typed query (synchronous, for
    /// in-memory lists). When nil, no suggestion popup is shown (mentions can
    /// still be inserted via API).
    public let suggestions: (@Sendable (String) -> [String])?
    /// Async `@` candidates — e.g. a directory / user-search lookup. The popup
    /// shows the latest cached results immediately and repaints when fresh ones
    /// arrive (debounced + cancel-on-new-query). Takes precedence over `suggestions`.
    public let asyncSuggestions: (@Sendable (String) async -> [String])?
    public init(suggestions: (@Sendable (String) -> [String])? = nil,
                asyncSuggestions: (@Sendable (String) async -> [String])? = nil) {
        self.suggestions = suggestions
        self.asyncSuggestions = asyncSuggestions
    }

    public var nodeSpec: NodeSpec {
        NodeSpec(
            group: "inline",
            inline: true,
            atom: true,
            attrs: [
                "id": AttributeSpec(),
                "label": AttributeSpec(default: .null),
            ],
            selectable: true,
            draggable: true,
            leafText: { node in
                "@" + (node.attrs["label"]?.stringValue ?? node.attrs["id"]?.stringValue ?? "")
            })
    }
    public var html: HTMLSpec { HTMLSpec(tag: "span") }

    public func plugins(_ ctx: ExtensionContext) -> [Plugin] {
        // Tracks an active `@` query so the view can show a popup.
        [Plugin(
            key: mentionSuggestionKey.key,
            stateField: PluginStateField(
                initialize: { _, _ in Optional<MentionSuggestion>.none as Any },
                apply: { _, _, _, newState in
                    computeMentionSuggestion(newState) as Any
                }))]
    }

    public func suggestionSources(_ ctx: ExtensionContext) -> [any SuggestionSource] {
        if let asyncSuggestions {
            return [AsyncSuggestionSource(provider: asyncSuggestions, locate: mentionContext,
                                          build: { mentionEntries($0, from: $1.from, to: $1.to) })]
        }
        guard let suggestions else { return [] }
        return [MentionSuggestionSource(provider: suggestions)]
    }
}

/// The active `@` query for this editor as a generic SuggestionContext, or nil.
@MainActor
private func mentionContext(_ editor: Editor) -> SuggestionContext? {
    editor.mentionSuggestion.map { SuggestionContext(from: $0.from, to: $0.to, query: $0.query) }
}

/// Maps a list of mention ids to popup entries for an `@` range. The range is
/// captured up front (a tap can clear the live suggestion before `apply` runs).
@MainActor
private func mentionEntries(_ ids: [String], from: Int, to: Int) -> [SuggestionEntry] {
    ids.map { id in
        SuggestionEntry(title: "@" + id, icon: "person.circle") {
            $0.acceptMentionSuggestion(id: id, from: from, to: to)
        }
    }
}

/// Drives the `@` popup from the tracked query + a synchronous name list.
@MainActor
final class MentionSuggestionSource: SuggestionSource {
    let provider: @Sendable (String) -> [String]
    nonisolated init(provider: @escaping @Sendable (String) -> [String]) { self.provider = provider }

    func context(_ editor: Editor) -> SuggestionContext? { mentionContext(editor) }
    func entries(_ query: String, _ editor: Editor) -> [SuggestionEntry] {
        guard let suggestion = editor.mentionSuggestion else { return [] }
        return mentionEntries(provider(query), from: suggestion.from, to: suggestion.to)
    }
}

private func computeMentionSuggestion(_ state: EditorState) -> MentionSuggestion? {
    guard let cursor = (state.selection as? TextSelection)?.cursor else { return nil }
    // Neutralize leaf atoms (a mention's own leaf text starts with "@" and
    // must not re-trigger the popup right after insertion).
    let textBefore = cursor.parent.textBetween(0, cursor.parentOffset, blockSeparator: nil, leafText: "\u{fffc}")
    guard let atRange = textBefore.range(of: "@", options: .backwards) else { return nil }
    // The trigger must start a word.
    if let before = textBefore[..<atRange.lowerBound].last, !before.isWhitespace { return nil }
    let query = textBefore[atRange.upperBound...]
    if query.contains(where: { $0.isWhitespace }) { return nil }
    let atOffset = textBefore.distance(from: textBefore.startIndex, to: atRange.lowerBound)
    let from = cursor.pos - (cursor.parentOffset - atOffset)
    return MentionSuggestion(query: String(query), from: from, to: cursor.pos)
}

/// Insert a mention node at the current selection.
public func insertMention(_ type: NodeType, id: String, label: String? = nil) -> Command {
    { state, dispatch, _ in
        var attrs: Attrs = ["id": .string(id)]
        if let label { attrs["label"] = .string(label) }
        guard let node = try? type.create(attrs) else { return false }
        dispatch?(state.tr.replaceSelectionWith(node).scrollIntoView())
        return true
    }
}

public extension Editor {
    /// Insert a mention of the given id.
    @discardableResult
    func insertMention(id: String, label: String? = nil) -> Bool {
        guard let type = schema.nodes["mention"] else { return false }
        return run(SchemaKit.insertMention(type, id: id, label: label))
    }

    /// The active `@` suggestion, if the cursor is typing one.
    var mentionSuggestion: MentionSuggestion? {
        (mentionSuggestionKey.getState(state)) ?? nil
    }

    /// Replace the active `@` query with a mention of the chosen id.
    @discardableResult
    func acceptMentionSuggestion(id: String, label: String? = nil) -> Bool {
        guard let suggestion = mentionSuggestion else { return false }
        return acceptMentionSuggestion(id: id, label: label, from: suggestion.from, to: suggestion.to)
    }

    /// Replace an explicit `@` range with a mention. Use this when the range
    /// was captured before a tap could move the selection.
    @discardableResult
    func acceptMentionSuggestion(id: String, label: String? = nil, from: Int, to: Int) -> Bool {
        guard let type = schema.nodes["mention"] else { return false }
        var attrs: Attrs = ["id": .string(id)]
        if let label { attrs["label"] = .string(label) }
        guard let node = try? type.create(attrs) else { return false }
        let tr = state.tr
        _ = try? tr.replaceWith(min(from, to), max(from, to), node)
        dispatch(tr.scrollIntoView())
        return true
    }
}
