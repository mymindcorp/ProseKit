import DocumentModel
import EditorStateKit

/// The active query for a suggestion menu and the document range it replaces.
public struct SuggestionContext: Equatable {
    public var from: Int
    public var to: Int
    public var query: String
    public init(from: Int, to: Int, query: String) {
        self.from = from
        self.to = to
        self.query = query
    }
}

/// One selectable row in a suggestion popup, with the action to run when chosen.
public struct SuggestionEntry {
    public var title: String
    public var subtitle: String?
    public var apply: (Editor) -> Void
    public init(title: String, subtitle: String? = nil, apply: @escaping (Editor) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.apply = apply
    }
}

/// A self-contained source of suggestions — the `/` slash menu, `[[` wiki links,
/// `@` mentions, etc. An extension provides one (or several) via
/// `Extension.suggestionSources`; the renderer drives the popup generically, so
/// it never needs to know about any particular trigger.
public protocol SuggestionSource: AnyObject {
    /// The active context (its trigger fired and a query is being typed), or nil.
    func context(_ editor: Editor) -> SuggestionContext?
    /// The entries to offer for the active query.
    func entries(_ query: String, _ editor: Editor) -> [SuggestionEntry]
}
