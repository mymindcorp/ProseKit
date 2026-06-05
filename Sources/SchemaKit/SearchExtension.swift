import DocumentModel
import DocumentTransform
import EditorStateKit

/// Search/replace state: the active query and which match is "current".
public final class SearchState {
    public let query: String
    public let caseSensitive: Bool
    public let currentIndex: Int
    init(query: String, caseSensitive: Bool, currentIndex: Int) {
        self.query = query
        self.caseSensitive = caseSensitive
        self.currentIndex = currentIndex
    }
}

/// Contributes the search/highlight plugin to an editor.
public final class SearchExtension: Extension {
    public let name = "search"
    public init() {}
    public func plugins(_ ctx: ExtensionContext) -> [Plugin] { [searchPlugin()] }
}

public let searchKey = PluginKey<SearchState>("search")
private let setQueryMeta = "search.setQuery"
private let setIndexMeta = "search.setIndex"

/// A plugin that highlights search matches as decorations. Drive it via the
/// `Editor` search API below.
public func searchPlugin() -> Plugin {
    Plugin(
        key: searchKey.key,
        stateField: PluginStateField(
            initialize: { _, _ in SearchState(query: "", caseSensitive: false, currentIndex: 0) },
            apply: { tr, value, _, _ in
                let state = value as! SearchState
                if let (q, cs) = tr.getMeta(setQueryMeta) as? (String, Bool) {
                    return SearchState(query: q, caseSensitive: cs, currentIndex: -1) // -1 = before first match
                }
                if let idx = tr.getMeta(setIndexMeta) as? Int {
                    return SearchState(query: state.query, caseSensitive: state.caseSensitive, currentIndex: idx)
                }
                return state
            }),
        props: PluginProps(decorations: { editorState in
            guard let s = searchKey.getState(editorState), !s.query.isEmpty else { return nil }
            let matches = TextSearch.matches(in: editorState.doc, query: s.query, caseSensitive: s.caseSensitive)
            let decos = matches.enumerated().map { i, m -> Decoration in
                let isCurrent = i == s.currentIndex
                return .inline(m.from, m.to, [
                    "class": isCurrent ? "search-current" : "search",
                    "background": isCurrent ? "#FFB300" : "#FFE082",
                ])
            }
            return DecorationSet(decos)
        }))
}

public extension Editor {
    var searchState: SearchState? { searchKey.getState(state) }

    /// The current search matches (recomputed from the live document).
    var searchMatches: [TextSearch.Match] {
        guard let s = searchState, !s.query.isEmpty else { return [] }
        return TextSearch.matches(in: doc, query: s.query, caseSensitive: s.caseSensitive)
    }

    /// Set the active search query (empty clears it).
    func setSearch(_ query: String, caseSensitive: Bool = false) {
        dispatch(state.tr.setMeta(setQueryMeta, (query, caseSensitive)))
    }

    func clearSearch() { setSearch("") }

    /// Move the selection to the next/previous match, wrapping around.
    func findNext() { moveToMatch(by: 1) }
    func findPrevious() { moveToMatch(by: -1) }

    private func moveToMatch(by delta: Int) {
        let matches = searchMatches
        guard !matches.isEmpty, let s = searchState else { return }
        let count = matches.count
        // From "before first" (-1), forward picks match 0 and backward the last.
        let base = s.currentIndex < 0 ? (delta > 0 ? -1 : 0) : s.currentIndex
        let index = ((base + delta) % count + count) % count
        let match = matches[index]
        let tr = state.tr.setMeta(setIndexMeta, index)
        tr.setSelection(TextSelection.create(tr.doc, match.from, match.to)).scrollIntoView()
        dispatch(tr)
    }

    /// Replace the current match with the given text. Returns false if there is
    /// no current match.
    @discardableResult
    func replaceCurrentMatch(with replacement: String) -> Bool {
        let matches = searchMatches
        guard let s = searchState, s.currentIndex < matches.count else { return false }
        let match = matches[s.currentIndex]
        let tr = state.tr
        try? tr.insertText(replacement, match.from, match.to)
        dispatch(tr.scrollIntoView())
        return true
    }

    /// Replace every match with the given text. Returns the number replaced.
    @discardableResult
    func replaceAllMatches(with replacement: String) -> Int {
        let matches = searchMatches
        guard !matches.isEmpty else { return 0 }
        let tr = state.tr
        // Replace from the end so earlier positions stay valid.
        for match in matches.reversed() {
            try? tr.insertText(replacement, match.from, match.to)
        }
        dispatch(tr)
        return matches.count
    }
}
