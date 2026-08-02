public import DocumentModel
import DocumentTransform
public import EditorChangeset
public import EditorCommands
public import EditorStateKit

// Suggestion mode (track changes), built on the ported prosemirror-changeset.
// ORIGINAL ProseKit feature — there is no official ProseMirror suggestion-mode
// package; only the underlying changeset library is a port. While enabled,
// edits apply to the document normally and a ChangeSet records them against a
// base document. Insertions render as inline "insertion" decorations; deleted
// content renders as a "deletion" widget at the deletion point carrying the
// removed text. Accepting a change folds it into the base; rejecting restores
// the base content in the document.

/// The data recorded per span: the author of the suggestion. Edits made while
/// suggesting is OFF use a reserved marker and are folded into the base.
private let committedData = "\u{0}committed"

public final class SuggestionModeState {
    /// Whether new edits are recorded as suggestions.
    public let enabled: Bool
    /// The recorded changes against the base document. Nil until suggestion
    /// mode has been enabled at least once.
    public let changeSet: ChangeSet<String>?

    public var changes: [Change<String>] { changeSet?.changes ?? [] }
    public var baseDoc: Node? { changeSet?.startDoc }

    init(enabled: Bool, changeSet: ChangeSet<String>?) {
        self.enabled = enabled
        self.changeSet = changeSet
    }

    /// The deleted text of the change at `index` (suggested spans only).
    public func deletedText(at index: Int) -> String {
        guard let set = changeSet, set.changes.indices.contains(index) else { return "" }
        let change = set.changes[index]
        var text = ""
        var offset = change.fromA
        for span in change.deleted {
            if span.data != committedData {
                text += set.startDoc.textBetween(offset, offset + span.length, blockSeparator: "\n")
            }
            offset += span.length
        }
        return text
    }

    private static func makeSet(_ base: Node, _ changes: [Change<String>]) -> ChangeSet<String> {
        ChangeSet.create(base, combine: { a, b in a == b ? a : nil }, changes: changes)
    }

    /// Fold change `index` into the base: the base adopts the current
    /// document's content for that range, and later changes' base coordinates
    /// shift accordingly. The document is untouched.
    static func accepting(_ set: ChangeSet<String>, _ index: Int, doc: Node) -> ChangeSet<String> {
        let change = set.changes[index]
        guard let newBase = try? set.startDoc.replace(change.fromA, change.toA, doc.slice(change.fromB, change.toB))
        else { return set }
        let delta = (change.toB - change.fromB) - (change.toA - change.fromA)
        var rest = set.changes
        rest.remove(at: index)
        rest = rest.map { c in
            c.fromA >= change.toA
                ? Change(c.fromA + delta, c.toA + delta, c.fromB, c.toB, c.deleted, c.inserted) : c
        }
        return makeSet(newBase, rest)
    }

    /// Drop change `index` after the document was reverted to the base content
    /// for its range (the rejecting transaction carries those steps): later
    /// changes' document coordinates shift accordingly. The base is untouched.
    static func rejecting(_ set: ChangeSet<String>, _ index: Int) -> ChangeSet<String> {
        let change = set.changes[index]
        let delta = (change.toA - change.fromA) - (change.toB - change.fromB)
        var rest = set.changes
        rest.remove(at: index)
        rest = rest.map { c in
            c.fromB >= change.toB
                ? Change(c.fromA, c.toA, c.fromB + delta, c.toB + delta, c.deleted, c.inserted) : c
        }
        return makeSet(set.startDoc, rest)
    }

    func apply(_ tr: Transaction, author: String) -> SuggestionModeState {
        if let action = tr.getMeta(suggestionModeMeta) as? SuggestionAction {
            switch action {
            case .setEnabled(let on):
                // Enabling for the first time starts tracking from the current
                // document; disabling keeps pending suggestions.
                let newSet = on && changeSet == nil ? Self.makeSet(tr.doc, []) : changeSet
                return SuggestionModeState(enabled: on, changeSet: newSet)
            case .accept(let index):
                guard let set = changeSet, set.changes.indices.contains(index) else { return self }
                return SuggestionModeState(enabled: enabled, changeSet: Self.accepting(set, index, doc: tr.doc))
            case .reject(let index):
                guard let set = changeSet, set.changes.indices.contains(index) else { return self }
                return SuggestionModeState(enabled: enabled, changeSet: Self.rejecting(set, index))
            case .acceptAll, .rejectAll:
                // Either way every change is resolved: after acceptAll the
                // current doc IS the new base; after rejectAll the reverting
                // steps in this transaction brought the doc back to the base.
                return SuggestionModeState(enabled: enabled, changeSet: changeSet != nil ? Self.makeSet(tr.doc, []) : nil)
            }
        }
        guard tr.docChanged, let set = changeSet else { return self }
        if enabled {
            return SuggestionModeState(enabled: true, changeSet: set.addSteps(tr.doc, tr.mapping.maps, author))
        }
        // Suggesting is off but suggestions are pending: the changeset must
        // still track the edit so its coordinates stay valid. Record it with
        // the committed marker, then fold purely-committed changes into the
        // base so they don't linger as suggestions.
        var s = set.addSteps(tr.doc, tr.mapping.maps, committedData)
        while let i = s.changes.firstIndex(where: { c in
            !(c.deleted.isEmpty && c.inserted.isEmpty)
                && c.deleted.allSatisfy { $0.data == committedData }
                && c.inserted.allSatisfy { $0.data == committedData }
        }) {
            s = Self.accepting(s, i, doc: tr.doc)
        }
        return SuggestionModeState(enabled: false, changeSet: s)
    }
}

public let suggestionModeKey = PluginKey<SuggestionModeState>("suggestionMode")
private let suggestionModeMeta = "suggestionMode$"

private enum SuggestionAction {
    case setEnabled(Bool)
    case accept(Int)
    case reject(Int)
    case acceptAll
    case rejectAll
}

/// Create the suggestion-mode plugin. `author` is recorded on every span this
/// editor produces (shown via the decorations' data-author attribute).
public func suggestionMode(author: String = "user") -> Plugin {
    Plugin(
        key: suggestionModeKey.key,
        stateField: PluginStateField(
            initialize: { _, _ in SuggestionModeState(enabled: false, changeSet: nil) },
            apply: { tr, value, _, _ in (value as! SuggestionModeState).apply(tr, author: author) }),
        props: PluginProps(decorations: { state in suggestionDecorations(state) }))
}

/// Inline "insertion" decorations over suggested insertions and "deletion"
/// widgets (carrying the removed text in data-text) at deletion points.
public func suggestionDecorations(_ state: EditorState) -> DecorationSet? {
    guard let pluginState = suggestionModeKey.getState(state), let set = pluginState.changeSet,
          !set.changes.isEmpty else { return nil }
    var decorations: [Decoration] = []
    for change in set.changes {
        var offset = change.fromB
        for span in change.inserted {
            if span.data != committedData {
                decorations.append(.inline(offset, offset + span.length,
                                           ["class": "insertion", "data-author": span.data]))
            }
            offset += span.length
        }
        var baseOffset = change.fromA
        var deletedText = ""
        var author = ""
        for span in change.deleted {
            if span.data != committedData {
                deletedText += set.startDoc.textBetween(baseOffset, baseOffset + span.length, blockSeparator: "\n")
                author = span.data
            }
            baseOffset += span.length
        }
        if !deletedText.isEmpty {
            decorations.append(.widget(change.fromB,
                                       ["class": "deletion", "data-text": deletedText, "data-author": author]))
        }
    }
    return decorations.isEmpty ? nil : DecorationSet(decorations)
}

// MARK: - Commands

/// Mark a transaction as turning suggestion recording on or off.
@discardableResult
public func setSuggestionMode(_ tr: Transaction, enabled: Bool) -> Transaction {
    tr.setMeta(suggestionModeMeta, SuggestionAction.setEnabled(enabled))
}

public let toggleSuggestionMode: Command = { state, dispatch, _ in
    guard let pluginState = suggestionModeKey.getState(state) else { return false }
    dispatch?(setSuggestionMode(state.tr, enabled: !pluginState.enabled))
    return true
}

/// The index of the suggestion touching `pos`, if any.
public func suggestionIndex(at pos: Int, _ state: EditorState) -> Int? {
    suggestionModeKey.getState(state)?.changes.firstIndex { $0.fromB <= pos && pos <= $0.toB }
}

/// Accept the suggestion at `index`: the document keeps its content and the
/// change stops being a suggestion.
public func acceptSuggestion(_ index: Int) -> Command {
    { state, dispatch, _ in
        guard let pluginState = suggestionModeKey.getState(state),
              pluginState.changes.indices.contains(index) else { return false }
        dispatch?(state.tr.setMeta(suggestionModeMeta, SuggestionAction.accept(index)))
        return true
    }
}

/// Reject the suggestion at `index`: the document's range is replaced with the
/// base document's content for that change.
public func rejectSuggestion(_ index: Int) -> Command {
    { state, dispatch, _ in
        guard let pluginState = suggestionModeKey.getState(state), let set = pluginState.changeSet,
              set.changes.indices.contains(index) else { return false }
        let change = set.changes[index]
        let tr = state.tr
        guard (try? tr.replace(change.fromB, change.toB, set.startDoc.slice(change.fromA, change.toA))) != nil
        else { return false }
        dispatch?(tr.setMeta(suggestionModeMeta, SuggestionAction.reject(index)))
        return true
    }
}

public let acceptAllSuggestions: Command = { state, dispatch, _ in
    guard let pluginState = suggestionModeKey.getState(state), !pluginState.changes.isEmpty
    else { return false }
    dispatch?(state.tr.setMeta(suggestionModeMeta, SuggestionAction.acceptAll))
    return true
}

public let rejectAllSuggestions: Command = { state, dispatch, _ in
    guard let pluginState = suggestionModeKey.getState(state), let set = pluginState.changeSet,
          !set.changes.isEmpty else { return false }
    let tr = state.tr
    // Back to front so earlier changes' positions stay valid.
    for change in set.changes.reversed() {
        guard (try? tr.replace(change.fromB, change.toB, set.startDoc.slice(change.fromA, change.toA))) != nil
        else { return false }
    }
    dispatch?(tr.setMeta(suggestionModeMeta, SuggestionAction.rejectAll))
    return true
}

/// Contributes the suggestion-mode (track changes) plugin. Off by default;
/// toggle with `toggleSuggestionMode`.
public final class SuggestionModeExtension: Extension {
    public let name = "suggestionMode"
    let author: String
    public init(author: String = "user") { self.author = author }
    public func plugins(_ ctx: ExtensionContext) -> [Plugin] { [suggestionMode(author: author)] }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        [
            "toggleSuggestionMode": toggleSuggestionMode,
            "acceptAllSuggestions": acceptAllSuggestions,
            "rejectAllSuggestions": rejectAllSuggestions,
        ]
    }
}
