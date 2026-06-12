import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorInputRules

/// State exposed by the mention suggestion plugin: the active `@` query, if
/// the cursor is currently typing one. The view reads this to show a popup.
public struct MentionSuggestion: Equatable {
    /// The text typed after `@` up to the cursor.
    public var query: String
    /// The document position of the `@` trigger.
    public var from: Int
    /// The cursor position.
    public var to: Int
}

public let mentionSuggestionKey = PluginKey<MentionSuggestion?>("mentionSuggestion")

/// A mention is an inline atom node with a stable `id` and an optional display
/// `label`. It renders as `@label` and serializes to
/// `<span data-mention="id">@label</span>`.
public final class MentionExtension: NodeExtension {
    public let name = "mention"
    /// Provides `@` autocomplete candidates for a typed query. When nil, no
    /// suggestion popup is shown (mentions can still be inserted via API).
    public let suggestions: ((String) -> [String])?
    public init(suggestions: ((String) -> [String])? = nil) {
        self.suggestions = suggestions
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
        guard let suggestions else { return [] }
        return [MentionSuggestionSource(provider: suggestions)]
    }
}

/// Drives the `@` popup from the tracked query + a configurable name list.
final class MentionSuggestionSource: SuggestionSource {
    let provider: (String) -> [String]
    init(provider: @escaping (String) -> [String]) { self.provider = provider }

    func context(_ editor: Editor) -> SuggestionContext? {
        editor.mentionSuggestion.map { SuggestionContext(from: $0.from, to: $0.to, query: $0.query) }
    }
    func entries(_ query: String, _ editor: Editor) -> [SuggestionEntry] {
        guard let suggestion = editor.mentionSuggestion else { return [] }
        // Capture the `@` range now (a tap can clear the live suggestion).
        let from = suggestion.from, to = suggestion.to
        return provider(query).map { id in
            SuggestionEntry(title: "@" + id) { $0.acceptMentionSuggestion(id: id, from: from, to: to) }
        }
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
