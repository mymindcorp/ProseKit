import DocumentModel
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
