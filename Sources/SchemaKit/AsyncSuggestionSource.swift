import Foundation

/// Drives a suggestion popup from an asynchronous source — a DB or search-index
/// lookup. It debounces fetches, cancels superseded queries, caches the latest
/// results (stale-while-revalidate, so the popup keeps showing the previous
/// results while a newer query loads instead of blinking empty), and asks the
/// renderer to repaint via `onChange`.
///
/// It is generic over the trigger: `locate` finds the active query for this
/// editor (returning nil when no trigger is live), and `build` turns the fetched
/// ids plus that context into popup entries. Both `[[` wiki-links and `@`
/// mentions reuse it; a new trigger needs only its own two closures.
@MainActor
final class AsyncSuggestionSource: SuggestionSource {
    private let provider: @Sendable (String) async -> [String]
    private let locate: @MainActor (Editor) -> SuggestionContext?
    private let build: @MainActor ([String], SuggestionContext) -> [SuggestionEntry]
    private let debounce: Duration
    var onChange: (() -> Void)?

    private var cachedQuery: String?
    private var pendingQuery: String?
    private var cached: [String] = []
    private var task: Task<Void, Never>?

    nonisolated init(provider: @escaping @Sendable (String) async -> [String],
                     debounce: Duration = .milliseconds(180),
                     locate: @escaping @MainActor (Editor) -> SuggestionContext?,
                     build: @escaping @MainActor ([String], SuggestionContext) -> [SuggestionEntry]) {
        self.provider = provider
        self.debounce = debounce
        self.locate = locate
        self.build = build
    }

    func context(_ editor: Editor) -> SuggestionContext? { locate(editor) }

    func entries(_ query: String, _ editor: Editor) -> [SuggestionEntry] {
        guard let ctx = locate(editor) else {
            task?.cancel(); pendingQuery = nil; return []
        }
        // Refresh only when this query is neither already shown nor in flight (so
        // repeated pulls — every keystroke *and* every scroll frame — don't restart
        // the fetch and reset its debounce forever).
        if query != cachedQuery, query != pendingQuery { fetch(query) }
        return build(cached, ctx)
    }

    private func fetch(_ query: String) {
        task?.cancel()
        pendingQuery = query
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            if Task.isCancelled { return }
            let results = await self.provider(query)
            if Task.isCancelled { return }
            self.cachedQuery = query
            self.pendingQuery = nil
            self.cached = results
            self.onChange?()
        }
    }
}
