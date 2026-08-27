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

/// A wiki-link is an inline atom node: the words it reads as (`text`), and
/// optionally the host's identity for what it points at (`targetId`) and what
/// kind of thing that is (`targetType`). It serializes to `[[text]]`.
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
                // What the link reads as. A `[[Page]]` typed by hand puts the
                // typed words here; a host that picked the target from its own
                // store puts the thing's name here and its identity below.
                "text": AttributeSpec(default: .null),
                // The host's id for what `text` names, and what kind of thing it
                // is. The id is what still resolves after a rename, and the type
                // is what lets a renderer draw the target's own icon without
                // asking anyone. Attributes outside this spec are dropped on
                // parse, so a host that writes one needs it declared here.
                "targetId": AttributeSpec(default: .null),
                "targetType": AttributeSpec(default: .null),
            ],
            selectable: true,
            draggable: true,
            leafText: { node in wikiLinkText(node) })
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
            let typed = (match[1] ?? "").trimmingCharacters(in: .whitespaces)
            if typed.isEmpty { return nil }
            // `[[Page|shown]]` reads as "shown": what a reader sees is the text.
            let shown = match[2].flatMap { $0.isEmpty ? nil : $0 } ?? typed
            let attrs: Attrs = ["text": .string(shown)]
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
///
/// The query is trimmed: the spacing after `[[` is spacing, not part of the page
/// name — `[[ Getting` names the same page as `[[Getting`, which is what the
/// `[[…]]` input rule's trimmed target and the ghost brackets' mirrored spaces
/// both already assume. A provider that substring-matches would find nothing for
/// " Getting" and the popup would blink out mid-word. The range stays untrimmed,
/// so accepting still replaces the spaces along with the query.
@MainActor
private func wikiLinkContext(_ editor: Editor) -> SuggestionContext? {
    editor.wikiLinkSuggestion.map {
        SuggestionContext(from: $0.from, to: $0.to, query: trimmedQuery($0.query))
    }
}

/// A `[[` query as a provider should see it (see `wikiLinkContext`).
private func trimmedQuery(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespaces)
}

/// Maps a list of target page ids to popup entries for a `[[` range. The range is
/// captured up front (a tap can clear the live suggestion before `apply` runs).
@MainActor
private func wikiLinkEntries(_ targets: [String], from: Int, to: Int) -> [SuggestionEntry] {
    targets.map { target in
        SuggestionEntry(title: target, icon: "doc.text") {
            $0.acceptWikiLinkSuggestion(text: target, from: from, to: to)
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
        return wikiLinkEntries(provider(trimmedQuery(query)), from: suggestion.from, to: suggestion.to)
    }
}

private func computeSuggestion(_ state: EditorState) -> WikiLinkSuggestion? {
    guard let cursor = (state.selection as? TextSelection)?.cursor,
          let type = state.schema.nodes["wikiLink"] else { return nil }
    let parent = cursor.parent
    guard isSuggestionContext(parent, state: state, cursor: cursor,
                              inserting: type, excludingHeadings: true) else { return nil }
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

/// What a wiki-link reads as.
public func wikiLinkText(_ node: Node) -> String {
    node.attrs["text"]?.stringValue ?? ""
}

/// The attribute set a wiki-link carries. What isn't passed isn't supplied, so
/// the node type fills it from the spec's default (null).
func wikiLinkAttrs(text: String, targetId: String?, targetType: String?) -> Attrs {
    var attrs: Attrs = ["text": .string(text)]
    if let targetId { attrs["targetId"] = .string(targetId) }
    if let targetType { attrs["targetType"] = .string(targetType) }
    return attrs
}

/// Insert a wiki-link node at the current selection.
public func insertWikiLink(_ type: NodeType, text: String, targetId: String? = nil,
                           targetType: String? = nil) -> Command {
    { state, dispatch, _ in
        let attrs = wikiLinkAttrs(text: text, targetId: targetId, targetType: targetType)
        guard let node = try? type.create(attrs) else { return false }
        dispatch?(state.tr.replaceSelectionWith(node).scrollIntoView())
        return true
    }
}

public extension Editor {
    /// Insert a wiki-link reading as `text`, optionally naming what it points at.
    @discardableResult
    func insertWikiLink(text: String, targetId: String? = nil, targetType: String? = nil) -> Bool {
        guard let type = schema.nodes["wikiLink"] else { return false }
        return run(SchemaKit.insertWikiLink(type, text: text, targetId: targetId, targetType: targetType))
    }

    /// The active `[[` suggestion, if the cursor is typing one.
    var wikiLinkSuggestion: WikiLinkSuggestion? {
        (wikiLinkSuggestionKey.getState(state)) ?? nil
    }

    /// Replace the active `[[` query with a wiki-link to the chosen target.
    @discardableResult
    func acceptWikiLinkSuggestion(text: String, targetId: String? = nil,
                                  targetType: String? = nil) -> Bool {
        guard let suggestion = wikiLinkSuggestion else { return false }
        return acceptWikiLinkSuggestion(text: text, targetId: targetId, targetType: targetType,
                                        from: suggestion.from, to: suggestion.to)
    }

    /// Replace an explicit `[[` range with a wiki-link. Use this when the range
    /// was captured before a tap could move the selection.
    @discardableResult
    func acceptWikiLinkSuggestion(text: String, targetId: String? = nil, targetType: String? = nil,
                                  from: Int, to: Int) -> Bool {
        guard let type = schema.nodes["wikiLink"] else { return false }
        let attrs = wikiLinkAttrs(text: text, targetId: targetId, targetType: targetType)
        guard let node = try? type.create(attrs) else { return false }
        let tr = state.tr
        _ = try? tr.replaceWith(min(from, to), max(from, to), node)
        dispatch(tr.scrollIntoView())
        return true
    }
}
