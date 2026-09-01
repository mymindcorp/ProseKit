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

    /// Every match in `[from, to)`, in document order.
    ///
    /// The same sequence as calling `findNext` from `from` and again from each
    /// result's `to` until it returns nil — but it walks the document once
    /// instead of once per match. `scanTextblocks` restarts at the root every
    /// call, so the loop it replaces was O(matches x blocks): highlighting a
    /// common query over a few thousand paragraphs took over a second, on every
    /// keystroke.
    public func findAll(_ state: EditorState, _ from: Int = 0, _ to: Int? = nil) -> [SearchResult] {
        let to = to ?? state.doc.content.size
        guard valid, from < to else { return [] }
        var out: [SearchResult] = []
        // Carried across blocks: the loop this replaces resumed at the accepted
        // match's end, so a candidate starting inside one was never offered to
        // it. A rejected candidate advances nothing, which is what lets an
        // overlapping neighbour still be tried.
        var cursor = from
        forEachTextblock(state.doc, from, to) { node, start in
            for candidate in impl.matchesIn(node, start, from, to) {
                guard candidate.from >= cursor else { continue }
                if checkResult(state, candidate) {
                    out.append(candidate)
                    cursor = candidate.to
                }
            }
        }
        return out
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
    /// Every match *start* in one textblock, in increasing order, overlapping
    /// ones included. The caller enforces non-overlap, because a match the
    /// whole-word test rejects can still be followed by one that overlaps it —
    /// which is exactly what the `findNext` retry loop does.
    func matchesIn(_ node: Node, _ blockStart: Int, _ from: Int, _ to: Int) -> [SearchResult]
}

private struct NullQuery: QueryImpl {
    func findNext(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult? { nil }
    func findPrev(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult? { nil }
    func matchesIn(_ node: Node, _ blockStart: Int, _ from: Int, _ to: Int) -> [SearchResult] { [] }
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

    func matchesIn(_ node: Node, _ start: Int, _ from: Int, _ to: Int) -> [SearchResult] {
        let content = blockText(node)
        let off = max(from, start)
        let lo = off - start, hi = min(node.content.size, to - start)
        guard lo < hi, hi <= content.count else { return [] }
        var hay = String(content[content.index(content.startIndex, offsetBy: lo)
                                 ..< content.index(content.startIndex, offsetBy: hi)])
        if !caseSensitive { hay = hay.lowercased() }
        var out: [SearchResult] = []
        var cursor = hay.startIndex
        // `cursorOffset` is carried rather than re-measured: `distance(from:
        // startIndex)` per match would make a block with many matches quadratic
        // in its own text, which is the shape being removed here.
        var cursorOffset = 0
        while cursor < hay.endIndex,
              let r = hay.range(of: string, range: cursor ..< hay.endIndex) {
            let index = cursorOffset + hay.distance(from: cursor, to: r.lowerBound)
            out.append(SearchResult(from: off + index, to: off + index + string.count,
                                    match: nil, matchStart: start))
            cursor = hay.index(after: r.lowerBound)
            cursorOffset = index + 1
        }
        return out
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
        // Empty *in document positions*, not only in the pattern's own units.
        // The regex works in UTF-16; a document position is a character. `.`
        // matches a lone combining mark inside `e\u{0301}`, and that is a
        // non-empty NSRange whose two ends are the same character — a match
        // 6..6 that no earlier guard could see, drawn as an empty highlight.
        guard let whole = groups.first?.range, !whole.isEmpty else { return nil }
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
            // `result` is nil for a match with no width in document positions,
            // so the first non-nil result is the first real match.
            return regex.matches(in: hay, options: [], range: searchRange)
                .lazy.compactMap { self.result(from: $0, in: hay, blockStart: start) }.first
        }
    }

    func matchesIn(_ node: Node, _ start: Int, _ from: Int, _ to: Int) -> [SearchResult] {
        let content = blockText(node)
        let hi = min(node.content.size, to - start)
        guard hi >= 0, hi <= content.count else { return [] }
        let hay = String(content[..<content.index(content.startIndex, offsetBy: hi)])
        let lo = max(0, from - start)
        guard lo <= hay.count else { return [] }
        var out: [SearchResult] = []
        var cursor = hay.index(hay.startIndex, offsetBy: lo)
        // Successive `firstMatch` from one past the previous start, rather than
        // `matches(in:)`: that returns only non-overlapping matches, and the
        // whole-word test can reject one whose overlapping neighbour is good.
        while cursor <= hay.endIndex {
            let searchRange = NSRange(cursor ..< hay.endIndex, in: hay)
            guard let m = regex.firstMatch(in: hay, options: [], range: searchRange),
                  let r = Range(m.range, in: hay) else { break }
            // An empty match is not a match — see `findNext`. `a|` and `.*`
            // produce one at every position, and each would have become a
            // zero-width highlight and a "match" the find bar counts.
            if !r.isEmpty, let res = result(from: m, in: hay, blockStart: start) { out.append(res) }
            guard r.lowerBound < hay.endIndex else { break }
            cursor = hay.index(after: r.lowerBound)
        }
        return out
    }

    func findPrev(_ state: EditorState, _ from: Int, _ to: Int) -> SearchResult? {
        scanTextblocks(state.doc, from, to) { node, start in
            let content = blockText(node)
            let hi = min(node.content.size, from - start)
            guard hi > 0, hi <= content.count else { return nil }
            let hay = String(content[..<content.index(content.startIndex, offsetBy: hi)])
            // Like upstream: walk overlapping match starts and keep the last.
            var best: SearchResult?
            var off = 0
            while off <= hay.count {
                let searchRange = NSRange(hay.index(hay.startIndex, offsetBy: off)..<hay.endIndex, in: hay)
                guard let m = regex.firstMatch(in: hay, options: [], range: searchRange),
                      let r = Range(m.range, in: hay) else { break }
                // Keep the last match with width; `result` decides width.
                if let res = result(from: m, in: hay, blockStart: start) { best = res }
                off = hay.distance(from: hay.startIndex, to: r.lowerBound) + 1
            }
            return best
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

/// Visit every textblock overlapping `[from, to)`, in document order.
///
/// `scanTextblocks` stops at the first block that answers, and always restarts
/// from the document root — so asking it for *every* match walked the whole
/// document once per match. Callers that want them all use this instead and
/// walk once.
private func forEachTextblock(_ node: Node, _ from: Int, _ to: Int,
                              _ f: (Node, Int) -> Void, _ nodeStart: Int = 0) {
    if node.inlineContent {
        f(node, nodeStart)
    } else if !node.isLeaf {
        var pos = nodeStart
        var i = 0
        while i < node.childCount, pos < to {
            let child = node.child(i)
            let start = pos
            pos += child.nodeSize
            if pos > from { forEachTextblock(child, from, to, f, start + 1) }
            i += 1
        }
    }
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
    /// Index of the decoration currently drawn as the active match, if any.
    /// Kept so a selection change can decide in O(log n) whether the
    /// highlighting changed at all — moving the caret around usually does not,
    /// and rebuilding it meant searching the whole document again.
    let activeIndex: Int?
    init(query: SearchQuery, range: SearchRange?, deco: DecorationSet, activeIndex: Int? = nil) {
        self.query = query
        self.range = range
        self.deco = deco
        self.activeIndex = activeIndex
    }
}

public let searchQueryKey = PluginKey<SearchQueryState>("searchQuery")
private let searchQueryMeta = "searchQuery$"

private struct SetSearchAction {
    let query: SearchQuery
    let range: SearchRange?
}

private let activeMatchClass = "ProseMirror-active-search-match"
private let matchClass = "ProseMirror-search-match"

private func buildMatchDeco(_ state: EditorState, _ query: SearchQuery, _ range: SearchRange?) -> DecorationSet {
    guard query.valid else { return .empty }
    let sel = state.selection
    let matches = query.findAll(state, range?.from ?? 0, range?.to ?? state.doc.content.size)
    return DecorationSet(matches.map { next in
        .inline(next.from, next.to,
                ["class": next.from == sel.from && next.to == sel.to ? activeMatchClass : matchClass])
    })
}

/// The span of `newDoc` an edit could have changed, widened to whole top-level
/// children — or nil when the mapping reports no changed range at all.
///
/// A match never crosses a textblock (the scan is per block), so widening to the
/// enclosing top-level child is enough to contain every match an edit can have
/// created, destroyed, or reshaped — including one that splits or joins blocks.
private func changedSpan(_ mapping: Mapping, _ newDoc: Node) -> (from: Int, to: Int)? {
    var lo = Int.max, hi = Int.min
    for (i, map) in mapping.maps.enumerated() {
        map.forEach { _, _, newStart, newEnd in
            // Carry each step's range through the steps that follow it, so the
            // union is in the final document's coordinates.
            var s = newStart, e = newEnd
            if i + 1 < mapping.maps.count {
                for j in (i + 1) ..< mapping.maps.count {
                    s = mapping.maps[j].map(s, -1)
                    e = mapping.maps[j].map(e, 1)
                }
            }
            lo = min(lo, s); hi = max(hi, e)
        }
    }
    guard lo <= hi else { return nil }
    let size = newDoc.content.size
    let start = newDoc.resolve(min(max(lo, 0), size))
    let end = newDoc.resolve(min(max(hi, 0), size))
    return (from: start.depth >= 1 ? start.before(1) : 0,
            to: end.depth >= 1 ? end.after(1) : size)
}

/// The match decorations after an edit, re-searching only the blocks the edit
/// touched and carrying the rest forward through the mapping.
///
/// A full rebuild re-scans every block's text, which on a few thousand
/// paragraphs is tens of milliseconds on every keystroke — while the find bar
/// is open, which is exactly when someone is typing a replacement.
private func updateMatchDeco(_ cur: SearchQueryState, _ tr: Transaction,
                             _ state: EditorState, _ range: SearchRange?) -> DecorationSet {
    let size = state.doc.content.size
    let limit = (from: range?.from ?? 0, to: range?.to ?? size)
    guard let span = changedSpan(tr.mapping, state.doc) else {
        return buildMatchDeco(state, cur.query, range)
    }
    let from = max(span.from, limit.from), to = min(span.to, limit.to)
    let carried = cur.deco.map(tr.mapping).decorations
    var out: [Decoration] = []
    out.reserveCapacity(carried.count)
    // A carried decoration keeps its attributes — rebuilding all of them to
    // restyle the one active match meant allocating a dictionary per match on
    // every keystroke. Only a stale *active* class has to be undone, and there
    // is at most one of those.
    func carry(_ d: Decoration) {
        out.append(d.attributes["class"] == activeMatchClass
                   ? .inline(d.from, d.to, ["class": matchClass]) : d)
    }
    // Everything before the touched span survives unchanged...
    for d in carried where d.to <= from { carry(d) }
    // ...the touched span is searched again...
    if from < to {
        for m in cur.query.findAll(state, from, to) {
            out.append(.inline(m.from, m.to, ["class": matchClass]))
        }
    }
    // ...and everything after it survives too. A decoration straddling the
    // boundary is dropped rather than carried: it was re-found above if it
    // still exists, and carrying it as well would double it.
    for d in carried where d.from >= to { carry(d) }
    if let active = activeMatchIndex(out, state.selection) {
        out[active] = .inline(out[active].from, out[active].to, ["class": activeMatchClass])
    }
    return DecorationSet(out)
}

/// Which decoration is styled as the active match under `sel`, if any.
///
/// The decorations come out of `findAll` in document order, so this is a binary
/// search on `from` — it runs on every selection change, including every arrow
/// key, and must not be a walk over every match.
private func activeMatchIndex(_ deco: DecorationSet, _ sel: Selection) -> Int? {
    activeMatchIndex(deco.decorations, sel)
}

private func activeMatchIndex(_ ds: [Decoration], _ sel: Selection) -> Int? {
    var lo = 0, hi = ds.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if ds[mid].from < sel.from { lo = mid + 1 } else { hi = mid }
    }
    guard lo < ds.count, ds[lo].from == sel.from, ds[lo].to == sel.to else { return nil }
    return lo
}

/// The same matches with only the active one's class changed.
private func reclassify(_ deco: DecorationSet, active: Int?) -> DecorationSet {
    DecorationSet(deco.decorations.enumerated().map { i, d in
        .inline(d.from, d.to, ["class": i == active ? activeMatchClass : matchClass])
    })
}

/// The prosemirror-search plugin: stores the current query + range and
/// highlights its matches.
public func searchQueryPlugin(initialQuery: SearchQuery? = nil, initialRange: SearchRange? = nil) -> Plugin {
    Plugin(
        key: searchQueryKey.key,
        stateField: PluginStateField(
            initialize: { _, state in
                let query = initialQuery ?? SearchQuery(search: "")
                let deco = buildMatchDeco(state, query, initialRange)
                return SearchQueryState(query: query, range: initialRange, deco: deco,
                                        activeIndex: activeMatchIndex(deco, state.selection))
            },
            apply: { tr, value, _, state in
                let cur = value as! SearchQueryState
                if let action = tr.getMeta(searchQueryMeta) as? SetSearchAction {
                    let deco = buildMatchDeco(state, action.query, action.range)
                    return SearchQueryState(query: action.query, range: action.range, deco: deco,
                                            activeIndex: activeMatchIndex(deco, state.selection))
                }
                if tr.docChanged {
                    var range = cur.range
                    if let r = range {
                        let from = tr.mapping.map(r.from, 1)
                        let to = tr.mapping.map(r.to, -1)
                        range = from < to ? SearchRange(from: from, to: to) : nil
                    }
                    // Carrying matches across an edit assumes the range only
                    // *moved*. When the edit collapsed it — and the search is
                    // now the whole document — every match outside the old
                    // range is one the carried set never held and the touched
                    // span never covers; the sweep found a match at the start
                    // of the document that a delete near the end made
                    // disappear. Nothing to carry: search from scratch.
                    let deco = (cur.range == nil) == (range == nil)
                        ? updateMatchDeco(cur, tr, state, range)
                        : buildMatchDeco(state, cur.query, range)
                    return SearchQueryState(query: cur.query, range: range, deco: deco,
                                            activeIndex: activeMatchIndex(deco, state.selection))
                }
                if tr.selectionSet {
                    // The document did not change, so neither did where the
                    // matches are: only which one is active can have moved.
                    // Searching again to discover that cost a full document
                    // scan per arrow key.
                    let active = activeMatchIndex(cur.deco, state.selection)
                    guard active != cur.activeIndex else { return cur }
                    return SearchQueryState(query: cur.query, range: cur.range,
                                            deco: reclassify(cur.deco, active: active),
                                            activeIndex: active)
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
