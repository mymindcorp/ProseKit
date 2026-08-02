import Foundation
public import DocumentModel

/// Maps node/mark type names to HTML tags for serialization & parsing. Defaults
/// cover the StarterKit + tables/image/wiki-link names.
public struct HTMLConfig: Sendable {
    /// node name → tag (heading/codeBlock handled specially)
    public var nodeTags: [String: String]
    /// mark name → tag
    public var markTags: [String: String]
    /// tag → node name (parse direction)
    public var tagToNode: [String: String]
    /// tag → mark name (parse direction)
    public var tagToMark: [String: String]
    /// The node attribute written by the UniqueID extension to round-trip as a
    /// `data-*` HTML attribute, and the HTML attribute name to use. Defaults to
    /// the `id` document attribute ↔ `data-id` (matching Tiptap). Set `idDocAttr`
    /// to nil to disable id serialization. Only emitted for nodes that actually
    /// carry the attribute, so non-UniqueID documents are unaffected.
    public var idDocAttr: String? = "id"
    public var idHTMLAttr: String = "data-id"

    public static let `default`: HTMLConfig = {
        let nodeTags: [String: String] = [
            "paragraph": "p", "blockquote": "blockquote",
            "bulletList": "ul", "orderedList": "ol", "listItem": "li",
            "horizontalRule": "hr", "hardBreak": "br", "image": "img",
            "table": "table", "tableRow": "tr", "tableCell": "td", "tableHeader": "th",
            "taskList": "ul", "taskItem": "li",
            "details": "details", "detailsSummary": "summary", "detailsContent": "div",
            "figure": "figure", "figcaption": "figcaption",
            "inlineMath": "span", "blockMath": "div",
            "wikiLink": "a", "mention": "span",
            "footnoteReference": "sup", "footnoteDefinition": "div",
        ]
        let markTags: [String: String] = [
            "bold": "strong", "italic": "em", "strike": "s", "underline": "u",
            "highlight": "mark", "code": "code", "link": "a",
            "subscript": "sub", "superscript": "sup",
            // textColor/backgroundColor serialize to styled <span> (see applyMarks).
        ]
        var tagToNode: [String: String] = [:]
        // taskList/taskItem also use ul/li but need a data-type to round-trip,
        // so they don't claim the reverse mapping (ul→bulletList, li→listItem).
        // detailsContent is a data-typed <div>, parsed as part of its <details>.
        // The math nodes are data-typed span/div, recognized by `data-type`.
        let noReverse: Set<String> = ["wikiLink", "mention", "taskList", "taskItem", "detailsContent",
                                      "footnoteReference", "footnoteDefinition",
                                      "inlineMath", "blockMath"]
        for (n, t) in nodeTags where !noReverse.contains(n) { tagToNode[t] = n }
        for h in 1...6 { tagToNode["h\(h)"] = "heading" }
        tagToNode["pre"] = "codeBlock"
        let tagToMark: [String: String] = [
            "strong": "bold", "b": "bold", "em": "italic", "i": "italic",
            "s": "strike", "del": "strike", "strike": "strike",
            "u": "underline", "ins": "underline",
            "mark": "highlight", "code": "code", "a": "link",
            "sub": "subscript", "sup": "superscript",
        ]
        return HTMLConfig(nodeTags: nodeTags, markTags: markTags, tagToNode: tagToNode, tagToMark: tagToMark)
    }()
}

// MARK: - Serialize

public enum HTMLSerializer {
    public static func serialize(_ doc: Node, config: HTMLConfig = .default) -> String {
        serialize(fragment: doc.content, config: config)
    }

    /// Serialize a bare fragment (e.g. a copied selection's content) to HTML.
    public static func serialize(fragment: Fragment, config: HTMLConfig = .default) -> String {
        var out = ""
        // Markup runs somewhat longer than the text it wraps. `size` is the
        // document model's own measure and costs nothing to ask for, so this is
        // a starting guess that saves the first several reallocations rather
        // than an attempt to get the length right.
        out.reserveCapacity(fragment.size * 2)
        serializeFragment(fragment, config, into: &out)
        return out
    }

    /// Which of two marks covering the same text is written outside the other,
    /// outermost first. Marks not listed here keep the schema's order.
    ///
    /// The choice is invisible in a rendered document, but it isn't arbitrary:
    /// CommonMark writes `<em><strong>x</strong></em>` for `***x***` and puts a
    /// link outside the emphasis inside it, so every other Markdown renderer
    /// does too. Matching them keeps our HTML comparable with theirs — which is
    /// how the CommonMark suite reads it, and how anyone diffing our output
    /// against a reference implementation will.
    private static let nestingOrder = ["link", "italic", "bold"]

    private static func nestingRank(_ mark: Mark) -> Int {
        nestingOrder.firstIndex(of: mark.type.name) ?? nestingOrder.count
    }

    static func serializeFragment(_ fragment: Fragment, _ config: HTMLConfig, into out: inout String) {
        // A mark can cover several nodes — bold across a link and the text after
        // it is one run — so marks are opened and closed around runs rather than
        // around each node, which would emit `<em>a</em><em><a>b</a></em>`.
        // Block nodes carry no marks, so this is a no-op for them.
        var active: [Mark] = []
        func closeDown(to keep: Int) {
            while active.count > keep { markClose(active.removeLast(), config, into: &out) }
        }
        func same(_ a: Mark, _ b: Mark) -> Bool { a.type === b.type && a.attrs == b.attrs }
        func carries(_ node: Node, _ mark: Mark) -> Bool {
            node.marks.contains { same($0, mark) }
        }
        // Where each mark's current run ends, remembered across the loop below.
        //
        // A run that ends at `e` ends at `e` from every position inside it, so
        // the scan happens once per run instead of once per node in it. Without
        // that, one mark spanning N children costs O(N²) — and a bolded passage
        // with links or emphasis inside it is exactly that shape, since those
        // children can't merge into one text node. A paragraph of 6000 such
        // children took 280 ms to write out.
        var runEnds: [(mark: Mark, end: Int)] = []
        func runEnd(_ mark: Mark, from: Int) -> Int {
            let cached = runEnds.firstIndex { same($0.mark, mark) }
            if let cached, runEnds[cached].end > from { return runEnds[cached].end }
            var j = from
            while j < fragment.childCount, carries(fragment.child(j), mark) { j += 1 }
            if let cached { runEnds[cached].end = j } else { runEnds.append((mark, j)) }
            return j
        }
        for i in 0..<fragment.childCount {
            let node = fragment.child(i)
            // Blocks carry no marks, and a fragment of them is the common case:
            // nothing below has anything to do.
            if node.marks.isEmpty, active.isEmpty {
                serializeNode(node, config, into: &out)
                continue
            }
            // A mark covering more of what follows is written outside one
            // covering less, so a bold across a link and the text after it wraps
            // both instead of being opened twice.
            // Two marks covering exactly the same text can be written in either
            // order — the tags apply to the same characters either way — so the
            // tie is broken by `nestingOrder` and then by the schema's own,
            // which is what the document lists them in.
            //
            // Each run end is measured once here rather than inside the
            // comparison, which asked for it O(m log m) times per node.
            let ends = node.marks.map { runEnd($0, from: i) }
            let own = node.marks.indices
                .sorted { left, right in
                    guard ends[left] == ends[right] else { return ends[left] > ends[right] }
                    return (nestingRank(node.marks[left]), left)
                        < (nestingRank(node.marks[right]), right)
                }
                .map { node.marks[$0] }
            // A node that can't carry a mark shouldn't close it either: `code`
            // excludes every other mark, but `<strong>a<code>b</code>c</strong>`
            // is exactly what should be written.
            func canCarry(_ mark: Mark) -> Bool {
                !node.isText || mark.addToSet(node.marks).contains { $0.type === mark.type }
            }
            var wanted: [Mark] = []
            for mark in active where own.contains(where: { same($0, mark) }) || !canCarry(mark) {
                wanted.append(mark)
            }
            for mark in own where !wanted.contains(where: { same($0, mark) }) {
                wanted.append(mark)
            }
            var shared = 0
            while shared < active.count, shared < wanted.count,
                  same(active[shared], wanted[shared]) { shared += 1 }
            closeDown(to: shared)
            for mark in wanted[shared...] {
                markOpen(mark, config, into: &out)
                active.append(mark)
            }
            serializeNode(node, config, into: &out)
        }
        closeDown(to: 0)
    }

    /// ` data-id="…"` for a node carrying the UniqueID attribute, else nothing.
    static func idAttr(_ node: Node, _ config: HTMLConfig, into out: inout String) {
        guard let docAttr = config.idDocAttr,
              case let .string(id)? = node.attrs[docAttr] else { return }
        out += " \(config.idHTMLAttr)=\""
        escapeAttribute(id, into: &out)
        out += "\""
    }

    /// Whether a list item holds nothing — one empty paragraph, which is there
    /// because `listItem` has to begin with one, not because anything was
    /// written in it.
    private static func isEmptyItem(_ item: Node) -> Bool {
        item.content.childCount == 1 && item.content.child(0).type.name == "paragraph"
            && item.content.child(0).content.size == 0
    }

    /// An item's blocks, without the empty paragraph `listItem`'s "paragraph
    /// block*" shape forces in front of content that isn't one — a code block
    /// written as the first thing in an item, say.
    private static func itemBlocks(_ item: Node) -> [Node] {
        var blocks = (0..<item.content.childCount).map { item.content.child($0) }
        if blocks.count > 1, blocks[0].type.name == "paragraph", blocks[0].content.size == 0 {
            blocks.removeFirst()
        }
        return blocks
    }

    /// A list's items. In a tight list — one written with no blank lines
    /// between its items — a paragraph inside an item is unwrapped, which is
    /// how Markdown renders one and what a reader expects to see.
    private static func listItems(_ list: Node, _ config: HTMLConfig, into out: inout String) {
        guard list.attrs["tight"]?.boolValue == true else {
            return serializeFragment(list.content, config, into: &out)
        }
        for i in 0..<list.content.childCount {
            let item = list.content.child(i)
            guard item.type.name == "listItem" else {
                serializeNode(item, config, into: &out); continue
            }
            out += "<li"
            idAttr(item, config, into: &out)
            if isEmptyItem(item) { out += "></li>"; continue }
            out += ">"
            for block in itemBlocks(item) {
                if block.type.name == "paragraph" {
                    serializeFragment(block.content, config, into: &out)
                } else {
                    serializeNode(block, config, into: &out)
                }
            }
            out += "</li>"
        }
    }

    /// Write `node` and everything under it.
    ///
    /// Everything here appends to one buffer rather than returning its own
    /// string. Returning meant each element built the whole of its subtree and
    /// then had it copied into its parent's string, and again into that one's
    /// parent — so a document's bytes were copied once per level they sat under.
    static func serializeNode(_ node: Node, _ config: HTMLConfig, into out: inout String) {
        if node.isText {
            // Marks are written by `serializeFragment`, which wraps them around
            // whole runs; this is just the node's own text.
            return escape(node.text ?? "", into: &out)
        }
        /// `<tag …attrs…>children</tag>`, the shape most of these have.
        func element(_ tag: String, _ attributes: String = "", content: Fragment? = nil) {
            out += "<\(tag)\(attributes)"
            idAttr(node, config, into: &out)
            out += ">"
            serializeFragment(content ?? node.content, config, into: &out)
            out += "</\(tag)>"
        }
        switch node.type.name {
        case "orderedList":
            // A list that doesn't start at 1 has to say so, or the numbering is
            // lost the moment it leaves the editor.
            let start = node.attrs["order"]?.intValue ?? 1
            out += start == 1 ? "<ol" : "<ol start=\"\(start)\""
            idAttr(node, config, into: &out)
            out += ">"
            listItems(node, config, into: &out)
            out += "</ol>"
        case "bulletList":
            out += "<ul"
            idAttr(node, config, into: &out)
            out += ">"
            listItems(node, config, into: &out)
            out += "</ul>"
        case "listItem" where isEmptyItem(node):
            out += "<li"
            idAttr(node, config, into: &out)
            out += "></li>"
        case "listItem":
            out += "<li"
            idAttr(node, config, into: &out)
            out += ">"
            for block in itemBlocks(node) { serializeNode(block, config, into: &out) }
            out += "</li>"
        case "heading":
            let level = node.attrs["level"]?.intValue ?? 1
            out += "<h\(level)"
            idAttr(node, config, into: &out)
            out += ">"
            serializeFragment(node.content, config, into: &out)
            out += "</h\(level)>"
        case "codeBlock":
            // The convention every highlighter reads, and what CommonMark's own
            // output uses for a fence's info string.
            out += "<pre"
            idAttr(node, config, into: &out)
            out += "><code"
            if let language = node.attrs["language"]?.stringValue, !language.isEmpty {
                out += " class=\"language-"
                escapeAttribute(language, into: &out)
                out += "\""
            }
            out += ">"
            escape(node.textContent, into: &out)
            out += "</code></pre>"
        case "horizontalRule":
            out += "<hr>"
        case "hardBreak":
            out += "<br>"
        case "image":
            out += "<img src=\""
            escapeAttribute(node.attrs["src"]?.stringValue ?? "", into: &out)
            out += "\""
            if let alt = node.attrs["alt"]?.stringValue {
                out += " alt=\""; escapeAttribute(alt, into: &out); out += "\""
            }
            if let title = node.attrs["title"]?.stringValue {
                out += " title=\""; escapeAttribute(title, into: &out); out += "\""
            }
            if let w = node.attrs["width"]?.intValue { out += " width=\"\(w)\"" }
            if let h = node.attrs["height"]?.intValue { out += " height=\"\(h)\"" }
            // The original behind this rendition, as flat `data-` attributes —
            // readable markup, and no JSON to escape inside an attribute.
            if case let .object(model)? = node.attrs["model"],
               case let .string(path)? = model["path"] {
                out += " data-model-path=\""; escapeAttribute(path, into: &out); out += "\""
                if let w = model["width"]?.intValue { out += " data-model-width=\"\(w)\"" }
                if let h = model["height"]?.intValue { out += " data-model-height=\"\(h)\"" }
            }
            out += ">"
        case "wikiLink":
            let target = node.attrs["target"]?.stringValue ?? ""
            out += "<a href=\""
            escapeAttribute(target, into: &out)
            out += "\" data-wikilink=\""
            escapeAttribute(target, into: &out)
            out += "\">"
            escape(node.attrs["label"]?.stringValue ?? target, into: &out)
            out += "</a>"
        case "mention":
            let id = node.attrs["id"]?.stringValue ?? ""
            out += "<span data-mention=\""
            escapeAttribute(id, into: &out)
            out += "\">@"
            escape(node.attrs["label"]?.stringValue ?? id, into: &out)
            out += "</span>"
        case "footnoteReference":
            // The label identifies the note; the number shown is the reference's
            // place in the document, which the caller knows and this doesn't —
            // so the label is what goes in the text as well as the attribute.
            let label = node.attrs["label"]?.stringValue ?? ""
            out += "<sup data-type=\"footnoteReference\" data-label=\""
            escapeAttribute(label, into: &out)
            out += "\">"
            escape(label, into: &out)
            out += "</sup>"
        case "footnoteDefinition":
            var attributes = " data-type=\"footnoteDefinition\" data-label=\""
            escapeAttribute(node.attrs["label"]?.stringValue ?? "", into: &attributes)
            attributes += "\""
            element("div", attributes)
        case "taskList":
            element("ul", " data-type=\"taskList\"")
        case "taskItem":
            let checked = node.attrs["checked"]?.boolValue ?? false
            out += "<li data-type=\"taskItem\" data-checked=\"\(checked)\""
            idAttr(node, config, into: &out)
            out += "><input type=\"checkbox\"\(checked ? " checked=\"checked\"" : "")>"
            serializeFragment(node.content, config, into: &out)
            out += "</li>"
        case "details":
            element("details", node.attrs["open"]?.boolValue == true ? " open" : "")
        case "detailsSummary":
            element("summary")
        case "detailsContent":
            element("div", " data-type=\"detailsContent\"")
        case "inlineMath", "blockMath":
            // Tiptap's shape: the source lives in `data-latex`, and the element's
            // text is the `$…$` form so non-math readers still see the formula.
            let inline = node.type.name == "inlineMath"
            let tag = inline ? "span" : "div", fence = inline ? "$" : "$$"
            let latex = node.attrs["latex"]?.stringValue ?? ""
            out += "<\(tag) data-type=\"\(inline ? "inline-math" : "block-math")\" data-latex=\""
            escapeAttribute(latex, into: &out)
            out += "\""
            idAttr(node, config, into: &out)
            out += ">"
            escape(fence + latex + fence, into: &out)
            out += "</\(tag)>"
        case "tableCell", "tableHeader":
            let tag = node.type.name == "tableHeader" ? "th" : "td"
            var a = ""
            let cs = node.attrs["colspan"]?.intValue ?? 1, rs = node.attrs["rowspan"]?.intValue ?? 1
            if cs != 1 { a += " colspan=\"\(cs)\"" }
            if rs != 1 { a += " rowspan=\"\(rs)\"" }
            if case let .array(cw)? = node.attrs["colwidth"] {
                a += " data-colwidth=\"\(cw.map { String($0.intValue ?? 0) }.joined(separator: ","))\""
            }
            element(tag, a)
        default:
            element(config.nodeTags[node.type.name] ?? "div")
        }
    }

    /// The opening tag for a mark. Split from the closing half so a mark can
    /// wrap a run of several nodes rather than each node separately.
    static func markOpen(_ mark: Mark, _ config: HTMLConfig, into out: inout String) {
        switch mark.type.name {
        case "link":
            out += "<a href=\""
            escapeAttribute(mark.attrs["href"]?.stringValue ?? "", into: &out)
            out += "\""
            if let title = mark.attrs["title"]?.stringValue {
                out += " title=\""; escapeAttribute(title, into: &out); out += "\""
            }
            out += ">"
        case "highlight":
            // The colour is a named style the theme resolves ("yellow"), not
            // necessarily a CSS colour — `data-color` is what round-trips it.
            // A style is emitted alongside only when the name happens to be
            // real CSS, so a highlight survives pasting into another app
            // without this ever writing a bogus declaration.
            out += "<mark"
            if let color = mark.attrs["color"]?.stringValue {
                out += " data-color=\""
                escapeAttribute(color, into: &out)
                out += "\""
                if let css = sanitizeCSSColor(color) {
                    out += " style=\"background-color:"
                    escapeAttribute(css, into: &out)
                    out += "\""
                }
            }
            out += ">"
        case "textColor", "backgroundColor":
            guard let c = mark.attrs["color"]?.stringValue else { return }
            out += mark.type.name == "textColor"
                ? "<span style=\"color:" : "<span style=\"background-color:"
            escapeAttribute(c, into: &out)
            out += "\">"
        default:
            guard let tag = config.markTags[mark.type.name] else { return }
            out += "<\(tag)>"
        }
    }

    static func markClose(_ mark: Mark, _ config: HTMLConfig, into out: inout String) {
        switch mark.type.name {
        case "link": out += "</a>"
        case "highlight": out += "</mark>"
        case "textColor", "backgroundColor":
            if mark.attrs["color"]?.stringValue != nil { out += "</span>" }
        default:
            guard let tag = config.markTags[mark.type.name] else { return }
            out += "</\(tag)>"
        }
    }

    /// The characters that can't be written literally where they'd be read as
    /// markup. `"` only matters inside a quoted attribute value.
    private static func isMarkupByte(_ b: UInt8, quote: Bool) -> Bool {
        b == UInt8(ascii: "&") || b == UInt8(ascii: "<") || b == UInt8(ascii: ">")
            || (quote && b == UInt8(ascii: "\""))
    }

    /// Append `s`, replacing the characters that would be read as markup.
    ///
    /// Text containing none of them is nearly all text, and costs one scan of
    /// its bytes and one copy. It used to cost three passes of
    /// `replacingOccurrences` — three Foundation calls each building a whole
    /// new string — whether or not there was anything to replace.
    static func escape(_ s: String, into out: inout String, quote: Bool = false) {
        guard s.utf8.contains(where: { isMarkupByte($0, quote: quote) }) else { out += s; return }
        var chunk = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            let entity: String
            switch s[i] {
            case "&": entity = "&amp;"
            case "<": entity = "&lt;"
            case ">": entity = "&gt;"
            case "\"" where quote: entity = "&quot;"
            default: i = s.index(after: i); continue
            }
            out += s[chunk..<i]
            out += entity
            i = s.index(after: i)
            chunk = i
        }
        out += s[chunk...]
    }

    /// Escape a value going inside a double-quoted attribute. A bare `"` there
    /// would end the attribute early and corrupt the rest of the tag — reachable
    /// from any user-supplied text (an image `alt`, a `\text{"…"}` in a formula).
    static func escapeAttribute(_ s: String, into out: inout String) {
        escape(s, into: &out, quote: true)
    }
}

/// Why HTML couldn't be parsed into a document.
public enum HTMLParseError: Error, CustomStringConvertible, Equatable {
    /// The markup nests deeper than `HTMLParser.maxNestingDepth`. Parsing it
    /// would have recursed far enough to overflow the stack.
    case nestingTooDeep(depth: Int, limit: Int)
    /// The parsed content couldn't be fitted to the schema. Structural coercion
    /// handles the shapes real markup produces, so this means the schema itself
    /// can't express the document — a bug rather than bad input.
    case invalidDocument(String)

    public var description: String {
        switch self {
        case let .nestingTooDeep(depth, limit):
            return "HTMLParseError: markup nests at least \(depth) elements deep (limit \(limit))"
        case let .invalidDocument(reason):
            return "HTMLParseError: parsed content isn't a valid document — \(reason)"
        }
    }
}

// MARK: - Parse

/// A tiny HTML tokenizer + parser sufficient for clipboard interchange of the
/// document shapes this editor produces.
public enum HTMLParser {
    enum Token {
        case open(tag: String, attrs: [String: String], selfClosing: Bool)
        case close(tag: String)
        case text(String)
    }

    /// A window on the token stream.
    ///
    /// Parsing descends into an element's children constantly, and each descent
    /// used to copy that element's tokens into a fresh `Array` — which for a
    /// `<body>` wrapper means copying, retaining, and then releasing the whole
    /// document. A slice keeps the same indices as the array it came from, so
    /// the `start`/`end` positions passed around here mean the same thing either
    /// way.
    typealias Tokens = ArraySlice<Token>

    /// The deepest element nesting `parse` will accept.
    ///
    /// Parsing descends recursively, one Swift stack frame per nested element,
    /// so pathological input — hand-crafted, or a generator gone wrong — can
    /// overflow the stack, which is a crash rather than a catchable error. This
    /// is checked up front against the token stream so the failure arrives as a
    /// thrown error instead. Real documents nest a dozen or so levels deep;
    /// anything near this limit is malformed by any reasonable measure.
    public static let maxNestingDepth = 256

    public static func parse(_ html: String, schema: Schema, config: HTMLConfig = .default) throws -> Node {
        let tokens = tokenize(html)
        if let depth = excessiveNestingDepth(tokens[...]) {
            throw HTMLParseError.nestingTooDeep(depth: depth, limit: maxNestingDepth)
        }
        let parsed = parseBlocks(tokens[...], schema, config)
        // HTML arrives in fragments, so the top level can hold things no schema
        // allows there — a bare `<li>` or `<td>` from a partial copy. Fit them
        // to the document's content instead of building something invalid.
        var blocks = fitContent(parsed, into: schema.topNodeType, schema: schema)
        if blocks.isEmpty, let p = schema.nodes["paragraph"]?.createAndFill() {
            blocks = [p]
        }
        let doc = try schema.node("doc", [:], content: Fragment.from(blocks))
        // `create` computes attributes but doesn't check content, so an invalid
        // document would otherwise be returned silently and only fail later,
        // somewhere that assumes it is well-formed.
        do {
            try doc.check()
        } catch {
            throw HTMLParseError.invalidDocument(String(describing: error))
        }
        return doc
    }

    /// The depth at which `tokens` exceed `maxNestingDepth`, or nil if they
    /// never do. Scans the flat token stream, so it costs one pass and runs
    /// before any recursion has a chance to overflow the stack.
    private static func excessiveNestingDepth(_ tokens: Tokens) -> Int? {
        var depth = 0
        for token in tokens {
            switch token {
            case let .open(_, _, selfClosing):
                // The tokenizer already reports void elements (`<br>`, `<img>`,
                // legal without a slash) as self-closing, so a flat document
                // full of images doesn't read as infinitely nested.
                guard !selfClosing else { continue }
                depth += 1
                if depth > maxNestingDepth { return depth }
            case .close:
                depth = max(0, depth - 1)
            case .text:
                continue
            }
        }
        return nil
    }

    // Tags whose children are spliced in transparently (document/section wrappers).
    private static let transparentWrappers: Set<String> = ["html", "body", "tbody", "thead", "tfoot"]
    // Tags dropped entirely along with their content (document metadata, CSS, JS).
    /// Tags dropped entirely along with their content. Beyond document metadata
    /// and CSS/JS, this covers the embedding elements — an `<iframe>` or an
    /// `<svg>` is a document of its own that can carry script, and none of them
    /// have a representation in the schema anyway.
    private static let skippedWrappers: Set<String> = [
        "head", "style", "script", "title", "noscript", "colgroup",
        "iframe", "frame", "frameset", "object", "embed", "applet", "svg", "template",
    ]
    private static let blockTags: Set<String> = [
        "p", "div", "ul", "ol", "li", "table", "tr", "td", "th", "tbody", "thead", "tfoot",
        "blockquote", "pre", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article",
    ]

    private static func containsBlockTag(_ tokens: Tokens) -> Bool {
        for t in tokens { if case let .open(tag, _, _) = t, blockTags.contains(tag) { return true } }
        return false
    }

    private static func one(_ node: Node?) -> [Node] { node.map { [$0] } ?? [] }

    /// The UniqueID attribute parsed from an element's `data-id`, as node attrs —
    /// but only when the target node type actually declares the attribute (i.e.
    /// the UniqueID extension is configured for it). Empty otherwise.
    private static func idAttrs(_ htmlAttrs: [String: String], _ nodeName: String,
                                _ schema: Schema, _ config: HTMLConfig) -> Attrs {
        guard let docAttr = config.idDocAttr,
              let value = htmlAttrs[config.idHTMLAttr],
              let type = schema.nodes[nodeName],
              type.defaultAttrs[docAttr] != nil
        else { return [:] }
        return [docAttr: .string(value)]
    }

    /// Wrap inline content as a textblock, but split it around any block-level
    /// atoms (e.g. a block `image`) so each becomes its own sibling rather than an
    /// invalid child of the textblock. With an inline-image schema nothing splits.
    private static func textblockSplittingBlocks(_ inline: [Node], wrap: ([Node]) -> Node?) -> [Node] {
        EditorSerialization.textblockSplittingBlocks(inline, wrap: wrap)
    }

    // Parse a single block-level element starting at `start`, yielding zero or
    // more sibling nodes (an inline-context `<img>` in a block-image schema lifts
    // out of its paragraph, so one element can produce several blocks).
    private static func parseBlock(_ tokens: Tokens, _ start: Int, _ schema: Schema, _ config: HTMLConfig) -> ([Node], Int)? {
        guard case let .open(tag, attrs, selfClosing) = tokens[start] else {
            // stray text at block level → wrap in a paragraph
            if case let .text(t) = tokens[start], !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let para = try? schema.node("paragraph", [:], content: Fragment.from([schema.text(decodeEntities(t))])) {
                return ([para], start + 1)
            }
            return ([], start + 1)
        }
        if tag == "hr" || (selfClosing && tag == "hr") {
            return (one(try? schema.node("horizontalRule")), start + 1)
        }
        if tag == "img" {
            return (one(makeImage(attrs, schema)), start + 1)
        }
        // Unknown void/self-closing element at block level (e.g. a stray <input>
        // or <col>): skip it — it has no children to recurse into.
        if selfClosing { return ([], start + 1) }
        let nodeName = config.tagToNode[tag]
        // Find matching close tag.
        let end = matchingClose(tokens, start, tag)
        switch nodeName {
        case "heading":
            let level = Int(tag.dropFirst()) ?? 1
            let inline = parseInline(tokens[(start + 1)..<end], schema, config)
            var a: Attrs = ["level": .int(level)]
            a.merge(idAttrs(attrs, "heading", schema, config)) { _, new in new }
            return (textblockSplittingBlocks(inline) { try? schema.node("heading", a, content: Fragment.from($0)) }, end + 1)
        case "codeBlock":
            let text = innerText(tokens, start + 1, end)
            let content = text.isEmpty ? Fragment.empty : Fragment.from([schema.text(text)])
            // `<pre><code class="language-x">` is where the language lives; the
            // class sits on the inner <code>, so look there too.
            var language: String?
            for j in (start + 1)..<max(start + 1, min(end, start + 3)) {
                if case let .open(tag, innerAttrs, _) = tokens[j], tag == "code",
                   let classes = innerAttrs["class"] {
                    language = classes.split(separator: " ")
                        .first { $0.hasPrefix("language-") }
                        .map { String($0.dropFirst("language-".count)) }
                }
            }
            if let language, !language.isEmpty,
               schema.nodes["codeBlock"]?.spec.attrs["language"] != nil {
                var a: Attrs = ["language": .string(language)]
                a.merge(idAttrs(attrs, "codeBlock", schema, config)) { _, new in new }
                return (one(try? schema.node("codeBlock", a, content: content)), end + 1)
            }
            return (one(try? schema.node("codeBlock", idAttrs(attrs, "codeBlock", schema, config), content: content)), end + 1)
        case "paragraph":
            let inline = parseInline(tokens[(start + 1)..<end], schema, config)
            let a = idAttrs(attrs, "paragraph", schema, config)
            return (textblockSplittingBlocks(inline) { try? schema.node("paragraph", a, content: Fragment.from($0)) }, end + 1)
        case "bulletList", "orderedList":
            // ul/ol may actually be a task list (Tiptap data-type, or items with checkboxes).
            return (one(parseList(tag, attrs, tokens, start, end, schema, config)), end + 1)
        case "details":
            return (parseDetails(attrs, tokens, start, end, schema, config), end + 1)
        case "tableCell", "tableHeader":
            let parsed = parseBlocks(tokens[(start + 1)..<end], schema, config)
            let children = schema.nodes[nodeName!].map { fitContent(parsed, into: $0, schema: schema) } ?? parsed
            var a: Attrs = idAttrs(attrs, nodeName!, schema, config)
            if let cs = attrs["colspan"].flatMap({ Int($0) }), cs != 1 { a["colspan"] = .int(cs) }
            if let rs = attrs["rowspan"].flatMap({ Int($0) }), rs != 1 { a["rowspan"] = .int(rs) }
            if let cw = parseColwidth(attrs) { a["colwidth"] = .array(cw.map { .int($0) }) }
            if let type = schema.nodes[nodeName!] {
                if let n = try? type.create(a, content: Fragment.from(children)) { return ([n], end + 1) }
                if let filled = type.createAndFill(a, content: Fragment.from(children)) { return ([filled], end + 1) }
            }
            return (parsed, end + 1)
        case "figcaption":
            // A textblock like a paragraph, but keeping its own type.
            let inline = parseInline(tokens[(start + 1)..<end], schema, config)
            let a = idAttrs(attrs, "figcaption", schema, config)
            guard schema.nodes["figcaption"] != nil else {
                // No caption node: keep the words as a paragraph rather than
                // dropping them on the floor.
                return (textblockSplittingBlocks(inline) {
                    try? schema.node("paragraph", [:], content: Fragment.from($0))
                }, end + 1)
            }
            return (textblockSplittingBlocks(inline) {
                try? schema.node("figcaption", a, content: Fragment.from($0))
            }, end + 1)
        case "blockquote", "listItem", "table", "tableRow", "figure":
            let parsed = parseBlocks(tokens[(start + 1)..<end], schema, config)
            let name = nodeName!
            let a = idAttrs(attrs, name, schema, config)
            if let type = schema.nodes[name] {
                let children = fitContent(parsed, into: type, schema: schema)
                if let n = try? type.create(a, content: Fragment.from(children)) { return ([n], end + 1) }
                if let filled = type.createAndFill(a, content: Fragment.from(children)) { return ([filled], end + 1) }
            }
            // The element itself has no place here; keep what was inside it.
            return (parsed, end + 1)
        default:
            // Unknown block: try its children as blocks.
            let children = parseBlocks(tokens[(start + 1)..<end], schema, config)
            return (children, end + 1)
        }
    }

    /// Elements that belong inside a paragraph rather than beside one.
    ///
    /// Everything else keeps the old treatment — parsed as a block, or as an
    /// unknown container whose children are parsed as blocks — so an unfamiliar
    /// wrapper can't be mistaken for a run of text.
    private static let inlineTags: Set<String> = [
        "strong", "b", "em", "i", "s", "del", "strike", "u", "ins", "mark", "code", "a",
        "sub", "sup", "span", "br", "img", "math", "small", "abbr", "cite", "q",
        "time", "kbd", "samp", "var", "big", "font", "wbr", "bdi", "bdo", "ruby",
    ]

    private static func parseBlocks(_ tokens: Tokens, _ schema: Schema, _ config: HTMLConfig) -> [Node] {
        var result: [Node] = []
        // Consecutive inline tokens belong to one paragraph. Without this each
        // element became its own block and its marks were lost, so
        // `<li>a <strong>b</strong> c</li>` came back as three unformatted
        // paragraphs — only `<p>` and `<div>` ever routed through `parseInline`.
        var inlineRun: Tokens = []
        func flushInline() {
            guard !inlineRun.isEmpty else { return }
            let inline = parseInline(inlineRun, schema, config)
            inlineRun = []
            guard !inline.isEmpty else { return }
            // Whitespace between two blocks isn't a paragraph.
            if inline.allSatisfy(\.isText),
               inline.map({ $0.text ?? "" }).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            result.append(contentsOf: textblockSplittingBlocks(inline) {
                try? schema.node("paragraph", [:], content: Fragment.from($0))
            })
        }

        var i = tokens.startIndex
        while i < tokens.endIndex {
            if case .text = tokens[i] {
                inlineRun.append(tokens[i]); i += 1; continue
            }
            if case let .open(tag, _, selfClosing) = tokens[i] {
                // An inline element mid-run stays in the paragraph. A `<math>`
                // standing alone still reaches the block handling below, so
                // display maths becomes a block node rather than a paragraph.
                if inlineTags.contains(tag), !(tag == "math" && inlineRun.isEmpty) {
                    if selfClosing {
                        inlineRun.append(tokens[i]); i += 1
                    } else {
                        let close = min(matchingClose(tokens, i, tag), tokens.endIndex - 1)
                        inlineRun.append(contentsOf: tokens[i...close])
                        i = close + 1
                    }
                    continue
                }
            }
            if case .close = tokens[i] { i += 1; continue }
            flushInline()
            if case let .open(tag, attrs, _) = tokens[i] {
                // A `data-type="block-math"` div, before the generic <div> branch
                // below would turn it into a paragraph of its `$$…$$` text.
                if tag == "div", let math = makeMath(attrs, tokens, i, schema, config) {
                    result.append(math.node)
                    i = math.next; continue
                }
                // Pasted MathML — from a page, a word processor, or another editor.
                if tag == "math" {
                    if let math = makeMathML(tokens, i, schema, config) {
                        result.append(math.node)
                        i = math.next
                    } else {
                        i = matchingClose(tokens, i, tag) + 1
                    }
                    continue
                }
                // KaTeX and MathJax emit the formula twice: once as MathML and
                // once as visual glyphs marked `aria-hidden`. Keeping both would
                // duplicate every pasted formula as nonsense text.
                if attrs["aria-hidden"] == "true" {
                    i = matchingClose(tokens, i, tag) + 1; continue
                }
                // Document/section wrappers (incl. <html>/<body> from full-document
                // clipboard HTML, e.g. Apple Notes): splice their children in.
                if transparentWrappers.contains(tag) {
                    let e = matchingClose(tokens, i, tag)
                    result.append(contentsOf: parseBlocks(tokens[(i + 1)..<e], schema, config))
                    i = e + 1; continue
                }
                // <head>/<style>/<script>/… — drop entirely.
                if skippedWrappers.contains(tag) { i = matchingClose(tokens, i, tag) + 1; continue }
                // A footnote's note, before the generic <div> branch flattens it
                // and loses which note the blocks belonged to.
                if tag == "div", attrs["data-type"] == "footnoteDefinition",
                   let type = schema.nodes["footnoteDefinition"] {
                    let e = matchingClose(tokens, i, tag)
                    var blocks = parseBlocks(tokens[(i + 1)..<e], schema, config)
                    if blocks.isEmpty, let para = try? schema.node("paragraph") { blocks = [para] }
                    if let definition = try? type.create(["label": .string(attrs["data-label"] ?? "")],
                                                         content: Fragment.from(blocks)) {
                        result.append(definition)
                        i = e + 1; continue
                    }
                }
                // <div>: a generic block container. With block children, flatten it;
                // otherwise treat its inline content as a paragraph (preserving marks).
                if tag == "div" {
                    let e = matchingClose(tokens, i, tag)
                    let inner = tokens[(i + 1)..<e]
                    if containsBlockTag(inner) {
                        result.append(contentsOf: parseBlocks(inner, schema, config))
                    } else {
                        let inline = parseInline(inner, schema, config)
                        if !inline.isEmpty, let para = try? schema.node("paragraph", [:], content: Fragment.from(inline)) {
                            result.append(para)
                        }
                    }
                    i = e + 1; continue
                }
            }
            if let (nodes, next) = parseBlock(tokens, i, schema, config) {
                result.append(contentsOf: nodes)
                i = next
            } else { i += 1 }
        }
        flushInline()
        return result
    }

    /// Parse a `<ul>`/`<ol>` as a task list (Tiptap `data-type`, or `<li>`s with
    /// checkboxes — e.g. pasted from Apple Notes) when applicable, else a bullet/
    /// ordered list.
    private static func parseList(_ tag: String, _ attrs: [String: String], _ tokens: Tokens, _ start: Int, _ end: Int, _ schema: Schema, _ config: HTMLConfig) -> Node? {
        let isTask = attrs["data-type"] == "taskList" || listLooksLikeTasks(tokens, start, end)
        if isTask, let listType = schema.nodes["taskList"], schema.nodes["taskItem"] != nil {
            var items: [Node] = []
            var i = start + 1
            while i < end {
                if case let .open(t, liAttrs, _) = tokens[i], t == "li" {
                    let liEnd = matchingClose(tokens, i, "li")
                    if let item = parseTaskItem(tokens, i, liEnd, liAttrs, schema, config) { items.append(item) }
                    i = liEnd + 1
                } else { i += 1 }
            }
            if !items.isEmpty, let n = try? listType.create(idAttrs(attrs, "taskList", schema, config), content: Fragment.from(items)) { return n }
        }
        let name = config.tagToNode[tag] ?? "bulletList"
        let parsed = parseBlocks(tokens[(start + 1)..<end], schema, config)
        guard let type = schema.nodes[name] else { return nil }
        // A `<ul>` can contain things that aren't list items — real pages put
        // stray paragraphs and nested markup in there.
        let children = fitContent(parsed, into: type, schema: schema)
        var a = idAttrs(attrs, name, schema, config)
        // `<ol start="…">` carries the first number.
        if name == "orderedList", let startAt = attrs["start"].flatMap({ Int($0) }) {
            a["order"] = .int(startAt)
        }
        // No `<li>` wrapping its text in a paragraph means the list was written
        // tight, which is how it should be written back out. Read off the
        // tokens, because fitting the content to the schema puts a paragraph
        // inside every item regardless.
        if type.spec.attrs["tight"] != nil, !children.isEmpty,
           !tokensHaveItemParagraph(tokens, start, end) {
            a["tight"] = .bool(true)
        }
        if let n = try? type.create(a, content: Fragment.from(children)) { return n }
        return type.createAndFill(a, content: Fragment.from(children))
    }

    /// Whether any `<li>` directly under this list wraps its content in a `<p>`.
    private static func tokensHaveItemParagraph(_ tokens: Tokens, _ start: Int, _ end: Int) -> Bool {
        var i = start + 1
        while i < end {
            guard case let .open(tag, _, _) = tokens[i], tag == "li" else { i += 1; continue }
            let liEnd = matchingClose(tokens, i, "li")
            var j = i + 1
            var depth = 0
            while j < liEnd {
                if case let .open(inner, _, selfClosing) = tokens[j] {
                    // Only the item's own children count — a paragraph inside a
                    // nested list belongs to that list, not this one.
                    if depth == 0, inner == "p" { return true }
                    if !selfClosing, inner == "ul" || inner == "ol" { depth += 1 }
                } else if case let .close(inner) = tokens[j], inner == "ul" || inner == "ol" {
                    depth -= 1
                }
                j += 1
            }
            i = liEnd + 1
        }
        return false
    }

    /// Parse a `<details>` into `details(detailsSummary, detailsContent)`. The
    /// `<summary>` (missing in hand-written HTML) becomes the summary; everything
    /// else becomes the content — whether or not it came wrapped in our
    /// `data-type="detailsContent"` div (that div flattens through `parseBlocks`).
    /// With a schema that has no details nodes, the section degrades to the
    /// summary as a paragraph followed by its body blocks.
    private static func parseDetails(_ attrs: [String: String], _ tokens: Tokens, _ start: Int, _ end: Int,
                                     _ schema: Schema, _ config: HTMLConfig) -> [Node] {
        var summaryTokens: Tokens = []
        var summaryAttrs: [String: String] = [:]
        var bodyTokens: [Token] = []
        var i = start + 1
        while i < end {
            if case let .open(t, sAttrs, selfClosing) = tokens[i], t == "summary", !selfClosing, summaryTokens.isEmpty {
                let sEnd = matchingClose(tokens, i, "summary")
                summaryTokens = tokens[(i + 1)..<min(sEnd, end)]
                summaryAttrs = sAttrs
                i = min(sEnd, end) + 1
                continue
            }
            bodyTokens.append(tokens[i])
            i += 1
        }
        let summaryInline = parseInline(summaryTokens, schema, config)
        let body = parseBlocks(bodyTokens[...], schema, config)
        guard let detailsType = schema.nodes["details"],
              let summaryType = schema.nodes["detailsSummary"],
              let contentType = schema.nodes["detailsContent"] else {
            // No details in this schema: keep the text rather than dropping it.
            var out: [Node] = []
            if !summaryInline.isEmpty, let para = try? schema.node("paragraph", [:], content: Fragment.from(summaryInline)) {
                out.append(para)
            }
            return out + body
        }
        let summaryNodeAttrs = idAttrs(summaryAttrs, "detailsSummary", schema, config)
        guard let summary = (try? summaryType.create(summaryNodeAttrs, content: Fragment.from(summaryInline)))
                ?? summaryType.createAndFill(summaryNodeAttrs),
              let content = (try? contentType.create([:], content: Fragment.from(body)))
                ?? contentType.createAndFill([:], content: Fragment.from(body))
        else { return body }
        var a: Attrs = ["open": .bool(attrs["open"] != nil)]
        a.merge(idAttrs(attrs, "details", schema, config)) { _, new in new }
        guard let node = try? detailsType.create(a, content: Fragment.from([summary, content])) else { return body }
        return [node]
    }

    private static func parseTaskItem(_ tokens: Tokens, _ liStart: Int, _ liEnd: Int, _ liAttrs: [String: String], _ schema: Schema, _ config: HTMLConfig) -> Node? {
        guard let itemType = schema.nodes["taskItem"] else { return nil }
        var checked = liAttrs["data-checked"] == "true"
        // Drop the checkbox <input> from the item's content, recording its state.
        var inner: [Token] = []
        var k = liStart + 1
        while k < liEnd {
            if case let .open(t, a, _) = tokens[k], t == "input", (a["type"] ?? "") == "checkbox" {
                if a["checked"] != nil { checked = true }
                k += 1; continue
            }
            inner.append(tokens[k]); k += 1
        }
        // Trim the whitespace that typically sits between the checkbox and the text.
        if case let .text(s) = inner.first {
            inner[0] = .text(String(s.drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" })))
        }
        let children = parseBlocks(inner[...], schema, config)
        var a: Attrs = ["checked": .bool(checked)]
        a.merge(idAttrs(liAttrs, "taskItem", schema, config)) { _, new in new }
        if let n = try? itemType.create(a, content: Fragment.from(children)) { return n }
        return itemType.createAndFill(a, content: Fragment.from(children))
    }

    private static func listLooksLikeTasks(_ tokens: Tokens, _ start: Int, _ end: Int) -> Bool {
        var i = start + 1
        while i < end {
            if case let .open(t, a, _) = tokens[i] {
                if t == "input", (a["type"] ?? "") == "checkbox" { return true }
                if t == "li", a["data-checked"] != nil { return true }
            }
            i += 1
        }
        return false
    }

    /// The value of a CSS declaration in an inline `style` string, matching the
    /// property name exactly (so `color` doesn't match `background-color`).
    private static func styleValue(_ style: String, _ property: String) -> String? {
        for decl in style.split(separator: ";") {
            let parts = decl.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == property {
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    private static func parseColwidth(_ attrs: [String: String]) -> [Int]? {
        guard let s = attrs["data-colwidth"] else { return nil }
        let parts = s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parts.isEmpty ? nil : parts
    }

    // Parse inline content (text + marks + inline atoms) within a block.
    private static func parseInline(_ tokens: Tokens, _ schema: Schema, _ config: HTMLConfig) -> [Node] {
        var result: [Node] = []
        // Open mark scopes, each tagged with the HTML tag that opened it. A close
        // removes the *nearest matching* scope rather than blindly popping the
        // top, so crossed or stray tags in foreign clipboard HTML (e.g.
        // `<span style=color><strong>a</span>b</strong>`) can't pop — and corrupt
        // — a mark they didn't open. The active mark set is the open scopes' marks.
        var openMarks: [(tag: String, marks: [Mark])] = []
        // The set every piece of text in scope carries. It changes only when a
        // scope opens or closes, but a paragraph asks for it once per run of
        // text, so it's kept rather than rebuilt each time.
        //
        // Built with `addToSet` rather than concatenated, so a mark the schema
        // says can't sit alongside another is dropped instead of producing a set
        // the document model rejects — `<strong><code>x</code></strong>` is
        // ordinary markup, and `code` excludes everything else.
        var currentMarks: [Mark] = []
        func marksChanged() {
            currentMarks = openMarks.flatMap(\.marks).reduce(into: [Mark]()) { set, mark in
                set = mark.addToSet(set)
            }
        }
        var i = tokens.startIndex
        while i < tokens.endIndex {
            switch tokens[i] {
            case let .text(t):
                let text = decodeEntities(t)
                if !text.isEmpty { result.append(schema.text(text, currentMarks)) }
                i += 1
            case let .open(tag, attrs, selfClosing):
                if tag == "br", let br = try? schema.node("hardBreak") { result.append(br); i += 1; continue }
                if tag == "img" { if let img = makeImage(attrs, schema) { result.append(img) }; i += 1; continue }
                // `data-type="inline-math"` (or a block-math div that landed in an
                // inline context — `textblockSplittingBlocks` lifts it back out).
                if let math = makeMath(attrs, tokens, i, schema, config) {
                    result.append(math.node); i = math.next; continue
                }
                if tag == "math" {
                    if let math = makeMathML(tokens, i, schema, config) {
                        result.append(math.node); i = math.next
                    } else {
                        i = matchingClose(tokens, i, tag) + 1
                    }
                    continue
                }
                // The visual half of a KaTeX/MathJax formula, duplicating the
                // MathML beside it.
                if attrs["aria-hidden"] == "true" {
                    i = matchingClose(tokens, i, tag) + 1; continue
                }
                if tag == "sup", attrs["data-type"] == "footnoteReference",
                   let type = schema.nodes["footnoteReference"] {
                    let close = matchingClose(tokens, i, tag)
                    // The label is the identifier; the text is only the number
                    // a reader sees, so it is the attribute that carries it.
                    let label = attrs["data-label"] ?? innerText(tokens, i + 1, close)
                    if let reference = try? type.create(["label": .string(label)]) {
                        result.append(reference); i = close + 1; continue
                    }
                }
                if tag == "span", let id = attrs["data-mention"], schema.nodes["mention"] != nil {
                    let close = matchingClose(tokens, i, tag)
                    var label = innerText(tokens, i + 1, close)
                    if label.hasPrefix("@") { label.removeFirst() }
                    if let m = try? schema.nodes["mention"]?.create(["id": .string(id), "label": .string(label)]) {
                        result.append(m); i = close + 1; continue
                    }
                }
                // A styled <span> opens a scope contributing textColor / backgroundColor.
                if tag == "span" {
                    if !selfClosing {
                        var marks: [Mark] = []
                        if let style = attrs["style"] {
                            // Colors are re-serialized into a `style` attribute, so
                            // anything CSS can express would round-trip with them.
                            if let c = styleValue(style, "background-color").flatMap(sanitizeCSSColor),
                               let mt = schema.marks["backgroundColor"] {
                                marks.append(mt.create(["color": .string(c)]))
                            }
                            if let c = styleValue(style, "color").flatMap(sanitizeCSSColor),
                               let mt = schema.marks["textColor"] {
                                marks.append(mt.create(["color": .string(c)]))
                            }
                        }
                        openMarks.append((tag: "span", marks: marks))
                        marksChanged()
                    }
                    i += 1; continue
                }
                if tag == "a", attrs["data-wikilink"] != nil || schema.nodes["wikiLink"] != nil, attrs["data-wikilink"] != nil {
                    let rawTarget = attrs["data-wikilink"] ?? attrs["href"] ?? ""
                    let close = matchingClose(tokens, i, tag)
                    let label = innerText(tokens, i + 1, close)
                    // A wiki target is normally a page name, but it falls back to
                    // the href and is serialized back into one — so it gets the
                    // same treatment. Unsafe targets degrade to plain text.
                    guard let target = sanitizeURL(rawTarget, for: .link) else {
                        if !label.isEmpty { result.append(schema.text(label, currentMarks)) }
                        i = close + 1; continue
                    }
                    if let wl = try? schema.nodes["wikiLink"]?.create(["target": .string(target), "label": .string(label)]) {
                        result.append(wl); i = close + 1; continue
                    }
                }
                // A self-closing mark tag opens no lasting scope.
                if !selfClosing, let markName = config.tagToMark[tag], let markType = schema.marks[markName] {
                    var attrsDict: Attrs = [:]
                    if markName == "link" {
                        // A `javascript:` href would become a link the editor
                        // hands to the system on tap. Drop the mark, keep the text.
                        guard let href = sanitizeURL(attrs["href"] ?? "", for: .link) else {
                            openMarks.append((tag: tag, marks: []))
                            marksChanged()
                            i += 1; continue
                        }
                        attrsDict["href"] = .string(href)
                        if let title = attrs["title"] { attrsDict["title"] = .string(title) }
                    }
                    // `data-color` is what this serializer writes; a bare
                    // `background-color` style is what other editors emit.
                    if markName == "highlight", markType.attrs["color"] != nil {
                        if let color = attrs["data-color"] {
                            attrsDict["color"] = .string(color)
                        } else if let style = attrs["style"],
                                  let css = styleValue(style, "background-color").flatMap(sanitizeCSSColor) {
                            attrsDict["color"] = .string(css)
                        }
                    }
                    openMarks.append((tag: tag, marks: [markType.create(attrsDict)]))
                    marksChanged()
                }
                i += 1
            case let .close(tag):
                // Remove the nearest scope opened by this exact tag; a stray or
                // crossed close (no matching open) is ignored.
                if let idx = openMarks.lastIndex(where: { $0.tag == tag }) {
                    openMarks.remove(at: idx)
                    marksChanged()
                }
                i += 1
            }
        }
        return result
    }

    /// A math node from an element carrying Tiptap's `data-type="inline-math"` /
    /// `"block-math"`, with the node it produced and the token index just past
    /// its close tag. Nil when the element isn't math or the schema lacks the
    /// node — in which case the caller falls through and keeps the `$…$` text.
    ///
    /// The source comes from `data-latex`; an element written by hand without
    /// that attribute falls back to unwrapping the `$` fences from its text.
    private static func makeMath(_ attrs: [String: String], _ tokens: Tokens, _ start: Int,
                                 _ schema: Schema, _ config: HTMLConfig) -> (node: Node, next: Int)? {
        let name: String
        switch attrs["data-type"] {
        case "inline-math": name = "inlineMath"
        case "block-math": name = "blockMath"
        default: return nil
        }
        guard let type = schema.nodes[name] else { return nil }
        guard case let .open(tag, _, selfClosing) = tokens[start] else { return nil }
        let close = selfClosing ? start : matchingClose(tokens, start, tag)
        // Attribute values are already entity-decoded by the tokenizer, so
        // decoding again here would turn `&amp;lt;` in a formula into `<`.
        let latex = attrs["data-latex"] ?? unfence(innerText(tokens, start + 1, close))
        var a: Attrs = ["latex": .string(latex)]
        a.merge(idAttrs(attrs, name, schema, config)) { _, new in new }
        guard let node = try? type.create(a) else { return nil }
        return (node, close + 1)
    }

    /// A math node from a `<math>` element — the LaTeX read from its TeX
    /// annotation, its `alttext`, or converted from its presentation markup.
    ///
    /// Returns nil when nothing usable can be read out, and the caller then
    /// drops the element: a formula that arrives as scraped prose ("x2+1") is
    /// worse than one that doesn't arrive.
    private static func makeMathML(_ tokens: Tokens, _ start: Int,
                                   _ schema: Schema, _ config: HTMLConfig) -> (node: Node, next: Int)? {
        guard case let .open(tag, _, selfClosing) = tokens[start], tag == "math", !selfClosing else { return nil }
        let close = matchingClose(tokens, start, tag)
        guard let converted = MathML.latex(tokens, from: start, to: close) else { return nil }
        // Display maths wants the block node, inline maths the inline one; fall
        // back to whichever this schema actually has.
        let preferred = converted.display ? "blockMath" : "inlineMath"
        let fallback = converted.display ? "inlineMath" : "blockMath"
        guard let type = schema.nodes[preferred] ?? schema.nodes[fallback],
              let node = try? type.create(["latex": .string(converted.latex)]) else { return nil }
        return (node, close + 1)
    }

    /// Strip surrounding `$$`/`$` from a math element's display text.
    private static func unfence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for fence in ["$$", "$"] where s.hasPrefix(fence) && s.hasSuffix(fence) && s.count > 2 * fence.count {
            s = String(s.dropFirst(fence.count).dropLast(fence.count))
            break
        }
        return s
    }

    private static func makeImage(_ attrs: [String: String], _ schema: Schema) -> Node? {
        // A `data:text/html` or `data:image/svg+xml` source is a script the
        // moment anything renders it; an unsafe source drops the image.
        guard let type = schema.nodes["image"], let raw = attrs["src"],
              let src = sanitizeURL(raw, for: .image) else { return nil }
        var a: Attrs = ["src": .string(src)]
        if let alt = attrs["alt"] { a["alt"] = .string(alt) }
        if let title = attrs["title"] { a["title"] = .string(title) }
        if let w = attrs["width"].flatMap({ Int($0) }) { a["width"] = .int(w) }
        if let h = attrs["height"].flatMap({ Int($0) }) { a["height"] = .int(h) }
        if let path = attrs["data-model-path"], !path.isEmpty {
            var model: [String: AttributeValue] = ["path": .string(path)]
            if let w = attrs["data-model-width"].flatMap({ Int($0) }) { model["width"] = .int(w) }
            if let h = attrs["data-model-height"].flatMap({ Int($0) }) { model["height"] = .int(h) }
            a["model"] = .object(model)
        }
        return try? type.create(a)
    }

    static func innerText(_ tokens: Tokens, _ start: Int, _ end: Int) -> String {
        var text = ""
        var i = start
        while i < end {
            if case let .text(t) = tokens[i] { text += decodeEntities(t) }
            i += 1
        }
        return text
    }

    static func matchingClose(_ tokens: Tokens, _ openIndex: Int, _ tag: String) -> Int {
        guard case let .open(_, _, selfClosing) = tokens[openIndex], !selfClosing else { return openIndex }
        var depth = 0
        var i = openIndex
        while i < tokens.endIndex {
            switch tokens[i] {
            case let .open(t, _, sc) where t == tag && !sc: depth += 1
            case let .close(t) where t == tag:
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        // No close tag: treat everything to the end as the element's children.
        // (Returning count, not count-1: callers slice (open+1)..<end, and an
        // unterminated tag as the last token must not produce an inverted range.)
        return tokens.endIndex
    }

    // MARK: Tokenizer

    /// Exposed for benchmarking the tokenizer separately from the parse.
    public static func tokenCountForBenchmark(_ html: String) -> Int { tokenize(html).count }

    /// Tokenizing works on UTF-8 bytes rather than `Character`s. Every byte the
    /// scanner makes a decision on is ASCII, and no byte of a multi-byte UTF-8
    /// sequence is ever ASCII, so the two agree on where tags and text begin —
    /// without paying to break 200 KB of markup into grapheme clusters first.
    /// It also matches the HTML spec, which tokenizes over code points: a
    /// combining mark after a `>` used to fuse into one `Character` and hide the
    /// tag's end.
    static func tokenize(_ html: String) -> [Token] {
        // Borrowing the string's own UTF-8 rather than copying it into an
        // `Array` first: the scanner only ever reads bytes, and the copy was a
        // second pass over every byte of the input before any work began.
        var source = html
        return source.withUTF8 { unsafe tokenize($0) }
    }

    private static func tokenize(_ chars: UnsafeBufferPointer<UInt8>) -> [Token] {
        var tokens: [Token] = []
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
        let bang = UInt8(ascii: "!"), question = UInt8(ascii: "?")
        let slash = UInt8(ascii: "/")
        let doubleQuote = UInt8(ascii: "\""), singleQuote = UInt8(ascii: "'")
        var i = 0
        while i < chars.count {
            if unsafe chars[i] == lt {
                // Markup declarations, comments, CDATA, and processing
                // instructions: <!DOCTYPE …>, <!-- … -->, <![CDATA[ … ]]>, <? … >.
                // These aren't elements — skip them (a leading <!DOCTYPE> from
                // Cocoa's HTML writer / Apple Notes would otherwise swallow the
                // whole document).
                if i + 1 < chars.count, unsafe chars[i + 1] == bang || chars[i + 1] == question {
                    i = unsafe skipDeclaration(chars, from: i)
                    continue
                }
                // Find the end of the tag, ignoring any ">" inside a quoted
                // attribute value — `href="data:text/html,<b>"` is one tag, not
                // a tag that ends in the middle of its own href.
                var j = i + 1
                var quote: UInt8?
                while j < chars.count {
                    let c = unsafe chars[j]
                    if let open = quote {
                        if c == open { quote = nil }
                    } else if c == doubleQuote || c == singleQuote {
                        quote = c
                    } else if c == gt {
                        break
                    }
                    j += 1
                }
                let lo = i + 1, hi = min(j, chars.count)
                if lo < hi, unsafe chars[lo] == slash {
                    // An end tag is just a name; anything after it (`</a foo>`)
                    // is ignored, as browsers ignore end-tag attributes.
                    var s = lo + 1
                    while s < hi, unsafe isASCIIWhitespace(chars[s]) { s += 1 }
                    var e = s
                    while e < hi, unsafe !isASCIIWhitespace(chars[e]), unsafe chars[e] != slash { e += 1 }
                    unsafe tokens.append(.close(tag: name(chars, s, e)))
                } else {
                    let (tag, attrs, selfClosing) = unsafe parseTag(chars, lo, hi)
                    tokens.append(.open(tag: tag, attrs: attrs, selfClosing: selfClosing || voidTags.contains(tag)))
                }
                i = j + 1
            } else {
                var j = i
                while unsafe j < chars.count && chars[j] != lt { j += 1 }
                unsafe tokens.append(.text(decodeUTF8(chars, i, j)))
                i = j
            }
        }
        return tokens
    }

    /// The whitespace HTML separates a tag's parts with. `CharacterSet` would
    /// answer the same question for these bytes, but it is a Foundation call per
    /// character and it leaves out the newlines that any prettied-up markup puts
    /// between an element's attributes.
    private static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D || b == 0x0C
    }

    private static func decodeUTF8(_ b: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> String {
        unsafe lo < hi ? String(decoding: UnsafeBufferPointer(rebasing: b[lo..<hi]), as: UTF8.self) : ""
    }

    /// The tag or attribute name in `b[lo..<hi]`, ASCII-lowercased.
    ///
    /// Names are ASCII by definition and in practice already lowercase, so the
    /// common path just decodes the bytes: `lowercased()` consults Unicode case
    /// tables and allocates a second string to reach the same answer.
    private static func name(_ b: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> String {
        guard lo < hi else { return "" }
        var upper = false
        for k in lo..<hi where unsafe b[k] >= 0x41 && b[k] <= 0x5A { upper = true; break }
        guard upper else { return unsafe decodeUTF8(b, lo, hi) }
        var lowered = [UInt8](repeating: 0, count: hi - lo)
        for k in 0..<(hi - lo) {
            let c = unsafe b[lo + k]
            lowered[k] = (c >= 0x41 && c <= 0x5A) ? c | 0x20 : c
        }
        return String(decoding: lowered, as: UTF8.self)
    }

    /// Parse a start tag's interior — everything between `<` and `>` — into its
    /// name, its attributes, and whether it closed itself.
    private static func parseTag(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int)
        -> (String, [String: String], Bool) {
        let slash = UInt8(ascii: "/"), equals = UInt8(ascii: "=")
        let doubleQuote = UInt8(ascii: "\""), singleQuote = UInt8(ascii: "'")
        var lo = start, hi = end
        while lo < hi, unsafe isASCIIWhitespace(b[lo]) { lo += 1 }
        while hi > lo, unsafe isASCIIWhitespace(b[hi - 1]) { hi -= 1 }
        var selfClosing = false
        if hi > lo, unsafe b[hi - 1] == slash {
            selfClosing = true
            hi -= 1
            while hi > lo, unsafe isASCIIWhitespace(b[hi - 1]) { hi -= 1 }
        }
        var i = lo
        while i < hi, unsafe !isASCIIWhitespace(b[i]) { i += 1 }
        let tag = unsafe name(b, lo, i)
        var attrs: [String: String] = [:]
        while i < hi {
            while i < hi, unsafe isASCIIWhitespace(b[i]) { i += 1 }
            guard i < hi else { break }
            let keyStart = i
            while i < hi, unsafe !isASCIIWhitespace(b[i]), unsafe b[i] != equals { i += 1 }
            let key = unsafe name(b, keyStart, i)
            // `key = "value"` is one attribute, so the "=" is looked for past
            // any space. A name with no "=" after it is a bare attribute.
            while i < hi, unsafe isASCIIWhitespace(b[i]) { i += 1 }
            guard i < hi, unsafe b[i] == equals else {
                if !key.isEmpty { attrs[key] = "" }
                continue
            }
            i += 1
            while i < hi, unsafe isASCIIWhitespace(b[i]) { i += 1 }
            let value: String
            if i < hi, unsafe b[i] == doubleQuote || b[i] == singleQuote {
                let quote = unsafe b[i]
                i += 1
                let valueStart = i
                while i < hi, unsafe b[i] != quote { i += 1 }
                value = unsafe decodeUTF8(b, valueStart, i)
                if i < hi { i += 1 }
            } else {
                // An unquoted value runs to the next space — `<td colspan=2>` is
                // legal markup, and hand-written markup is full of it.
                let valueStart = i
                while i < hi, unsafe !isASCIIWhitespace(b[i]) { i += 1 }
                value = unsafe decodeUTF8(b, valueStart, i)
            }
            if !key.isEmpty { attrs[key] = decodeEntities(value) }
        }
        return (tag, attrs, selfClosing)
    }

    /// Skip a non-element construct starting at `start` (chars[start] == "<" and
    /// the next char is "!" or "?"). Returns the index just past its terminator:
    /// "-->" (or the spec's incorrectly-closed "--!>") for comments, "]]>" for
    /// CDATA, and the first ">" for everything else (DOCTYPEs and processing
    /// instructions — matching browsers' bogus-comment state). An unterminated
    /// construct consumes to end of input, as in browsers.
    private static func skipDeclaration(_ chars: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        func match(_ s: String, at j: Int) -> Bool {
            var k = j
            for c in s.utf8 {
                guard k < chars.count, unsafe chars[k] == c else { return false }
                k += 1
            }
            return true
        }
        if match("<!--", at: start) {
            // Spec: "<!-->" and "<!--->" are complete (abruptly-closed) empty
            // comments — parsing continues after them.
            if match(">", at: start + 4) { return start + 5 }
            if match("->", at: start + 4) { return start + 6 }
            var j = start + 4
            while j < chars.count {
                if match("-->", at: j) { return j + 3 }
                if match("--!>", at: j) { return j + 4 }
                j += 1
            }
            return chars.count
        }
        if match("<![CDATA[", at: start) {
            var j = start + 9
            while j < chars.count {
                if match("]]>", at: j) { return j + 3 }
                j += 1
            }
            return chars.count
        }
        var j = start + 1
        while j < chars.count, unsafe chars[j] != UInt8(ascii: ">") { j += 1 }
        return min(j + 1, chars.count)
    }

    private static let voidTags: Set<String> = ["br", "hr", "img", "input", "col", "wbr", "source", "area", "meta", "link"]

    /// The named character references that actually turn up in web article text.
    ///
    /// Not the full HTML5 set (~2,200 names, most of them mathematical): this is
    /// the long tail that matters for pasted prose — typographic punctuation,
    /// currency and symbols, and the accented Latin letters. Anything missing
    /// still round-trips as its literal source rather than being mangled, and
    /// numeric references (`&#8217;` / `&#xe9;`) are handled by the scanner
    /// itself, so they need no entries here.

    /// A numeric reference's character. Zero, a surrogate, and anything past the
    /// last code point are all errors that both HTML and CommonMark resolve to
    /// the replacement character rather than dropping.
    private static func scalarForReference(_ value: UInt32) -> Character {
        guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
        return Character(scalar)
    }

    /// How far to look for an entity's ";". A name is letters and digits (a
    /// numeric reference adds a leading "#"), so the search stops at the first
    /// character that can't be part of one — which is usually the very next one,
    /// and never more than the longest name we know. An unbounded scan is
    /// quadratic on "&"-dense text like a list of URLs.
    private static let entityWindow: Int = max(longestEntityName + 1, 12)

    /// Tested against the raw byte: `Character.isLetter` consults Unicode
    /// properties, which costs more per character than the whole scan should.
    /// A byte of a multi-byte UTF-8 sequence is never in range, so a name ends
    /// at one just as it would have on the `Character`.
    private static func isEntityNameByte(_ b: UInt8, first: Bool) -> Bool {
        if first, b == UInt8(ascii: "#") { return true }
        return (b >= 48 && b <= 57) || ((b | 0x20) >= 97 && (b | 0x20) <= 122)
    }

    static func decodeEntities(_ s: String, cappingNumericDigits capped: Bool = false) -> String {
        // Text with no "&" in it is the overwhelming majority, and this is the
        // only work done for it. Asked of the UTF-8 rather than the string,
        // because `contains` on a `Character` compares grapheme clusters —
        // which means breaking the whole string into them first.
        guard s.utf8.contains(UInt8(ascii: "&")) else { return s }
        var source = s
        return source.withUTF8 { unsafe decodeEntities($0, capped) }
    }

    /// Like the tokenizer, this reads bytes rather than `Character`s. Walking a
    /// `String.Index` costs a grapheme-cluster break per step, and the old
    /// window scan paid for up to 32 of them at every "&" — which on prose full
    /// of `&rsquo;` and `&mdash;` was most of the work.
    private static func decodeEntities(_ b: UnsafeBufferPointer<UInt8>, _ capped: Bool) -> String {
        let amp = UInt8(ascii: "&"), semi = UInt8(ascii: ";")
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            guard unsafe b[i] == amp else {
                // Everything up to the next "&" is copied in one move.
                var j = i + 1
                while j < b.count, unsafe b[j] != amp { j += 1 }
                unsafe out.append(contentsOf: UnsafeBufferPointer(rebasing: b[i..<j]))
                i = j
                continue
            }
            // An entity is "&" + a name or numeric reference + ";". Search for the
            // ";" only within the longest one that could match — an unbounded
            // scan is quadratic on '&'-dense text like URL lists. Numeric
            // references can be longer than any name, hence the floor.
            let start = i + 1
            let windowEnd = min(start + entityWindow, b.count)
            var scan = start
            while scan < windowEnd, unsafe isEntityNameByte(b[scan], first: scan == start) { scan += 1 }
            guard scan < windowEnd, unsafe b[scan] == semi, scan > start,
                  let decoded = unsafe entityValue(b, start, scan, capped)
            else { out.append(amp); i = start; continue }
            out.append(contentsOf: decoded.utf8)
            i = scan + 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The replacement for the reference named by `b[lo..<hi]` — the text
    /// between the "&" and its ";" — or nil when it names nothing, in which case
    /// the caller keeps the source as it was written.
    private static func entityValue(_ b: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int,
                                    _ capped: Bool) -> String? {
        if unsafe b[lo] != UInt8(ascii: "#") {
            return unsafe namedEntities[decodeUTF8(b, lo, hi)]
        }
        var digits = lo + 1
        var radix: UInt32 = 10
        if digits < hi, unsafe (b[digits] | 0x20) == UInt8(ascii: "x") {
            digits += 1
            radix = 16
        }
        guard digits < hi else { return nil }
        // HTML puts no limit on a reference's digits: its tokenizer takes them
        // all and resolves whatever is out of range to the replacement
        // character, which is why leading zeros are legal there. CommonMark
        // allows 7 decimal digits and 6 hexadecimal, and past that the text was
        // never a reference — `&#87654321;` is those characters, not U+FFFD.
        // Both dialects share this decoder, so the caller says which it reads.
        if capped, hi - digits > (radix == 16 ? 6 : 7) { return nil }
        var value: UInt32 = 0
        for k in digits..<hi {
            let c = unsafe b[k]
            let digit: UInt32
            if c >= 48, c <= 57 {
                digit = UInt32(c - 48)
            } else if radix == 16, (c | 0x20) >= 97, (c | 0x20) <= 102 {
                digit = UInt32((c | 0x20) - 87)
            } else {
                return nil
            }
            // A reference too long to hold is left as it was written, as it was
            // when this went through `UInt32.init(_:radix:)`.
            let (scaled, overflowed) = value.multipliedReportingOverflow(by: radix)
            guard !overflowed else { return nil }
            let (sum, carried) = scaled.addingReportingOverflow(digit)
            guard !carried else { return nil }
            value = sum
        }
        return String(scalarForReference(value))
    }
}
