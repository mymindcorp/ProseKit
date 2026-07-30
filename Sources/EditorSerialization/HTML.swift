import Foundation
import DocumentModel

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
            "inlineMath": "span", "blockMath": "div",
            "wikiLink": "a", "mention": "span",
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
                                      "inlineMath", "blockMath"]
        for (n, t) in nodeTags where !noReverse.contains(n) { tagToNode[t] = n }
        for h in 1...6 { tagToNode["h\(h)"] = "heading" }
        tagToNode["pre"] = "codeBlock"
        let tagToMark: [String: String] = [
            "strong": "bold", "b": "bold", "em": "italic", "i": "italic",
            "s": "strike", "del": "strike", "strike": "strike", "u": "underline",
            "mark": "highlight", "code": "code", "a": "link",
            "sub": "subscript", "sup": "superscript",
        ]
        return HTMLConfig(nodeTags: nodeTags, markTags: markTags, tagToNode: tagToNode, tagToMark: tagToMark)
    }()
}

// MARK: - Serialize

public enum HTMLSerializer {
    public static func serialize(_ doc: Node, config: HTMLConfig = .default) -> String {
        serializeFragment(doc.content, config)
    }

    /// Serialize a bare fragment (e.g. a copied selection's content) to HTML.
    public static func serialize(fragment: Fragment, config: HTMLConfig = .default) -> String {
        serializeFragment(fragment, config)
    }

    static func serializeFragment(_ fragment: Fragment, _ config: HTMLConfig) -> String {
        var out = ""
        // Group inline runs vs block nodes naturally by recursion.
        for i in 0..<fragment.childCount {
            out += serializeNode(fragment.child(i), config)
        }
        return out
    }

    /// ` data-id="…"` for a node carrying the UniqueID attribute, else "".
    static func idAttr(_ node: Node, _ config: HTMLConfig) -> String {
        guard let docAttr = config.idDocAttr,
              case let .string(id)? = node.attrs[docAttr] else { return "" }
        return " \(config.idHTMLAttr)=\"\(escapeAttribute(id))\""
    }

    static func serializeNode(_ node: Node, _ config: HTMLConfig) -> String {
        if node.isText {
            return applyMarks(escape(node.text ?? ""), node.marks, config)
        }
        switch node.type.name {
        case "heading":
            let level = node.attrs["level"]?.intValue ?? 1
            return "<h\(level)\(idAttr(node, config))>\(serializeFragment(node.content, config))</h\(level)>"
        case "codeBlock":
            return "<pre\(idAttr(node, config))><code>\(escape(node.textContent))</code></pre>"
        case "horizontalRule":
            return "<hr>"
        case "hardBreak":
            return "<br>"
        case "image":
            var attrs = " src=\"\(escapeAttribute(node.attrs["src"]?.stringValue ?? ""))\""
            if let alt = node.attrs["alt"]?.stringValue { attrs += " alt=\"\(escapeAttribute(alt))\"" }
            if let title = node.attrs["title"]?.stringValue { attrs += " title=\"\(escapeAttribute(title))\"" }
            if let w = node.attrs["width"]?.intValue { attrs += " width=\"\(w)\"" }
            if let h = node.attrs["height"]?.intValue { attrs += " height=\"\(h)\"" }
            // The original behind this rendition, as flat `data-` attributes —
            // readable markup, and no JSON to escape inside an attribute.
            if case let .object(model)? = node.attrs["model"],
               case let .string(path)? = model["path"] {
                attrs += " data-model-path=\"\(escapeAttribute(path))\""
                if let w = model["width"]?.intValue { attrs += " data-model-width=\"\(w)\"" }
                if let h = model["height"]?.intValue { attrs += " data-model-height=\"\(h)\"" }
            }
            return "<img\(attrs)>"
        case "wikiLink":
            let target = node.attrs["target"]?.stringValue ?? ""
            let label = node.attrs["label"]?.stringValue ?? target
            return "<a href=\"\(escapeAttribute(target))\" data-wikilink=\"\(escapeAttribute(target))\">\(escape(label))</a>"
        case "mention":
            let id = node.attrs["id"]?.stringValue ?? ""
            let label = node.attrs["label"]?.stringValue ?? id
            return "<span data-mention=\"\(escapeAttribute(id))\">\(escape("@" + label))</span>"
        case "taskList":
            return "<ul data-type=\"taskList\"\(idAttr(node, config))>\(serializeFragment(node.content, config))</ul>"
        case "taskItem":
            let checked = node.attrs["checked"]?.boolValue ?? false
            let box = "<input type=\"checkbox\"\(checked ? " checked=\"checked\"" : "")>"
            return "<li data-type=\"taskItem\" data-checked=\"\(checked)\"\(idAttr(node, config))>\(box)\(serializeFragment(node.content, config))</li>"
        case "details":
            let open = node.attrs["open"]?.boolValue ?? false
            return "<details\(open ? " open" : "")\(idAttr(node, config))>\(serializeFragment(node.content, config))</details>"
        case "detailsSummary":
            return "<summary\(idAttr(node, config))>\(serializeFragment(node.content, config))</summary>"
        case "detailsContent":
            return "<div data-type=\"detailsContent\"\(idAttr(node, config))>\(serializeFragment(node.content, config))</div>"
        case "inlineMath", "blockMath":
            // Tiptap's shape: the source lives in `data-latex`, and the element's
            // text is the `$…$` form so non-math readers still see the formula.
            let inline = node.type.name == "inlineMath"
            let tag = inline ? "span" : "div", fence = inline ? "$" : "$$"
            let latex = node.attrs["latex"]?.stringValue ?? ""
            return "<\(tag) data-type=\"\(inline ? "inline-math" : "block-math")\" "
                + "data-latex=\"\(escapeAttribute(latex))\"\(idAttr(node, config))>"
                + "\(escape(fence + latex + fence))</\(tag)>"
        case "tableCell", "tableHeader":
            let tag = node.type.name == "tableHeader" ? "th" : "td"
            var a = ""
            let cs = node.attrs["colspan"]?.intValue ?? 1, rs = node.attrs["rowspan"]?.intValue ?? 1
            if cs != 1 { a += " colspan=\"\(cs)\"" }
            if rs != 1 { a += " rowspan=\"\(rs)\"" }
            if case let .array(cw)? = node.attrs["colwidth"] {
                a += " data-colwidth=\"\(cw.map { String($0.intValue ?? 0) }.joined(separator: ","))\""
            }
            return "<\(tag)\(a)\(idAttr(node, config))>\(serializeFragment(node.content, config))</\(tag)>"
        default:
            let tag = config.nodeTags[node.type.name] ?? "div"
            return "<\(tag)\(idAttr(node, config))>\(serializeFragment(node.content, config))</\(tag)>"
        }
    }

    static func applyMarks(_ text: String, _ marks: [Mark], _ config: HTMLConfig) -> String {
        var result = text
        for mark in marks.reversed() {
            if mark.type.name == "link" {
                let href = mark.attrs["href"]?.stringValue ?? ""
                var attributes = " href=\"\(escapeAttribute(href))\""
                if let title = mark.attrs["title"]?.stringValue {
                    attributes += " title=\"\(escapeAttribute(title))\""
                }
                result = "<a\(attributes)>\(result)</a>"
            } else if mark.type.name == "highlight" {
                // The colour is a named style the theme resolves ("yellow"), not
                // necessarily a CSS colour — `data-color` is what round-trips it.
                // A style is emitted alongside only when the name happens to be
                // real CSS, so a highlight survives pasting into another app
                // without this ever writing a bogus declaration.
                var attributes = ""
                if let color = mark.attrs["color"]?.stringValue {
                    attributes = " data-color=\"\(escapeAttribute(color))\""
                    if let css = sanitizeCSSColor(color) {
                        attributes += " style=\"background-color:\(escapeAttribute(css))\""
                    }
                }
                result = "<mark\(attributes)>\(result)</mark>"
            } else if mark.type.name == "textColor", let c = mark.attrs["color"]?.stringValue {
                result = "<span style=\"color:\(escapeAttribute(c))\">\(result)</span>"
            } else if mark.type.name == "backgroundColor", let c = mark.attrs["color"]?.stringValue {
                result = "<span style=\"background-color:\(escapeAttribute(c))\">\(result)</span>"
            } else if let tag = config.markTags[mark.type.name] {
                result = "<\(tag)>\(result)</\(tag)>"
            }
        }
        return result
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escape a value going inside a double-quoted attribute. A bare `"` there
    /// would end the attribute early and corrupt the rest of the tag — reachable
    /// from any user-supplied text (an image `alt`, a `\text{"…"}` in a formula).
    static func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
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
        if let depth = excessiveNestingDepth(tokens) {
            throw HTMLParseError.nestingTooDeep(depth: depth, limit: maxNestingDepth)
        }
        let parsed = parseBlocks(tokens, schema, config)
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
    private static func excessiveNestingDepth(_ tokens: [Token]) -> Int? {
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

    private static func containsBlockTag(_ tokens: [Token]) -> Bool {
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
    private static func parseBlock(_ tokens: [Token], _ start: Int, _ schema: Schema, _ config: HTMLConfig) -> ([Node], Int)? {
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
            let inline = parseInline(Array(tokens[(start + 1)..<end]), schema, config)
            var a: Attrs = ["level": .int(level)]
            a.merge(idAttrs(attrs, "heading", schema, config)) { _, new in new }
            return (textblockSplittingBlocks(inline) { try? schema.node("heading", a, content: Fragment.from($0)) }, end + 1)
        case "codeBlock":
            let text = innerText(tokens, start + 1, end)
            let content = text.isEmpty ? Fragment.empty : Fragment.from([schema.text(text)])
            return (one(try? schema.node("codeBlock", idAttrs(attrs, "codeBlock", schema, config), content: content)), end + 1)
        case "paragraph":
            let inline = parseInline(Array(tokens[(start + 1)..<end]), schema, config)
            let a = idAttrs(attrs, "paragraph", schema, config)
            return (textblockSplittingBlocks(inline) { try? schema.node("paragraph", a, content: Fragment.from($0)) }, end + 1)
        case "bulletList", "orderedList":
            // ul/ol may actually be a task list (Tiptap data-type, or items with checkboxes).
            return (one(parseList(tag, attrs, tokens, start, end, schema, config)), end + 1)
        case "details":
            return (parseDetails(attrs, tokens, start, end, schema, config), end + 1)
        case "tableCell", "tableHeader":
            let parsed = parseBlocks(Array(tokens[(start + 1)..<end]), schema, config)
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
        case "blockquote", "listItem", "table", "tableRow":
            let parsed = parseBlocks(Array(tokens[(start + 1)..<end]), schema, config)
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
            let children = parseBlocks(Array(tokens[(start + 1)..<end]), schema, config)
            return (children, end + 1)
        }
    }

    /// Elements that belong inside a paragraph rather than beside one.
    ///
    /// Everything else keeps the old treatment — parsed as a block, or as an
    /// unknown container whose children are parsed as blocks — so an unfamiliar
    /// wrapper can't be mistaken for a run of text.
    private static let inlineTags: Set<String> = [
        "strong", "b", "em", "i", "s", "del", "strike", "u", "mark", "code", "a",
        "sub", "sup", "span", "br", "img", "math", "small", "abbr", "cite", "q",
        "time", "kbd", "samp", "var", "big", "font", "wbr", "bdi", "bdo", "ruby",
    ]

    private static func parseBlocks(_ tokens: [Token], _ schema: Schema, _ config: HTMLConfig) -> [Node] {
        var result: [Node] = []
        // Consecutive inline tokens belong to one paragraph. Without this each
        // element became its own block and its marks were lost, so
        // `<li>a <strong>b</strong> c</li>` came back as three unformatted
        // paragraphs — only `<p>` and `<div>` ever routed through `parseInline`.
        var inlineRun: [Token] = []
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

        var i = 0
        while i < tokens.count {
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
                        let close = min(matchingClose(tokens, i, tag), tokens.count - 1)
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
                    result.append(contentsOf: parseBlocks(Array(tokens[(i + 1)..<e]), schema, config))
                    i = e + 1; continue
                }
                // <head>/<style>/<script>/… — drop entirely.
                if skippedWrappers.contains(tag) { i = matchingClose(tokens, i, tag) + 1; continue }
                // <div>: a generic block container. With block children, flatten it;
                // otherwise treat its inline content as a paragraph (preserving marks).
                if tag == "div" {
                    let e = matchingClose(tokens, i, tag)
                    let inner = Array(tokens[(i + 1)..<e])
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
    private static func parseList(_ tag: String, _ attrs: [String: String], _ tokens: [Token], _ start: Int, _ end: Int, _ schema: Schema, _ config: HTMLConfig) -> Node? {
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
        let parsed = parseBlocks(Array(tokens[(start + 1)..<end]), schema, config)
        guard let type = schema.nodes[name] else { return nil }
        // A `<ul>` can contain things that aren't list items — real pages put
        // stray paragraphs and nested markup in there.
        let children = fitContent(parsed, into: type, schema: schema)
        let a = idAttrs(attrs, name, schema, config)
        if let n = try? type.create(a, content: Fragment.from(children)) { return n }
        return type.createAndFill(a, content: Fragment.from(children))
    }

    /// Parse a `<details>` into `details(detailsSummary, detailsContent)`. The
    /// `<summary>` (missing in hand-written HTML) becomes the summary; everything
    /// else becomes the content — whether or not it came wrapped in our
    /// `data-type="detailsContent"` div (that div flattens through `parseBlocks`).
    /// With a schema that has no details nodes, the section degrades to the
    /// summary as a paragraph followed by its body blocks.
    private static func parseDetails(_ attrs: [String: String], _ tokens: [Token], _ start: Int, _ end: Int,
                                     _ schema: Schema, _ config: HTMLConfig) -> [Node] {
        var summaryTokens: [Token] = []
        var summaryAttrs: [String: String] = [:]
        var bodyTokens: [Token] = []
        var i = start + 1
        while i < end {
            if case let .open(t, sAttrs, selfClosing) = tokens[i], t == "summary", !selfClosing, summaryTokens.isEmpty {
                let sEnd = matchingClose(tokens, i, "summary")
                summaryTokens = Array(tokens[(i + 1)..<min(sEnd, end)])
                summaryAttrs = sAttrs
                i = min(sEnd, end) + 1
                continue
            }
            bodyTokens.append(tokens[i])
            i += 1
        }
        let summaryInline = parseInline(summaryTokens, schema, config)
        let body = parseBlocks(bodyTokens, schema, config)
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

    private static func parseTaskItem(_ tokens: [Token], _ liStart: Int, _ liEnd: Int, _ liAttrs: [String: String], _ schema: Schema, _ config: HTMLConfig) -> Node? {
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
        let children = parseBlocks(inner, schema, config)
        var a: Attrs = ["checked": .bool(checked)]
        a.merge(idAttrs(liAttrs, "taskItem", schema, config)) { _, new in new }
        if let n = try? itemType.create(a, content: Fragment.from(children)) { return n }
        return itemType.createAndFill(a, content: Fragment.from(children))
    }

    private static func listLooksLikeTasks(_ tokens: [Token], _ start: Int, _ end: Int) -> Bool {
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
    private static func parseInline(_ tokens: [Token], _ schema: Schema, _ config: HTMLConfig) -> [Node] {
        var result: [Node] = []
        // Open mark scopes, each tagged with the HTML tag that opened it. A close
        // removes the *nearest matching* scope rather than blindly popping the
        // top, so crossed or stray tags in foreign clipboard HTML (e.g.
        // `<span style=color><strong>a</span>b</strong>`) can't pop — and corrupt
        // — a mark they didn't open. The active mark set is the open scopes' marks.
        var openMarks: [(tag: String, marks: [Mark])] = []
        func currentMarks() -> [Mark] { openMarks.flatMap { $0.marks } }
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case let .text(t):
                let text = decodeEntities(t)
                if !text.isEmpty { result.append(schema.text(text, currentMarks())) }
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
                        if !label.isEmpty { result.append(schema.text(label, currentMarks())) }
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
                }
                i += 1
            case let .close(tag):
                // Remove the nearest scope opened by this exact tag; a stray or
                // crossed close (no matching open) is ignored.
                if let idx = openMarks.lastIndex(where: { $0.tag == tag }) {
                    openMarks.remove(at: idx)
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
    private static func makeMath(_ attrs: [String: String], _ tokens: [Token], _ start: Int,
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
        let latex = attrs["data-latex"].map(decodeEntities)
            ?? unfence(innerText(tokens, start + 1, close))
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
    private static func makeMathML(_ tokens: [Token], _ start: Int,
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

    static func innerText(_ tokens: [Token], _ start: Int, _ end: Int) -> String {
        var text = ""
        var i = start
        while i < end {
            if case let .text(t) = tokens[i] { text += decodeEntities(t) }
            i += 1
        }
        return text
    }

    static func matchingClose(_ tokens: [Token], _ openIndex: Int, _ tag: String) -> Int {
        guard case let .open(_, _, selfClosing) = tokens[openIndex], !selfClosing else { return openIndex }
        var depth = 0
        var i = openIndex
        while i < tokens.count {
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
        return tokens.count
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
        var tokens: [Token] = []
        let chars = Array(html.utf8)
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
        let bang = UInt8(ascii: "!"), question = UInt8(ascii: "?")
        let doubleQuote = UInt8(ascii: "\""), singleQuote = UInt8(ascii: "'")
        var i = 0
        while i < chars.count {
            if chars[i] == lt {
                // Markup declarations, comments, CDATA, and processing
                // instructions: <!DOCTYPE …>, <!-- … -->, <![CDATA[ … ]]>, <? … >.
                // These aren't elements — skip them (a leading <!DOCTYPE> from
                // Cocoa's HTML writer / Apple Notes would otherwise swallow the
                // whole document).
                if i + 1 < chars.count, chars[i + 1] == bang || chars[i + 1] == question {
                    i = skipDeclaration(chars, from: i)
                    continue
                }
                // Find the end of the tag, ignoring any ">" inside a quoted
                // attribute value — `href="data:text/html,<b>"` is one tag, not
                // a tag that ends in the middle of its own href.
                var j = i + 1
                var quote: UInt8?
                while j < chars.count {
                    let c = chars[j]
                    if let open = quote {
                        if c == open { quote = nil }
                    } else if c == doubleQuote || c == singleQuote {
                        quote = c
                    } else if c == gt {
                        break
                    }
                    j += 1
                }
                let raw = String(decoding: chars[(i + 1)..<min(j, chars.count)], as: UTF8.self)
                if raw.hasPrefix("/") {
                    tokens.append(.close(tag: raw.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()))
                } else {
                    let (tag, attrs, selfClosing) = parseTag(raw)
                    tokens.append(.open(tag: tag, attrs: attrs, selfClosing: selfClosing || voidTags.contains(tag)))
                }
                i = j + 1
            } else {
                var j = i
                while j < chars.count && chars[j] != lt { j += 1 }
                tokens.append(.text(String(decoding: chars[i..<j], as: UTF8.self)))
                i = j
            }
        }
        return tokens
    }

    /// Skip a non-element construct starting at `start` (chars[start] == "<" and
    /// the next char is "!" or "?"). Returns the index just past its terminator:
    /// "-->" (or the spec's incorrectly-closed "--!>") for comments, "]]>" for
    /// CDATA, and the first ">" for everything else (DOCTYPEs and processing
    /// instructions — matching browsers' bogus-comment state). An unterminated
    /// construct consumes to end of input, as in browsers.
    private static func skipDeclaration(_ chars: [UInt8], from start: Int) -> Int {
        func match(_ s: String, at j: Int) -> Bool {
            var k = j
            for c in s.utf8 {
                guard k < chars.count, chars[k] == c else { return false }
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
        while j < chars.count, chars[j] != UInt8(ascii: ">") { j += 1 }
        return min(j + 1, chars.count)
    }

    private static let voidTags: Set<String> = ["br", "hr", "img", "input", "col", "wbr", "source", "area", "meta", "link"]

    private static func parseTag(_ raw: String) -> (String, [String: String], Bool) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        let selfClosing = s.hasSuffix("/")
        if selfClosing { s.removeLast() }
        let scanner = Array(s)
        var idx = 0
        func skipSpace() { while idx < scanner.count && scanner[idx] == " " { idx += 1 } }
        // tag name
        var name = ""
        while idx < scanner.count && scanner[idx] != " " { name.append(scanner[idx]); idx += 1 }
        var attrs: [String: String] = [:]
        while idx < scanner.count {
            skipSpace()
            var key = ""
            while idx < scanner.count && scanner[idx] != "=" && scanner[idx] != " " { key.append(scanner[idx]); idx += 1 }
            if idx < scanner.count && scanner[idx] == "=" {
                idx += 1
                if idx < scanner.count && (scanner[idx] == "\"" || scanner[idx] == "'") {
                    let quote = scanner[idx]; idx += 1
                    var value = ""
                    while idx < scanner.count && scanner[idx] != quote { value.append(scanner[idx]); idx += 1 }
                    idx += 1
                    if !key.isEmpty { attrs[key.lowercased()] = decodeEntities(value) }
                }
            } else if !key.isEmpty {
                attrs[key.lowercased()] = ""
            }
            if idx < scanner.count && scanner[idx] == " " { continue }
            if key.isEmpty { idx += 1 }
        }
        return (name.lowercased(), attrs, selfClosing)
    }

    /// The named character references that actually turn up in web article text.
    ///
    /// Not the full HTML5 set (~2,200 names, most of them mathematical): this is
    /// the long tail that matters for pasted prose — typographic punctuation,
    /// currency and symbols, and the accented Latin letters. Anything missing
    /// still round-trips as its literal source rather than being mangled, and
    /// numeric references (`&#8217;` / `&#xe9;`) are handled by the scanner
    /// itself, so they need no entries here.
    private static let namedEntities: [String: Character] = [
        // Markup delimiters.
        "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&",

        // Spaces and invisible formatting.
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "shy": "\u{00AD}", "zwnj": "\u{200C}", "zwj": "\u{200D}",

        // Typographic punctuation — the bulk of what breaks in practice.
        "mdash": "—", "ndash": "–", "hellip": "…",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "sbquo": "\u{201A}", "bdquo": "\u{201E}", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "laquo": "«", "raquo": "»", "bull": "•", "middot": "·",
        "dagger": "†", "Dagger": "‡", "prime": "′", "Prime": "″",
        "iexcl": "¡", "iquest": "¿", "para": "¶", "sect": "§", "brvbar": "¦",

        // Symbols, currency, and the handful of maths that shows up in prose.
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "micro": "µ",
        "plusmn": "±", "times": "×", "divide": "÷", "minus": "−",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³",
        "cent": "¢", "pound": "£", "yen": "¥", "euro": "€", "curren": "¤",
        "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥",
        "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔",

        // Mathematical and Greek symbols. Worth carrying because the editor has
        // a math extension: formulas pasted as HTML arrive written this way.
        // Greek lowercase.
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ",
        "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "rho": "ρ", "sigmaf": "ς",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ", "psi": "ψ",
        "omega": "ω", "thetasym": "ϑ", "upsih": "ϒ", "piv": "ϖ",
        // Greek uppercase.
        "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Epsilon": "Ε", "Zeta": "Ζ",
        "Eta": "Η", "Theta": "Θ", "Iota": "Ι", "Kappa": "Κ", "Lambda": "Λ", "Mu": "Μ",
        "Nu": "Ν", "Xi": "Ξ", "Omicron": "Ο", "Pi": "Π", "Rho": "Ρ", "Sigma": "Σ", "Tau": "Τ",
        "Upsilon": "Υ", "Phi": "Φ", "Chi": "Χ", "Psi": "Ψ", "Omega": "Ω",
        // Operators and relations.
        "sum": "∑", "prod": "∏", "int": "∫", "part": "∂", "nabla": "∇", "radic": "√",
        "lowast": "∗", "sdot": "⋅", "equiv": "≡", "cong": "≅", "asymp": "≈", "prop": "∝",
        "sim": "∼", "there4": "∴", "ang": "∠", "perp": "⊥",
        // Set theory and logic.
        "isin": "∈", "notin": "∉", "ni": "∋", "sub": "⊂", "sup": "⊃", "sube": "⊆", "supe": "⊇",
        "nsub": "⊄", "cap": "∩", "cup": "∪", "empty": "∅", "forall": "∀", "exist": "∃",
        "and": "∧", "or": "∨", "not": "¬",
        // Double arrows.
        "lArr": "⇐", "uArr": "⇑", "rArr": "⇒", "dArr": "⇓", "hArr": "⇔",
        // Technical and misc.
        "alefsym": "ℵ", "weierp": "℘", "image": "ℑ", "real": "ℜ", "fnof": "ƒ", "oline": "‾",
        "frasl": "⁄", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋", "lang": "⟨",
        "rang": "⟩", "loz": "◊", "spades": "♠", "clubs": "♣", "hearts": "♥", "diams": "♦",

        // Accented Latin letters.
        "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä", "atilde": "ã", "aring": "å",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë",
        "iacute": "í", "igrave": "ì", "icirc": "î", "iuml": "ï",
        "oacute": "ó", "ograve": "ò", "ocirc": "ô", "ouml": "ö", "otilde": "õ", "oslash": "ø",
        "uacute": "ú", "ugrave": "ù", "ucirc": "û", "uuml": "ü",
        "yacute": "ý", "yuml": "ÿ", "ccedil": "ç", "ntilde": "ñ",
        "szlig": "ß", "aelig": "æ", "oelig": "œ", "thorn": "þ", "eth": "ð",
        "Aacute": "Á", "Agrave": "À", "Acirc": "Â", "Auml": "Ä", "Atilde": "Ã", "Aring": "Å",
        "Eacute": "É", "Egrave": "È", "Ecirc": "Ê", "Euml": "Ë",
        "Iacute": "Í", "Igrave": "Ì", "Icirc": "Î", "Iuml": "Ï",
        "Oacute": "Ó", "Ograve": "Ò", "Ocirc": "Ô", "Ouml": "Ö", "Otilde": "Õ", "Oslash": "Ø",
        "Uacute": "Ú", "Ugrave": "Ù", "Ucirc": "Û", "Uuml": "Ü",
        "Yacute": "Ý", "Ccedil": "Ç", "Ntilde": "Ñ",
        "AElig": "Æ", "OElig": "Œ", "THORN": "Þ", "ETH": "Ð",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            // An entity is "&" + a short name or numeric reference + ";". Search
            // for the ";" only within the longest legal entity (10 chars) — an
            // unbounded scan is quadratic on '&'-dense text like URL lists.
            guard s[i] == "&" else { out.append(s[i]); i = s.index(after: i); continue }
            let next = s.index(after: i)
            let windowEnd = s.index(next, offsetBy: 10, limitedBy: s.endIndex) ?? s.endIndex
            guard let semi = s[next..<windowEnd].firstIndex(of: ";")
            else { out.append(s[i]); i = next; continue }
            let name = s[next..<semi]
            var decoded: Character?
            if let c = namedEntities[String(name)] {
                decoded = c
            } else if name.hasPrefix("#x") || name.hasPrefix("#X") {
                if let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { decoded = Character(u) }
            } else if name.hasPrefix("#") {
                if let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { decoded = Character(u) }
            }
            if let decoded {
                out.append(decoded)
                i = s.index(after: semi)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }
}
