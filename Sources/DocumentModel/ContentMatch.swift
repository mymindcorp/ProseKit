import Foundation

/// Instances of this class represent a match state of a node type's content
/// expression, and can be used to find out whether further content matches
/// here, and whether a given position is a valid end of the node.
public final class ContentMatch: @unchecked Sendable {
    /// True when this match state represents a valid end of the node.
    public internal(set) var validEnd: Bool
    /// The outgoing edges of this state.
    var next: [Edge] = []
    var wrapCache: [(NodeType, [NodeType]?)] = []

    struct Edge {
        let type: NodeType
        let next: ContentMatch
    }

    init(validEnd: Bool) {
        self.validEnd = validEnd
    }

    /// A content match state that matches nothing and is not a valid end.
    public static let empty = ContentMatch(validEnd: true)

    var edgeCount: Int { next.count }
    func edge(_ n: Int) -> Edge { next[n] }

    /// The node types reachable directly from this match state, in order.
    public var edgeTypes: [NodeType] { next.map { $0.type } }

    /// Match a node type, returning a match after that node if successful.
    public func matchType(_ type: NodeType) -> ContentMatch? {
        for edge in next where edge.type === type {
            return edge.next
        }
        return nil
    }

    /// Try to match a fragment. Returns the resulting match when successful.
    public func matchFragment(_ frag: Fragment, start: Int = 0, end: Int? = nil) -> ContentMatch? {
        let end = end ?? frag.childCount
        var cur: ContentMatch? = self
        var i = start
        while let c = cur, i < end {
            cur = c.matchType(frag.child(i).type)
            i += 1
        }
        return cur
    }

    var inlineContent: Bool {
        next.first.map { $0.type.isInline } ?? false
    }

    /// Get the first matching node type at this match state that can be
    /// generated.
    public var defaultType: NodeType? {
        for edge in next where !(edge.type.isText || edge.type.hasRequiredAttrs) {
            return edge.type
        }
        return nil
    }

    func compatible(_ other: ContentMatch) -> Bool {
        for i in next.indices {
            for j in other.next.indices where next[i].type === other.next[j].type {
                return true
            }
        }
        return false
    }

    /// Try to match the given fragment, and if that fails, see if it can be
    /// made to match by inserting nodes in front of it. When successful,
    /// return a fragment of inserted nodes (which may be empty if nothing had
    /// to be inserted).
    public func fillBefore(_ after: Fragment, toEnd: Bool = false, startIndex: Int = 0) -> Fragment? {
        var seen: [ContentMatch] = [self]

        func search(_ match: ContentMatch, _ types: [NodeType]) -> Fragment? {
            let finished = match.matchFragment(after, start: startIndex)
            if let finished, (!toEnd || finished.validEnd) {
                var nodes: [Node] = []
                for t in types {
                    if let n = t.createAndFill() { nodes.append(n) }
                }
                return Fragment.from(nodes)
            }
            for edge in match.next {
                if !edge.type.isText && !edge.type.hasRequiredAttrs && !seen.contains(where: { $0 === edge.next }) {
                    seen.append(edge.next)
                    if let found = search(edge.next, types + [edge.type]) {
                        return found
                    }
                }
            }
            return nil
        }

        return search(self, [])
    }

    /// Find a set of wrapping node types that would allow a node of the given
    /// type to appear at this position. The result may be empty (when it fits
    /// directly) and will be `nil` when no such wrapping exists.
    public func findWrapping(_ target: NodeType) -> [NodeType]? {
        for cached in wrapCache where cached.0 === target {
            return cached.1
        }
        let computed = computeWrapping(target)
        wrapCache.append((target, computed))
        return computed
    }

    private func computeWrapping(_ target: NodeType) -> [NodeType]? {
        struct Active { var match: ContentMatch; var type: NodeType?; var via: Int }
        var seen: [ObjectIdentifier: Bool] = [ObjectIdentifier(self): true]
        var active: [Active] = [Active(match: self, type: nil, via: -1)]
        var head = 0
        while head < active.count {
            let current = active[head]
            if current.match.matchType(target) != nil {
                // Reconstruct the chain of types.
                var result: [NodeType] = []
                var obj = current
                while let t = obj.type {
                    result.append(t)
                    obj = active[obj.via]
                }
                return result.reversed()
            }
            for edge in current.match.next {
                let type = edge.type
                // Past the first level we are already inside a wrapper, so the
                // candidate has to finish that wrapper's content by itself —
                // `edge.next` is where the wrapper stands once it holds this one
                // node. Without that, a chain can be handed back that builds an
                // invalid node: `details` is "detailsSummary detailsContent", so
                // wrapping into its summary alone leaves the content missing.
                if !type.isLeaf, !type.hasRequiredAttrs,
                   seen[ObjectIdentifier(type.contentMatch)] == nil,
                   current.type == nil || edge.next.validEnd {
                    seen[ObjectIdentifier(type.contentMatch)] = true
                    active.append(Active(match: type.contentMatch, type: type, via: head))
                }
            }
            head += 1
        }
        return nil
    }
}

// MARK: - Content expression parser → NFA → DFA

public extension ContentMatch {
    /// Parse a content expression (e.g. `"paragraph block*"`) into a content
    /// match against the given node types.
    static func parse(_ expr: String, _ nodeTypes: [String: NodeType]) throws(ModelError) -> ContentMatch {
        try ContentExpression.parse(expr, nodeTypes)
    }
}

enum ContentExpression {
    /// Parse a content expression string against a schema's node types,
    /// producing the start `ContentMatch` of the resulting DFA.
    public static func parse(_ string: String, _ nodeTypes: [String: NodeType]) throws(ModelError) -> ContentMatch {
        var stream = TokenStream(string: string, nodeTypes: nodeTypes)
        if stream.next == nil {
            return ContentMatch.empty
        }
        let expr = try parseExpr(&stream)
        if stream.next != nil {
            throw ModelError.schemaError("Unexpected trailing text in content expression: \(string)")
        }
        let nfaResult = nfa(expr)
        try checkForDeadEnds(nfaResult, stream)
        return dfa(nfaResult)
    }

    // Tokenizer
    struct TokenStream {
        let string: String
        let nodeTypes: [String: NodeType]
        var tokens: [String]
        var pos = 0
        var inline: Bool? = nil

        init(string: String, nodeTypes: [String: NodeType]) {
            self.string = string
            self.nodeTypes = nodeTypes
            // Split into tokens: words and the symbols (){}+*?|, and ranges.
            var toks: [String] = []
            let scalars = Array(string)
            var i = 0
            while i < scalars.count {
                let c = scalars[i]
                if c == " " || c == "\n" || c == "\t" { i += 1; continue }
                if "(){}+*?|".contains(c) {
                    toks.append(String(c)); i += 1; continue
                }
                if c == "," {
                    toks.append(","); i += 1; continue
                }
                // word (name or number)
                var word = ""
                while i < scalars.count {
                    let ch = scalars[i]
                    if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                        word.append(ch); i += 1
                    } else { break }
                }
                if word.isEmpty {
                    toks.append(String(c)); i += 1
                } else {
                    toks.append(word)
                }
            }
            self.tokens = toks
        }

        var next: String? { pos < tokens.count ? tokens[pos] : nil }

        mutating func eat(_ tok: String) -> Bool {
            if next == tok { pos += 1; return true }
            return false
        }
    }

    indirect enum Expr {
        case choice([Expr])
        case seq([Expr])
        case plus(Expr)
        case star(Expr)
        case opt(Expr)
        case range(min: Int, max: Int, expr: Expr) // max == -1 => unbounded
        case name(NodeType)
    }

    static func parseExpr(_ stream: inout TokenStream) throws(ModelError) -> Expr {
        var exprs: [Expr] = [try parseExprSeq(&stream)]
        while stream.eat("|") {
            exprs.append(try parseExprSeq(&stream))
        }
        return exprs.count == 1 ? exprs[0] : .choice(exprs)
    }

    static func parseExprSeq(_ stream: inout TokenStream) throws(ModelError) -> Expr {
        var exprs: [Expr] = []
        repeat {
            exprs.append(try parseExprSubscript(&stream))
        } while stream.next != nil && stream.next != ")" && stream.next != "|"
        return exprs.count == 1 ? exprs[0] : .seq(exprs)
    }

    static func parseExprSubscript(_ stream: inout TokenStream) throws(ModelError) -> Expr {
        var expr = try parseExprAtom(&stream)
        while true {
            if stream.eat("+") { expr = .plus(expr) }
            else if stream.eat("*") { expr = .star(expr) }
            else if stream.eat("?") { expr = .opt(expr) }
            else if stream.next == "{" { expr = try parseExprRange(&stream, expr) }
            else { break }
        }
        return expr
    }

    static func parseExprRange(_ stream: inout TokenStream, _ expr: Expr) throws(ModelError) -> Expr {
        _ = stream.eat("{")
        let minStr = stream.next
        guard let minStr, let minV = Int(minStr) else {
            throw ModelError.schemaError("Expected number in content range")
        }
        stream.pos += 1
        var maxV = minV
        if stream.eat(",") {
            if stream.next == "}" {
                maxV = -1
            } else if let mx = stream.next, let mv = Int(mx) {
                maxV = mv
                stream.pos += 1
            }
        }
        if !stream.eat("}") {
            throw ModelError.schemaError("Unclosed braced range")
        }
        return .range(min: minV, max: maxV, expr: expr)
    }

    static func parseExprAtom(_ stream: inout TokenStream) throws(ModelError) -> Expr {
        if stream.eat("(") {
            let expr = try parseExpr(&stream)
            if !stream.eat(")") {
                throw ModelError.schemaError("Missing closing paren in content expression")
            }
            return expr
        }
        guard let tok = stream.next else {
            throw ModelError.schemaError("Unexpected end of content expression")
        }
        // A node-type name or group name.
        let types = resolveName(tok, stream.nodeTypes)
        if types.isEmpty {
            throw ModelError.schemaError("No node type or group '\(tok)' found")
        }
        stream.pos += 1
        let exprs = types.map { Expr.name($0) }
        return exprs.count == 1 ? exprs[0] : .choice(exprs)
    }

    static func resolveName(_ name: String, _ nodeTypes: [String: NodeType]) -> [NodeType] {
        if let t = nodeTypes[name] { return [t] }
        // group match — preserve schema definition order (matches ProseMirror)
        var result: [NodeType] = []
        for (_, t) in nodeTypes {
            if t.groups.contains(name) { result.append(t) }
        }
        return result.sorted { $0.schemaOrder < $1.schemaOrder }
    }

    // NFA construction. Represented as an array of states, each state a list of
    // edges. An edge has an optional term (NodeType) and a target state index.
    struct NFAEdge { var term: NodeType?; var to: Int }
    typealias NFA = [[NFAEdge]]

    static func nfa(_ expr: Expr) -> NFA {
        var nfa: NFA = [[]]

        func node() -> Int { nfa.append([]); return nfa.count - 1 }
        func edge(_ from: Int, _ to: Int, _ term: NodeType?) {
            nfa[from].append(NFAEdge(term: term, to: to))
        }
        func connect(_ edges: [(from: Int, idx: Int)], _ to: Int) {
            for e in edges { nfa[e.from][e.idx].to = to }
        }

        // compile returns list of dangling edges (placeholders to be connected)
        func compile(_ expr: Expr, _ from: Int) -> [(from: Int, idx: Int)] {
            switch expr {
            case let .name(type):
                let idx = nfa[from].count
                edge(from, -1, type)
                return [(from, idx)]
            case let .choice(exprs):
                var out: [(from: Int, idx: Int)] = []
                for e in exprs { out.append(contentsOf: compile(e, from)) }
                return out
            case let .seq(exprs):
                var cur = from
                var dangling: [(from: Int, idx: Int)] = []
                for (i, e) in exprs.enumerated() {
                    let next = compile(e, cur)
                    if i == exprs.count - 1 { return next }
                    let n = node()
                    connect(next, n)
                    cur = n
                    dangling = next
                }
                return dangling
            case let .star(inner):
                let loop = node()
                edge(from, loop, nil)
                connect(compile(inner, loop), loop)
                let idx = nfa[loop].count
                edge(loop, -1, nil)
                return [(loop, idx)]
            case let .plus(inner):
                let loop = node()
                connect(compile(inner, from), loop)
                connect(compile(inner, loop), loop)
                let idx = nfa[loop].count
                edge(loop, -1, nil)
                return [(loop, idx)]
            case let .opt(inner):
                let idx = nfa[from].count
                edge(from, -1, nil)
                return [(from, idx)] + compile(inner, from)
            case let .range(min, max, inner):
                var cur = from
                for _ in 0..<min {
                    let n = node()
                    connect(compile(inner, cur), n)
                    cur = n
                }
                if max == -1 {
                    let loop = cur
                    connect(compile(inner, loop), loop)
                    let idx = nfa[loop].count
                    edge(loop, -1, nil)
                    return [(loop, idx)]
                } else {
                    var dangling: [(from: Int, idx: Int)] = []
                    for _ in min..<max {
                        let idx = nfa[cur].count
                        edge(cur, -1, nil)
                        dangling.append((cur, idx))
                        let n = node()
                        connect(compile(inner, cur), n)
                        cur = n
                    }
                    let idx = nfa[cur].count
                    edge(cur, -1, nil)
                    dangling.append((cur, idx))
                    return dangling
                }
            }
        }

        let endDangling = compile(expr, 0)
        let end = node()
        connect(endDangling, end)
        return nfa
    }

    // Epsilon-closure of a set of NFA states.
    static func nullFrom(_ nfa: NFA, _ node: Int) -> [Int] {
        var result: [Int] = []
        func scan(_ n: Int) {
            for e in nfa[n] where e.term == nil {
                if !result.contains(e.to) {
                    result.append(e.to)
                    scan(e.to)
                }
            }
        }
        scan(node)
        // Descending, like upstream's `cmp = (a, b) => b - a`. State order is
        // what fixes the order of the DFA's outgoing edges, and that order is
        // what `defaultType`, `fillBefore` and `findWrapping` pick from.
        return result.sorted(by: >)
    }

    // Subset construction (NFA → DFA), producing ContentMatch states.
    static func dfa(_ nfa: NFA) -> ContentMatch {
        var labeled: [[Int]: ContentMatch] = [:]
        let endState = nfa.count - 1

        func explore(_ states0: [Int]) -> ContentMatch {
            // states includes epsilon closure
            var states = states0
            for s in states0 { for n in nullFrom(nfa, s) where !states.contains(n) { states.append(n) } }
            states.sort(by: >)
            if let existing = labeled[states] { return existing }
            let validEnd = states.contains(endState)
            let match = ContentMatch(validEnd: validEnd)
            labeled[states] = match
            // Group outgoing terminal edges by node type.
            var byType: [(type: NodeType, targets: [Int])] = []
            for s in states {
                for e in nfa[s] where e.term != nil {
                    if let idx = byType.firstIndex(where: { $0.type === e.term! }) {
                        if !byType[idx].targets.contains(e.to) { byType[idx].targets.append(e.to) }
                    } else {
                        byType.append((e.term!, [e.to]))
                    }
                }
            }
            for group in byType {
                let nextMatch = explore(group.targets)
                match.next.append(ContentMatch.Edge(type: group.type, next: nextMatch))
            }
            return match
        }

        return explore([0])
    }

    static func checkForDeadEnds(_ nfa: NFA, _ stream: TokenStream) throws(ModelError) {
        // Best-effort: no-op. ProseMirror warns on dead ends; we skip for now.
        _ = nfa; _ = stream
    }
}
