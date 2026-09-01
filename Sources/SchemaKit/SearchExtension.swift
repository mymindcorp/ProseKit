import DocumentModel
import DocumentTransform
public import EditorStateKit

/// Contributes the search/highlight plugin (EditorStateKit's prosemirror-search
/// port) to an editor, and a Tiptap-flavored facade over its query state and
/// commands. The find bar drives the facade; everything below it is the
/// official engine — string or regexp queries, case-sensitivity, whole-word.
public final class SearchExtension: Extension {
    public let name = "search"
    public init() {}
    public func plugins(_ ctx: ExtensionContext) -> [Plugin] { [searchQueryPlugin()] }
}

public extension Editor {
    /// The active search query (nil when the search plugin isn't installed).
    var searchQuery: SearchQuery? { searchQueryKey.getState(state)?.query }

    /// All matches of the active query, in document order.
    var searchMatches: [(from: Int, to: Int)] {
        guard let qs = searchQueryKey.getState(state), qs.query.valid else { return [] }
        var result: [(from: Int, to: Int)] = []
        var pos = qs.range?.from ?? 0
        let end = qs.range?.to ?? state.doc.content.size
        while let next = qs.query.findNext(state, pos, end) {
            result.append((next.from, next.to))
            // Always forward: a matcher that ever handed back an empty match at
            // `pos` would otherwise keep this loop — and the memory it fills —
            // going until the process was killed.
            pos = Swift.max(next.to, pos + 1)
        }
        return result
    }

    /// The index of the match the selection sits on, or -1 — drives "n of m".
    /// (The engine has no stored cursor; the active match IS the selection.)
    var currentSearchMatchIndex: Int {
        let sel = state.selection
        return searchMatches.firstIndex { $0.from == sel.from && $0.to == sel.to } ?? -1
    }

    /// Set the active search query (empty clears it).
    func setSearch(_ query: String, caseSensitive: Bool = false, regexp: Bool = false, wholeWord: Bool = false) {
        dispatch(setSearchState(state.tr, SearchQuery(
            search: query, caseSensitive: caseSensitive, regexp: regexp, wholeWord: wholeWord)))
    }

    func clearSearch() { setSearch("") }

    /// Move the selection to the next/previous match, wrapping around.
    func findNext() { _ = EditorStateKit.findNext(state) { [weak self] tr in self?.dispatch(tr) } }
    func findPrevious() { _ = EditorStateKit.findPrev(state) { [weak self] tr in self?.dispatch(tr) } }

    /// Replace the match the selection sits on (or the first match when the
    /// selection isn't on one). Returns false if there is no match.
    @discardableResult
    func replaceCurrentMatch(with replacement: String) -> Bool {
        guard let qs = searchQueryKey.getState(state), qs.query.valid else { return false }
        let query = qs.query.withReplace(replacement)
        let sel = state.selection
        let range = qs.range ?? SearchRange(from: 0, to: state.doc.content.size)
        var match = query.findNext(state, range.from, range.to)
        if let atSelection = query.findNext(state, sel.from, range.to),
           atSelection.from == sel.from, atSelection.to == sel.to {
            match = atSelection
        }
        guard let match else { return false }
        let tr = state.tr
        for repl in query.getReplacements(state, match).reversed() {
            _ = try? tr.replace(repl.from, repl.to, repl.insert)
        }
        dispatch(tr.scrollIntoView())
        return true
    }

    /// Replace every match with the given text. Returns the number replaced.
    @discardableResult
    func replaceAllMatches(with replacement: String) -> Int {
        guard let qs = searchQueryKey.getState(state), qs.query.valid else { return 0 }
        let query = qs.query.withReplace(replacement)
        let range = qs.range ?? SearchRange(from: 0, to: state.doc.content.size)
        var matches: [SearchResult] = []
        var pos = range.from
        while let next = query.findNext(state, pos, range.to) {
            matches.append(next)
            pos = Swift.max(next.to, pos + 1) // see `searchMatches`
        }
        guard !matches.isEmpty else { return 0 }
        let tr = state.tr
        for match in matches.reversed() {
            for repl in query.getReplacements(state, match).reversed() {
                _ = try? tr.replace(repl.from, repl.to, repl.insert)
            }
        }
        dispatch(tr)
        return matches.count
    }
}

extension SearchQuery {
    /// A copy of this query with different replace text.
    func withReplace(_ replacement: String) -> SearchQuery {
        SearchQuery(search: search, caseSensitive: caseSensitive, literal: literal,
                    regexp: regexp, replace: replacement, wholeWord: wholeWord, filter: filter)
    }
}
