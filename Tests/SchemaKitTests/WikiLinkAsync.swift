import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

/// Thread-safe record of the queries the async provider was asked for. The
/// provider closure is `@Sendable` and may run off the main actor, so guard it.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    func record(_ q: String) { lock.lock(); queries.append(q); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return queries }
    var count: Int { all.count }
}

/// Spin the main run loop until `predicate()` holds or `timeout` elapses, so the
/// source's debounced `Task` (a main-actor job) gets a chance to run under the
/// synchronous CLT test harness.
private func pumpMain(timeout: TimeInterval = 3, until predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

/// Build an editor whose `[[` popup is backed by an async provider, type the
/// given trigger, and return (editor, the active wiki suggestion source, log).
@MainActor
private func asyncWikiSetup(typing trigger: String,
                            provider: @escaping @Sendable (String, CallLog) -> [String])
    throws -> (Editor, any SuggestionSource, CallLog) {
    let log = CallLog()
    let editor = try Editor(extensions: fullKit(wikiLinkAsyncSuggestions: { q in
        log.record(q)
        return provider(q, log)
    }))
    try type(editor, trigger)
    try expectNotNil(editor.suggestionSources.first(where: { $0.context(editor) != nil }))
    let source = editor.suggestionSources.first { $0.context(editor) != nil }!
    return (editor, source, log)
}

func registerWikiLinkAsyncTests() {
    test("wiki async: empty until the fetch resolves, then shows results") {
        MainActor.assumeIsolated {
            let (editor, source, log) = try! asyncWikiSetup(typing: "[[Arc") { q, _ in
                ["Architecture", "Archive"].filter { $0.hasPrefix(q) }
            }
            // First pull triggers the fetch but has nothing cached yet.
            try! expect(source.entries("Arc", editor).isEmpty, "no results before the fetch resolves")
            var changed = false
            source.onChange = { changed = true }
            pumpMain { changed }
            try! expect(changed, "onChange should fire once results arrive")
            let titles = source.entries("Arc", editor).map(\.title)
            try! expectEqual(titles, ["Architecture", "Archive"])
            try! expectEqual(log.count, 1)
        }
    }

    test("wiki async: repeated pulls of the same query fetch only once") {
        MainActor.assumeIsolated {
            let (editor, source, log) = try! asyncWikiSetup(typing: "[[A") { q, _ in [q] }
            // Every keystroke *and* every scroll frame re-pulls; the source must
            // not restart (and reset the debounce on) an unchanged query.
            for _ in 0..<20 { _ = source.entries("A", editor) }
            var ready = false
            source.onChange = { ready = true }
            pumpMain { ready }
            // Keep pulling after it resolved — still no extra fetch.
            for _ in 0..<20 { _ = source.entries("A", editor) }
            try! expectEqual(log.count, 1, "one fetch for one distinct query")
        }
    }

    test("wiki async: a newer query cancels the in-flight one (debounced)") {
        MainActor.assumeIsolated {
            let (editor, source, log) = try! asyncWikiSetup(typing: "[[Arc") { q, _ in [q] }
            // Drive successive queries faster than the debounce; only the last
            // should survive to actually hit the provider.
            _ = source.entries("A", editor)
            _ = source.entries("Ar", editor)
            _ = source.entries("Arc", editor)
            var ready = false
            source.onChange = { ready = true }
            pumpMain { ready }
            try! expectEqual(log.all, ["Arc"], "earlier queries are cancelled before they fetch")
            try! expectEqual(source.entries("Arc", editor).map(\.title), ["Arc"])
        }
    }

    test("wiki async: stale results stay visible while a newer query is in flight") {
        MainActor.assumeIsolated {
            let (editor, source, log) = try! asyncWikiSetup(typing: "[[Ar") { q, _ in [q] }
            var ready = false
            source.onChange = { ready = true }
            _ = source.entries("Ar", editor)
            pumpMain { ready }
            try! expectEqual(source.entries("Ar", editor).map(\.title), ["Ar"])
            // A new query starts fetching; until it resolves the popup keeps the
            // previous results rather than blinking empty.
            ready = false
            try! expectEqual(source.entries("Arc", editor).map(\.title), ["Ar"],
                             "previous results remain while the new query loads")
            pumpMain { ready }
            try! expectEqual(source.entries("Arc", editor).map(\.title), ["Arc"])
            try! expectEqual(log.all, ["Ar", "Arc"])
        }
    }

    test("wiki async: no active suggestion returns empty and fetches nothing") {
        MainActor.assumeIsolated {
            let (editor, source, log) = try! asyncWikiSetup(typing: "[[Arc") { q, _ in [q] }
            // Move the caret away, which clears the live `[[` suggestion.
            select(editor, 1, 1)
            try! expect(editor.wikiLinkSuggestion == nil)
            try! expect(source.entries("Arc", editor).isEmpty, "no popup without an active trigger")
            // Give any stray task a chance to (not) run.
            pumpMain(timeout: 0.3) { false }
            try! expectEqual(log.count, 0, "a missing trigger must not fetch")
        }
    }

    test("wiki: the query hands the provider a trimmed page name") {
        MainActor.assumeIsolated {
            // `[[ Arc` names the same page as `[[Arc` — the spacing after the
            // brackets is spacing (the input rule trims the target too). Handing
            // " Arc" to a substring-matching provider finds nothing, and the
            // popup blinks out mid-word.
            let (editor, source, log) = try! asyncWikiSetup(typing: "[[ Arc") { q, _ in
                ["Architecture", "Archive"].filter { $0.hasPrefix(q) }
            }
            let context = source.context(editor)!
            try! expectEqual(context.query, "Arc")
            // The range still covers the space, so accepting replaces it.
            try! expectEqual(editor.doc.textBetween(context.from, context.to), "[[ Arc")
            var ready = false
            source.onChange = { ready = true }
            _ = source.entries(context.query, editor)
            pumpMain { ready }
            try! expectEqual(source.entries(context.query, editor).map(\.title),
                             ["Architecture", "Archive"])
            try! expectEqual(log.all, ["Arc"], "the provider never sees the spacing")
        }
    }

    // MARK: - Synchronous sources (only covered by the iOS view tests otherwise)

    test("wiki sync: provider results become entries whose apply inserts a wikiLink") {
        MainActor.assumeIsolated {
            let editor = try! Editor(extensions: fullKit(wikiLinkSuggestions: { q in
                ["Home", "Architecture"].filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
            }))
            try! type(editor, "[[Arch")
            let source = editor.suggestionSources.first { $0.context(editor) != nil }!
            try! expect(source.onChange == nil, "a sync source has no refresh hook (default no-op)")
            let entries = source.entries("Arch", editor)
            try! expectEqual(entries.map(\.title), ["Architecture"])
            entries[0].apply(editor)
            var target: String?
            editor.doc.descendants { n, _, _, _ in
                if n.type.name == "wikiLink" { target = n.attrs["text"]?.stringValue }
                return true
            }
            try! expectEqual(target, "Architecture")
            try! expect(editor.wikiLinkSuggestion == nil, "applying consumes the `[[` query")
        }
    }

    test("wiki sync: a spaced query is trimmed too, and accepting eats the space") {
        MainActor.assumeIsolated {
            let editor = try! Editor(extensions: fullKit(wikiLinkSuggestions: { q in
                ["Home", "Architecture"].filter { q.isEmpty || $0.hasPrefix(q) }
            }))
            try! type(editor, "[[  Arch")
            let source = editor.suggestionSources.first { $0.context(editor) != nil }!
            let context = source.context(editor)!
            try! expectEqual(context.query, "Arch")
            let entries = source.entries(context.query, editor)
            try! expectEqual(entries.map(\.title), ["Architecture"])
            entries[0].apply(editor)
            try! expectEqual(editor.doc.textContent, "Architecture",
                             "the brackets and the spacing go with the query")
        }
    }

    test("mention sync: provider results become @entries whose apply inserts a mention") {
        MainActor.assumeIsolated {
            let editor = try! Editor(extensions: fullKit(mentionSuggestions: { q in
                ["jose", "jane"].filter { $0.hasPrefix(q) }
            }))
            try! type(editor, "hi @ja")
            let source = editor.suggestionSources.first { $0.context(editor) != nil }!
            let entries = source.entries("ja", editor)
            try! expectEqual(entries.map(\.title), ["@jane"])
            entries[0].apply(editor)
            var id: String?
            editor.doc.descendants { n, _, _, _ in
                if n.type.name == "mention" { id = n.attrs["id"]?.stringValue }
                return true
            }
            try! expectEqual(id, "jane")
            try! expect(editor.mentionSuggestion == nil, "applying consumes the `@` query")
        }
    }

    test("mention async: the generic source fetches @ candidates and applies one") {
        MainActor.assumeIsolated {
            let log = CallLog()
            let editor = try! Editor(extensions: fullKit(mentionAsyncSuggestions: { q in
                log.record(q)
                return ["jose", "jane"].filter { $0.hasPrefix(q) }
            }))
            try! type(editor, "hi @j")
            let source = editor.suggestionSources.first { $0.context(editor) != nil }!
            try! expect(source.entries("j", editor).isEmpty, "nothing cached before the fetch resolves")
            var ready = false
            source.onChange = { ready = true }
            pumpMain { ready }
            let entries = source.entries("j", editor)
            try! expectEqual(entries.map(\.title), ["@jose", "@jane"])
            try! expectEqual(log.count, 1)
            entries[1].apply(editor)
            var id: String?
            editor.doc.descendants { n, _, _, _ in
                if n.type.name == "mention" { id = n.attrs["id"]?.stringValue }
                return true
            }
            try! expectEqual(id, "jane")
        }
    }
}
