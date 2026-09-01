import Foundation
public import DocumentModel
import DocumentTransform

// A port of prosemirror-search: SearchQuery (string/regexp matching with
// case-sensitivity, literal mode, whole-word filtering and $1/$&-style
// replacements), a plugin that highlights matches, and find/replace commands.
//
// Differences from upstream: regular expressions use NSRegularExpression
// (ICU syntax rather than JS), match offsets are converted from UTF-16 to this
// model's grapheme-based positions, and the per-node text cache is dropped
// (Nodes are value types here; recomputing per textblock is cheap).

/// One regexp group of a match: its content-relative character range (nil when
/// the group didn't participate) and its text.
public struct SearchMatchGroup: Sendable {
    public let range: Range<Int>?
    public let text: String?
}

/// A matched instance of a search query. `match` is non-nil only for regular
/// expression queries; group 0 is the whole match.
public struct SearchResult {
    public let from: Int
    public let to: Int
    public let match: [SearchMatchGroup]?
    public let matchStart: Int
}

public final class SearchQuery: @unchecked Sendable {
    /// The search string (or regular expression source).
    public let search: String
    public let caseSensitive: Bool
    /// Disables the default `\n`/`\r`/`\t` unescaping in string queries.
    public let literal: Bool
    /// When true, the search string is a regular expression.
    public let regexp: Bool
    /// The replace text ("" when none).
    public let replace: String
    /// Whether the query is non-empty and (for regexps) syntactically valid.
    public let valid: Bool
    /// When true, matches with further word characters around them are ignored.
    public let wholeWord: Bool
    /// Optional filter; results it rejects are skipped.
    public let filter: ((EditorState, SearchResult) -> Bool)?

    private let impl: any QueryImpl

    public init(search: String, caseSensitive: Bool = false, literal: Bool = false,
                regexp: Bool = false, replace: String = "", wholeWord: Bool = false,
                filter: ((EditorState, SearchResult) -> Bool)? = nil) {
        self.search = search
        self.caseSensitive = caseSensitive
        self.literal = literal
        self.regexp = regexp
        self.replace = replace
        self.wholeWord = wholeWord
        self.filter = filter
        let valid = !search.isEmpty && !(regexp && !validRegExp(search))
        self.valid = valid
        let unquoted = literal ? search
            : SearchQuery.unquoteString(search)
        if !valid {
            self.impl = NullQuery()
        } else if regexp {
            self.impl = RegExpQuery(pattern: search, caseSensitive: caseSensitive) ?? NullQuery()
        } else {
            self.impl = StringQuery(string: caseSensitive ? unquoted : unquoted.lowercased(),
                                    caseSensitive: caseSensitive)
        }
    }

    public func eq(_ other: SearchQuery) -> Bool {
        search == other.search && replace == other.replace
            && caseSensitive == other.caseSensitive && regexp == other.regexp
            && wholeWord == other.wholeWord
    }

    /// Find the next occurrence in [from, to).
    public func findNext(_ state: EditorState, _ from: Int = 0, _ to: Int? = nil) -> SearchResult? {
        let to = to ?? state.doc.content.size
        var from = from
        while true {
            if from >= to { return nil }
            guard let result = impl.findNext(state, from, to) else { return nil }
            if checkResult(state, result) { return result }
            from = result.from + 1
        }
    }

    /// Find the previous occurrence searching back from `from` down to `to`.
    public func findPrev(_ state: EditorState, _ from: Int? = nil, _ to: Int = 0) -> SearchResult? {
        var from = from ?? state.doc.content.size
        while true {
            if from <= to { return nil }
            guard let result = impl.findPrev(state, from, to) else { return nil }
            if checkResult(state, result) { return result }
            from = result.to - 1
        }
    }

    func checkResult(_ state: EditorState, _ result: SearchResult) -> Bool {
        (!wholeWord || (checkWordBoundary(state, result.from) && checkWordBoundary(state, result.to)))
            && (filter?(state, result) ?? true)
    }

    func unquote(_ string: String) -> String {
        literal ? string : SearchQuery.unquoteString(string)
    }

    private static func unquoteString(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, "nrt\\".contains(chars[i + 1]) {
                switch chars[i + 1] {
                case "n": out += "\n"
                case "r": out += "\r"
                case "t": out += "\t"
                default: out += "\\"
                }
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// The ranges to replace for a result. Multiple ranges occur when `replace`
    /// contains `$1`/`$&` placeholders whose first use preserves the original
    /// content in place. Apply back-to-front (or map through the transaction).
    public func getReplacements(_ state: EditorState, _ result: SearchResult) -> [(from: Int, to: Int, insert: Slice)] {
        let resolvedFrom = state.doc.resolve(result.from)
        let marks = resolvedFrom.marksAcross(state.doc.resolve(result.to)) ?? []
        var ranges: [(from: Int, to: Int, insert: Slice)] = []

        var frag = Fragment.empty
        var pos = result.from
        let groups = result.match ?? [SearchMatchGroup(range: 0..<(result.to - result.from), text: nil)]
        for part in parseReplacement(unquote(replace)) {
            switch part {
            case .text(let text):
                frag = frag.addToEnd(state.schema.text(text, marks))
            case .group(let n, let copy):
                guard n < groups.count, let span = groups[n].range else { continue }
                let from = result.matchStart + span.lowerBound
                let to = result.matchStart + span.upperBound
                if copy {
                    frag = frag.append(state.doc.slice(from, to).content)
                } else {
                    if frag.childCount > 0 || from > pos {
                        ranges.append((pos, from, Slice(content: frag, openStart: 0, openEnd: 0)))
                        frag = .empty
                    }
                    pos = to
                }
            }
        }
        if frag.childCount > 0 || pos < result.to {
            ranges.append((pos, result.to, Slice(content: frag, openStart: 0, openEnd: 0)))
        }
        return ranges
    }
}

// MARK: - Query implementations

private protocol QueryImpl {
    func findNext(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult?
    func findPrev(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult?
}

private struct NullQuery: QueryImpl {
    func findNext(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult? { nil }
    func findPrev(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult? { nil }
}

private struct StringQuery: QueryImpl {
    let string: String
    let caseSensitive: Bool

    func findNext(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult? {
        scanTextblocks(state.doc, from, to) { node, start in
            let content = blockText(node)
            let off = max(from, start)
            let lo = off - start, hi = min(node.content.size, to - start)
            guard lo < hi, hi <= content.count else { return nil }
            var hay = String(content[content.index(content.startIndex, offsetBy: lo)..<content.index(content.startIndex, offsetBy: hi)])
            if !caseSensitive { hay = hay.lowercased() }
            guard let r = hay.range(of: string) else { return nil }
            let index = hay.distance(from: hay.startIndex, to: r.lowerBound)
            return SearchResult(from: off + index, to: off + index + string.count, match: nil, matchStart: start)
        }
    }

    func findPrev(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult? {
        scanTextblocks(state.doc, from, to) { node, start in
            let content = blockText(node)
            let off = max(start, to)
            let lo = off - start, hi = min(node.content.size, from - start)
            guard lo < hi, hi <= content.count else { return nil }
            var hay = String(content[content.index(content.startIndex, offsetBy: lo)..<content.index(content.startIndex, offsetBy: hi)])
            if !caseSensitive { hay = hay.lowercased() }
            guard let r = hay.range(of: string, options: .backwards) else { return nil }
            let index = hay.distance(from: hay.startIndex, to: r.lowerBound)
            return SearchResult(from: off + index, to: off + index + string.count, match: nil, matchStart: start)
        }
    }
}

private struct RegExpQuery: QueryImpl {
    let regex: NSRegularExpression

    init?(pattern: String, caseSensitive: Bool) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
        else { return nil }
        self.regex = regex
    }

    private func result(from match: NSTextCheckingResult, in hay: String, blockStart: Int) -> SearchResult? {
        var groups: [SearchMatchGroup] = []
        for g in 0..<match.numberOfRanges {
            let nsr = match.range(at: g)
            guard nsr.location != NSNotFound, let r = Range(nsr, in: hay) else {
                groups.append(SearchMatchGroup(range: nil, text: nil))
                continue
            }
            let lo = hay.distance(from: hay.startIndex, to: r.lowerBound)
            let hi = hay.distance(from: hay.startIndex, to: r.upperBound)
            groups.append(SearchMatchGroup(range: lo..<hi, text: String(hay[r])))
        }
        guard let whole = groups.first?.range else { return nil }
        return SearchResult(from: blockStart + whole.lowerBound, to: blockStart + whole.upperBound,
                            match: groups, matchStart: blockStart)
    }

    func findNext(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult? {
        scanTextblocks(state.doc, from, to) { node, start in
            let content = blockText(node)
            let hi = min(node.content.size, to - start)
            guard hi >= 0, hi <= content.count else { return nil }
            let hay = String(content[..<content.index(content.startIndex, offsetBy: hi)])
            let lo = max(0, from - start)
            guard lo <= hay.count else { return nil }
            // The first match *with width*. An empty match is not a match: `a|`
            // and `.*` match the empty string at every position, and a result
            // whose `to` equals the `from` it was searched from sends every
            // "find all" loop — the highlighter's included — round forever; the
            // find bar spun until the process was killed. One enumeration pass
            // rather than a `firstMatch` per offset, which was quadratic in the
            // block on exactly the queries that produce empty matches.
            let searchRange = NSRange(hay.index(hay.startIndex, offsetBy: lo)..<hay.endIndex, in: hay)
            guard let found = regex.matches(in: hay, options: [], range: searchRange)
                    .first(where: { $0.range.length > 0 }) else { return nil }
            return result(from: found, in: hay, blockStart: start)
        }
    }

    func findPrev(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult? {
        scanTextblocks(state.doc, from, to) { node, start in
            let content = blockText(node)
            let hi = min(node.content.size, from - start)
            guard hi > 0, hi <= content.count else { return nil }
            let hay = String(content[..<content.index(content.startIndex, offsetBy: hi)])
            // Like upstream: walk overlapping match starts and keep the last.
            var best: NSTextCheckingResult?
            var off = 0
            while off <= hay.count {
                let searchRange = NSRange(hay.index(hay.startIndex, offsetBy: off)..<hay.endIndex, in: hay)
                guard let m = regex.firstMatch(in: hay, options: [], range: searchRange),
                      let r = Range(m.range, in: hay) else { break }
                if !r.isEmpty { best = m } // see findNext: an empty match is not one
                off = hay.distance(from: hay.startIndex, to: r.lowerBound) + 1
            }
            guard let best else { return nil }
            return result(from: best, in: hay, blockStart: start)
        }
    }
}

public func validRegExp(_ source: String) -> Bool {
    (try? NSRegularExpression(pattern: source)) != nil
}

/// The searchable text of an inline-content node: one character per position
/// (leaf atoms become U+FFFC, non-leaf inline children are padded with spaces
/// matching their boundary tokens).
private func blockText(_ node: Node) -> String {
    var content = ""
    for i in 0..<node.childCount {
        let child = node.child(i)
        if child.isText {
            content += child.text ?? ""
        } else if child.isLeaf {
            content += "\u{FFFC}"
        } else {
            content += " " + blockText(child) + " "
        }
    }
    return content
}

private func scanTextblocks<T>(_ node: Node, _ from: Int, _ to: Int,
                               _ f: (Node, Int) -> T?, _ nodeStart: Int = 0) -> T? {
    if node.inlineContent {
        return f(node, nodeStart)
    } else if !node.isLeaf {
        if from > to {
            var pos = nodeStart + node.content.size
            var i = node.childCount - 1
            while i >= 0, pos > to {
                let child = node.child(i)
                pos -= child.nodeSize
                if pos < from, let result = scanTextblocks(child, from, to, f, pos + 1) { return result }
                i -= 1
            }
        } else {
            var pos = nodeStart
            var i = 0
            while i < node.childCount, pos < to {
                let child = node.child(i)
                let start = pos
                pos += child.nodeSize
                if pos > from, let result = scanTextblocks(child, from, to, f, start + 1) { return result }
                i += 1
            }
        }
    }
    return nil
}

private func checkWordBoundary(_ state: EditorState, _ pos: Int) -> Bool {
    let resolved = state.doc.resolve(pos)
    guard let before = resolved.nodeBefore, let after = resolved.nodeAfter,
          before.isText, after.isText else { return true }
    let beforeLetter = before.text?.last?.isLetter ?? false
    let afterLetter = after.text?.first?.isLetter ?? false
    return !beforeLetter || !afterLetter
}

// MARK: - Replacement parsing

private enum ReplPart {
    case text(String)
    case group(Int, copy: Bool)
}

private func parseReplacement(_ text: String) -> [ReplPart] {
    var result: [ReplPart] = []
    var highestSeen = -1
    func add(_ t: String) {
        guard !t.isEmpty else { return }
        if case .text(let prev)? = result.last {
            result[result.count - 1] = .text(prev + t)
        } else {
            result.append(.text(t))
        }
    }
    let chars = Array(text)
    var i = 0, flushed = 0
    while i < chars.count {
        if chars[i] == "$", i + 1 < chars.count,
           chars[i + 1] == "$" || chars[i + 1] == "&" || chars[i + 1].isNumber {
            let c = chars[i + 1]
            if c == "$" {
                add(String(chars[flushed..<i]) + "$") // "$$" → literal "$"
            } else {
                add(String(chars[flushed..<i]))
                let n = c == "&" ? 0 : c.wholeNumberValue!
                if highestSeen >= n {
                    result.append(.group(n, copy: true))
                } else {
                    highestSeen = n == 0 ? 1000 : n
                    result.append(.group(n, copy: false)) // first use: keep in place
                }
            }
            i += 2
            flushed = i
        } else {
            i += 1
        }
    }
    add(String(chars[flushed...]))
    return result
}

// MARK: - Plugin

/// A searched sub-range of the document.
public struct SearchRange: Equatable, Sendable {
    public let from: Int
    public let to: Int
    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// The search plugin's state: the active query, optional range, and the match
/// highlight decorations.
public final class SearchQueryState {
    public let query: SearchQuery
    public let range: SearchRange?
    public let deco: DecorationSet
    init(query: SearchQuery, range: SearchRange?, deco: DecorationSet) {
        self.query = query
        self.range = range
        self.deco = deco
    }
}

public let searchQueryKey = PluginKey<SearchQueryState>("searchQuery")
private let searchQueryMeta = "searchQuery$"

private struct SetSearchAction {
    let query: SearchQuery
    let range: SearchRange?
}

private func buildMatchDeco(_ state: EditorState, _ query: SearchQuery, _ range: SearchRange?) -> DecorationSet {
    guard query.valid else { return .empty }
    var deco: [Decoration] = []
    let sel = state.selection
    var pos = range?.from ?? 0
    let end = range?.to ?? state.doc.content.size
    while let next = query.findNext(state, pos, end) {
        let cls = next.from == sel.from && next.to == sel.to
            ? "ProseMirror-active-search-match" : "ProseMirror-search-match"
        deco.append(.inline(next.from, next.to, ["class": cls]))
        // Always forward. This runs on every transaction while a query is set,
        // so a matcher that ever handed back an empty match here would hang the
        // editor on the next keystroke, not just the find bar.
        pos = Swift.max(next.to, pos + 1)
    }
    return DecorationSet(deco)
}

/// The prosemirror-search plugin: stores the current query + range and
/// highlights its matches.
public func searchQueryPlugin(initialQuery: SearchQuery? = nil, initialRange: SearchRange? = nil) -> Plugin {
    Plugin(
        key: searchQueryKey.key,
        stateField: PluginStateField(
            initialize: { _, state in
                let query = initialQuery ?? SearchQuery(search: "")
                return SearchQueryState(query: query, range: initialRange,
                                        deco: buildMatchDeco(state, query, initialRange))
            },
            apply: { tr, value, _, state in
                let cur = value as! SearchQueryState
                if let action = tr.getMeta(searchQueryMeta) as? SetSearchAction {
                    return SearchQueryState(query: action.query, range: action.range,
                                            deco: buildMatchDeco(state, action.query, action.range))
                }
                if tr.docChanged || tr.selectionSet {
                    var range = cur.range
                    if let r = range {
                        let from = tr.mapping.map(r.from, 1)
                        let to = tr.mapping.map(r.to, -1)
                        range = from < to ? SearchRange(from: from, to: to) : nil
                    }
                    return SearchQueryState(query: cur.query, range: range,
                                            deco: buildMatchDeco(state, cur.query, range))
                }
                return cur
            }),
        props: PluginProps(decorations: { state in searchQueryKey.getState(state)?.deco }))
}

/// The active search query and range, if the plugin is active.
public func getSearchQueryState(_ state: EditorState) -> SearchQueryState? {
    searchQueryKey.getState(state)
}

/// Mark a transaction as updating the active search query and range.
@discardableResult
public func setSearchState(_ tr: Transaction, _ query: SearchQuery, _ range: SearchRange? = nil) -> Transaction {
    tr.setMeta(searchQueryMeta, SetSearchAction(query: query, range: range))
}

// MARK: - Commands

private func nextMatch(_ search: SearchQueryState, _ state: EditorState, _ wrap: Bool,
                       _ curFrom: Int, _ curTo: Int) -> SearchResult? {
    let range = search.range ?? SearchRange(from: 0, to: state.doc.content.size)
    if let next = search.query.findNext(state, max(curTo, range.from), range.to) { return next }
    guard wrap else { return nil }
    return search.query.findNext(state, range.from, min(curFrom, range.to))
}

private func prevMatch(_ search: SearchQueryState, _ state: EditorState, _ wrap: Bool,
                       _ curFrom: Int, _ curTo: Int) -> SearchResult? {
    let range = search.range ?? SearchRange(from: 0, to: state.doc.content.size)
    if let prev = search.query.findPrev(state, min(curFrom, range.to), range.from) { return prev }
    guard wrap else { return nil }
    return search.query.findPrev(state, range.to, max(curTo, range.from))
}

private func findCommand(wrap: Bool, dir: Int) -> @Sendable (EditorState, ((Transaction) -> Void)?) -> Bool {
    { state, dispatch in
        guard let search = searchQueryKey.getState(state), search.query.valid else { return false }
        let from = state.selection.from, to = state.selection.to
        guard let next = dir > 0 ? nextMatch(search, state, wrap, from, to)
                                 : prevMatch(search, state, wrap, from, to) else { return false }
        dispatch?(state.tr.setSelection(TextSelection.create(state.doc, next.from, next.to)).scrollIntoView())
        return true
    }
}

/// Move the selection to the next match (wrapping around).
public let findNext = findCommand(wrap: true, dir: 1)
/// Like `findNext`, without wrapping.
public let findNextNoWrap = findCommand(wrap: false, dir: 1)
/// Move the selection to the previous match (wrapping around).
public let findPrev = findCommand(wrap: true, dir: -1)
/// Like `findPrev`, without wrapping.
public let findPrevNoWrap = findCommand(wrap: false, dir: -1)

private func replaceCommand(wrap: Bool, moveForward: Bool) -> @Sendable (EditorState, ((Transaction) -> Void)?) -> Bool {
    { state, dispatch in
        guard let search = searchQueryKey.getState(state), search.query.valid else { return false }
        let from = state.selection.from
        guard let next = nextMatch(search, state, wrap, from, from) else { return false }
        guard let dispatch else { return true }

        if state.selection.from == next.from, state.selection.to == next.to {
            let tr = state.tr
            let replacements = search.query.getReplacements(state, next)
            for repl in replacements.reversed() {
                _ = try? tr.replace(repl.from, repl.to, repl.insert)
            }
            if moveForward, let after = nextMatch(search, state, wrap, next.from, next.to) {
                tr.setSelection(TextSelection.create(tr.doc, tr.mapping.map(after.from, 1), tr.mapping.map(after.to, -1)))
            } else {
                tr.setSelection(TextSelection.create(tr.doc, next.from, tr.mapping.map(next.to, 1)))
            }
            dispatch(tr.scrollIntoView())
        } else if !moveForward {
            return false
        } else {
            dispatch(state.tr.setSelection(TextSelection.create(state.doc, next.from, next.to)).scrollIntoView())
        }
        return true
    }
}

/// Replace the selected match and move to the next one (or select the next
/// match when none is selected).
public let replaceNext = replaceCommand(wrap: true, moveForward: true)
/// Like `replaceNext`, without wrapping.
public let replaceNextNoWrap = replaceCommand(wrap: false, moveForward: true)
/// Replace the selected match, keeping it selected.
public let replaceCurrent = replaceCommand(wrap: false, moveForward: false)

/// Replace all matches in the search range.
public let replaceAll: @Sendable (EditorState, ((Transaction) -> Void)?) -> Bool = { state, dispatch in
    guard let search = searchQueryKey.getState(state) else { return false }
    let range = search.range ?? SearchRange(from: 0, to: state.doc.content.size)
    var matches: [SearchResult] = []
    var pos = range.from
    while let next = search.query.findNext(state, pos, range.to) {
        matches.append(next)
        pos = next.to
    }
    if let dispatch {
        let tr = state.tr
        for match in matches.reversed() {
            for repl in search.query.getReplacements(state, match).reversed() {
                _ = try? tr.replace(repl.from, repl.to, repl.insert)
            }
        }
        dispatch(tr)
    }
    return true
}
