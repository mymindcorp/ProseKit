import DocumentModel
import DocumentTransform
import EditorStateKit

/// The active query for a suggestion menu and the document range it replaces.
public struct SuggestionContext: Equatable {
    public let from: Int
    public let to: Int
    public let query: String
    public init(from: Int, to: Int, query: String) {
        self.from = from
        self.to = to
        self.query = query
    }
}

/// One selectable row in a suggestion popup, with the action to run when chosen.
public struct SuggestionEntry {
    public let title: String
    public let subtitle: String?
    /// An optional SF Symbol name shown as a leading glyph (the renderer falls
    /// back to a generic icon when nil).
    public let icon: String?
    public let apply: (Editor) -> Void
    public init(title: String, subtitle: String? = nil, icon: String? = nil, apply: @escaping (Editor) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.apply = apply
    }
}

/// A menu row captures document positions. Selection changes (including the
/// tap that accepts it) are fine, but a document edit makes those positions
/// stale. Let the next popup refresh provide a new row instead of applying an
/// old row to unrelated text.
@MainActor
func guardSuggestionEntries(_ entries: [SuggestionEntry], in editor: Editor) -> [SuggestionEntry] {
    let doc = editor.doc
    return entries.map { entry in
        SuggestionEntry(title: entry.title, subtitle: entry.subtitle, icon: entry.icon) { current in
            guard current.doc == doc else { return }
            entry.apply(current)
        }
    }
}

func suggestionCrossesHardBreak(_ parent: Node, from: Int, to: Int) -> Bool {
    var found = false
    parent.nodesBetween(from, to, { node, _, _, _ in
        if node.type.name == "hardBreak" { found = true }
        return !found
    })
    return found
}

/// Explicit suggestion ranges can outlive the text that created them. Bounds
/// must be checked before resolving positions, and the replacement must fit
/// exactly: a fitter may move an inline atom outside a text-only block while
/// deleting the query it was supposed to replace in place.
func replaceSuggestionRange(_ editor: Editor, from: Int, to: Int, with node: Node) -> Bool {
    let start = min(from, to), end = max(from, to)
    guard start >= 0, end <= editor.doc.content.size else { return false }
    let tr = editor.state.tr
    let slice = Slice(content: Fragment.from(node), openStart: 0, openEnd: 0)
    guard (try? tr.step(ReplaceStep(start, end, slice))) != nil else { return false }
    editor.dispatch(tr.scrollIntoView())
    return true
}

/// A self-contained source of suggestions — the `/` slash menu, `[[` wiki links,
/// `@` mentions, etc. An extension provides one (or several) via
/// `Extension.suggestionSources`; the renderer drives the popup generically, so
/// it never needs to know about any particular trigger.
///
/// `@MainActor` because the renderer that pulls from it is main-actor UI. The
/// pull (`entries`) is synchronous so local sources render in the same pass; a
/// source that fetches asynchronously returns what it has now and calls
/// `onChange` when fresh results arrive, prompting the renderer to re-pull.
@MainActor
public protocol SuggestionSource: AnyObject {
    /// The active context (its trigger fired and a query is being typed), or nil.
    func context(_ editor: Editor) -> SuggestionContext?
    /// The entries to offer for the active query. Must return synchronously; an
    /// async source returns cached/empty results and refreshes via `onChange`.
    func entries(_ query: String, _ editor: Editor) -> [SuggestionEntry]
    /// Set by the renderer; a source calls it when asynchronously-loaded entries
    /// become available, so the open popup is re-pulled and repainted. Sync
    /// sources can ignore it (the default is a no-op).
    var onChange: (() -> Void)? { get set }
}

public extension SuggestionSource {
    var onChange: (() -> Void)? { get { nil } set {} } // sync sources don't refresh
}

/// Where a typed trigger may open a popup: running prose that can actually hold
/// the node the trigger inserts. Code is literal text — a `[[` there means
/// brackets and an `@` means an `@` — and the schema has the last word: a
/// textblock that can't hold the node can't be offered it, or accepting the
/// suggestion would build a document the schema rejects.
///
/// `excludingHeadings` is the caller's judgment about prose rather than a
/// schema matter: a wiki-link treats a heading as a title, not prose, while a
/// mention in a title is ordinary.
func isSuggestionContext(_ parent: Node, state: EditorState, cursor: ResolvedPos,
                         inserting type: NodeType, excludingHeadings: Bool) -> Bool {
    guard parent.isTextblock, !parent.type.spec.code,
          !(excludingHeadings && parent.type.name == "heading"),
          parent.type.contentMatch.matchType(type) != nil else { return false }
    // An inline code span is code too, even in a paragraph. `storedMarks` is
    // what the next character would take on, which is what matters at a
    // boundary where the cursor's own marks haven't caught up yet.
    let marks = state.storedMarks ?? cursor.marks()
    return !marks.contains { $0.type.spec.code }
}
