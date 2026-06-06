import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorInputRules

/// State exposed by the wiki-link suggestion plugin: the active `[[` query, if
/// the cursor is currently typing one. The view reads this to show a popup.
public struct WikiLinkSuggestion: Equatable {
    /// The text typed after `[[` up to the cursor.
    public var query: String
    /// The document position of the `[[` opening (where the trigger started).
    public var from: Int
    /// The cursor position.
    public var to: Int
}

public let wikiLinkSuggestionKey = PluginKey<WikiLinkSuggestion?>("wikiLinkSuggestion")

/// A wiki-link is an inline atom node with a stable `target` (page id/name) and
/// an optional display `label`. It renders its label (or target) and serializes
/// to `[[target|label]]`.
public final class WikiLinkExtension: NodeExtension {
    public let name = "wikiLink"
    /// Provides `[[` autocomplete candidates for a typed query. When nil, no
    /// suggestion popup is shown (the `[[…]]` input rule still works).
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
                "target": AttributeSpec(),
                "label": AttributeSpec(default: .null),
            ],
            selectable: true,
            draggable: true,
            leafText: { node in
                node.attrs["label"]?.stringValue ?? node.attrs["target"]?.stringValue ?? ""
            })
    }
    public var html: HTMLSpec { HTMLSpec(tag: "a") }

    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        // Parameterless command is not meaningful; expose via Editor typed method.
        return ["unsetWikiLink": { state, dispatch, _ in
            guard let ns = state.selection as? NodeSelection, ns.node.type === type else { return false }
            dispatch?(state.tr.deleteSelection())
            return true
        }]
    }

    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.nodeType else { return [] }
        // [[Target]] or [[Target|Label]] -> a wiki-link node.
        return [InputRule("\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]$") { state, match, start, end in
            let target = (match[1] ?? "").trimmingCharacters(in: .whitespaces)
            if target.isEmpty { return nil }
            var attrs: Attrs = ["target": .string(target)]
            if let label = match[2], !label.isEmpty { attrs["label"] = .string(label) }
            guard let node = try? type.create(attrs) else { return nil }
            let tr = state.tr
            _ = try? tr.replaceWith(start, end, node)
            return tr
        }]
    }

    public func plugins(_ ctx: ExtensionContext) -> [Plugin] {
        // Tracks an active `[[` suggestion query so the view can show a popup.
        [Plugin(
            key: wikiLinkSuggestionKey.key,
            stateField: PluginStateField(
                initialize: { _, _ in Optional<WikiLinkSuggestion>.none as Any },
                apply: { tr, _, _, newState in
                    computeSuggestion(newState) as Any
                }))]
    }

    public func suggestionSources(_ ctx: ExtensionContext) -> [any SuggestionSource] {
        guard let suggestions else { return [] }
        return [WikiLinkSuggestionSource(provider: suggestions)]
    }
}

/// Drives the `[[` popup from the tracked query + a configurable target list.
final class WikiLinkSuggestionSource: SuggestionSource {
    let provider: (String) -> [String]
    init(provider: @escaping (String) -> [String]) { self.provider = provider }

    func context(_ editor: Editor) -> SuggestionContext? {
        editor.wikiLinkSuggestion.map { SuggestionContext(from: $0.from, to: $0.to, query: $0.query) }
    }
    func entries(_ query: String, _ editor: Editor) -> [SuggestionEntry] {
        provider(query).map { target in
            SuggestionEntry(title: target) { $0.acceptWikiLinkSuggestion(target: target) }
        }
    }
}

private func computeSuggestion(_ state: EditorState) -> WikiLinkSuggestion? {
    guard let cursor = (state.selection as? TextSelection)?.cursor else { return nil }
    let parent = cursor.parent
    let textBefore = parent.textBetween(0, cursor.parentOffset)
    // Find the last unmatched "[[".
    guard let openRange = textBefore.range(of: "[[", options: .backwards) else { return nil }
    let afterOpen = textBefore[openRange.upperBound...]
    // Cancel if there's a closing "]]" or a newline after the "[[".
    if afterOpen.contains("]") { return nil }
    let query = String(afterOpen)
    let openOffset = textBefore.distance(from: textBefore.startIndex, to: openRange.lowerBound)
    let from = cursor.pos - (cursor.parentOffset - openOffset)
    return WikiLinkSuggestion(query: query, from: from, to: cursor.pos)
}

/// Insert a wiki-link node at the current selection.
public func insertWikiLink(_ type: NodeType, target: String, label: String? = nil) -> Command {
    { state, dispatch, _ in
        var attrs: Attrs = ["target": .string(target)]
        if let label { attrs["label"] = .string(label) }
        guard let node = try? type.create(attrs) else { return false }
        dispatch?(state.tr.replaceSelectionWith(node).scrollIntoView())
        return true
    }
}

public extension Editor {
    /// Insert a wiki-link to the given target page.
    @discardableResult
    func insertWikiLink(target: String, label: String? = nil) -> Bool {
        guard let type = schema.nodes["wikiLink"] else { return false }
        return run(SchemaKit.insertWikiLink(type, target: target, label: label))
    }

    /// The active `[[` suggestion, if the cursor is typing one.
    var wikiLinkSuggestion: WikiLinkSuggestion? {
        (wikiLinkSuggestionKey.getState(state)) ?? nil
    }

    /// Replace the active `[[` query with a wiki-link to the chosen target.
    @discardableResult
    func acceptWikiLinkSuggestion(target: String, label: String? = nil) -> Bool {
        guard let type = schema.nodes["wikiLink"], let suggestion = wikiLinkSuggestion else { return false }
        var attrs: Attrs = ["target": .string(target)]
        if let label { attrs["label"] = .string(label) }
        guard let node = try? type.create(attrs) else { return false }
        let tr = state.tr
        _ = try? tr.replaceWith(suggestion.from, suggestion.to, node)
        dispatch(tr.scrollIntoView())
        return true
    }
}
