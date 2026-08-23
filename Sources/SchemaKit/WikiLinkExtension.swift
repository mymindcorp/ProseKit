import Foundation
public import DocumentModel
import DocumentTransform
public import EditorStateKit
public import EditorCommands
public import EditorInputRules

/// State exposed by the wiki-link suggestion plugin: the active `[[` query, if
/// the cursor is currently typing one. The view reads this to show a popup.
public struct WikiLinkSuggestion: Equatable {
    /// The text typed after `[[` up to the cursor.
    public let query: String
    /// The document position of the `[[` opening (where the trigger started).
    public let from: Int
    /// The cursor position.
    public let to: Int
}

public let wikiLinkSuggestionKey = PluginKey<WikiLinkSuggestion?>("wikiLinkSuggestion")

/// A wiki-link is an inline atom node with a stable `target` (page id/name) and
/// an optional display `label`. It renders its label (or target) and serializes
/// to `[[target|label]]`.
public final class WikiLinkExtension: NodeExtension {
    public let name = "wikiLink"
    /// Provides `[[` autocomplete candidates for a typed query (synchronous, for
    /// in-memory lists). When nil, no popup is shown (the `[[…]]` input rule still
    /// works).
    public let suggestions: (@Sendable (String) -> [String])?
    /// Async `[[` candidates — e.g. a DB / search-index lookup. The popup shows
    /// the latest cached results immediately and repaints when fresh ones arrive
    /// (debounced + cancel-on-new-query). Takes precedence over `suggestions`.
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
        if let asyncSuggestions {
            return [AsyncSuggestionSource(provider: asyncSuggestions, locate: wikiLinkContext,
                                          build: { wikiLinkEntries($0, from: $1.from, to: $1.to) })]
        }
        guard let suggestions else { return [] }
        return [WikiLinkSuggestionSource(provider: suggestions)]
    }
}

/// The active `[[` query for this editor as a generic SuggestionContext, or nil.
@MainActor
private func wikiLinkContext(_ editor: Editor) -> SuggestionContext? {
    editor.wikiLinkSuggestion.map { SuggestionContext(from: $0.from, to: $0.to, query: $0.query) }
}

/// Maps a list of target page ids to popup entries for a `[[` range. The range is
/// captured up front (a tap can clear the live suggestion before `apply` runs).
@MainActor
private func wikiLinkEntries(_ targets: [String], from: Int, to: Int) -> [SuggestionEntry] {
    targets.map { target in
        SuggestionEntry(title: target, icon: "doc.text") {
            $0.acceptWikiLinkSuggestion(target: target, from: from, to: to)
        }
    }
}

/// Drives the `[[` popup from the tracked query + a synchronous target list.
@MainActor
final class WikiLinkSuggestionSource: SuggestionSource {
    let provider: @Sendable (String) -> [String]
    nonisolated init(provider: @escaping @Sendable (String) -> [String]) { self.provider = provider }

    func context(_ editor: Editor) -> SuggestionContext? { wikiLinkContext(editor) }
    func entries(_ query: String, _ editor: Editor) -> [SuggestionEntry] {
        guard let suggestion = editor.wikiLinkSuggestion else { return [] }
        return wikiLinkEntries(provider(query), from: suggestion.from, to: suggestion.to)
    }
}

/// Where `[[` may open the popup: running prose — a paragraph, including the
/// ones inside list items, quotes, and table cells — and nothing else. A
/// heading is a title rather than prose, and code is literal text where `[[`
/// means brackets; neither should autocomplete. The schema has the last word:
/// a textblock that can't hold a wiki-link can't be offered one.
private func isSuggestionContext(_ parent: Node, state: EditorState, cursor: ResolvedPos,
                                 wikiLink: NodeType) -> Bool {
    guard parent.isTextblock, !parent.type.spec.code,
          parent.type.name != "heading",
          parent.type.contentMatch.matchType(wikiLink) != nil else { return false }
    // An inline code span is code too, even in a paragraph. `storedMarks` is
    // what the next character would take on, which is what matters at a
    // boundary where the cursor's own marks haven't caught up yet.
    let marks = state.storedMarks ?? cursor.marks()
    return !marks.contains { $0.type.spec.code }
}

private func computeSuggestion(_ state: EditorState) -> WikiLinkSuggestion? {
    guard let cursor = (state.selection as? TextSelection)?.cursor,
          let type = state.schema.nodes["wikiLink"] else { return nil }
    let parent = cursor.parent
    guard isSuggestionContext(parent, state: state, cursor: cursor, wikiLink: type) else { return nil }
    // One character per inline leaf, so a character offset into this string is
    // a document offset. Without the override a leaf expands to its `leafText`
    // — a wiki-link renders as its whole label — and every offset past it
    // overstates the position by the label's length, which puts `from` beyond
    // the cursor and traps in `resolve`.
    let textBefore = parent.textBetween(0, cursor.parentOffset, blockSeparator: nil, leafText: "\u{fffc}")
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
        guard let suggestion = wikiLinkSuggestion else { return false }
        return acceptWikiLinkSuggestion(target: target, label: label, from: suggestion.from, to: suggestion.to)
    }

    /// Replace an explicit `[[` range with a wiki-link. Use this when the range
    /// was captured before a tap could move the selection.
    @discardableResult
    func acceptWikiLinkSuggestion(target: String, label: String? = nil, from: Int, to: Int) -> Bool {
        guard let type = schema.nodes["wikiLink"] else { return false }
        var attrs: Attrs = ["target": .string(target)]
        if let label { attrs["label"] = .string(label) }
        guard let node = try? type.create(attrs) else { return false }
        let tr = state.tr
        _ = try? tr.replaceWith(min(from, to), max(from, to), node)
        dispatch(tr.scrollIntoView())
        return true
    }
}
