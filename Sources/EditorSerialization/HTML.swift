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

    public static let `default`: HTMLConfig = {
        let nodeTags: [String: String] = [
            "paragraph": "p", "blockquote": "blockquote",
            "bulletList": "ul", "orderedList": "ol", "listItem": "li",
            "horizontalRule": "hr", "hardBreak": "br", "image": "img",
            "table": "table", "tableRow": "tr", "tableCell": "td", "tableHeader": "th",
            "taskList": "ul", "taskItem": "li",
            "wikiLink": "a", "mention": "span",
        ]
        let markTags: [String: String] = [
            "bold": "strong", "italic": "em", "strike": "s", "underline": "u",
            "highlight": "mark", "code": "code", "link": "a",
        ]
        var tagToNode: [String: String] = [:]
        // taskList/taskItem also use ul/li but need a data-type to round-trip,
        // so they don't claim the reverse mapping (ul→bulletList, li→listItem).
        let noReverse: Set<String> = ["wikiLink", "mention", "taskList", "taskItem"]
        for (n, t) in nodeTags where !noReverse.contains(n) { tagToNode[t] = n }
        for h in 1...6 { tagToNode["h\(h)"] = "heading" }
        tagToNode["pre"] = "codeBlock"
        let tagToMark: [String: String] = [
            "strong": "bold", "b": "bold", "em": "italic", "i": "italic",
            "s": "strike", "del": "strike", "strike": "strike", "u": "underline",
            "mark": "highlight", "code": "code", "a": "link",
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

    static func serializeNode(_ node: Node, _ config: HTMLConfig) -> String {
        if node.isText {
            return applyMarks(escape(node.text ?? ""), node.marks, config)
        }
        switch node.type.name {
        case "heading":
            let level = node.attrs["level"]?.intValue ?? 1
            return "<h\(level)>\(serializeFragment(node.content, config))</h\(level)>"
        case "codeBlock":
            return "<pre><code>\(escape(node.textContent))</code></pre>"
        case "horizontalRule":
            return "<hr>"
        case "hardBreak":
            return "<br>"
        case "image":
            var attrs = " src=\"\(escape(node.attrs["src"]?.stringValue ?? ""))\""
            if let alt = node.attrs["alt"]?.stringValue { attrs += " alt=\"\(escape(alt))\"" }
            if let title = node.attrs["title"]?.stringValue { attrs += " title=\"\(escape(title))\"" }
            if let w = node.attrs["width"]?.intValue { attrs += " width=\"\(w)\"" }
            return "<img\(attrs)>"
        case "wikiLink":
            let target = node.attrs["target"]?.stringValue ?? ""
            let label = node.attrs["label"]?.stringValue ?? target
            return "<a href=\"\(escape(target))\" data-wikilink=\"\(escape(target))\">\(escape(label))</a>"
        case "mention":
            let id = node.attrs["id"]?.stringValue ?? ""
            let label = node.attrs["label"]?.stringValue ?? id
            return "<span data-mention=\"\(escape(id))\">\(escape("@" + label))</span>"
        case "taskList":
            return "<ul data-type=\"taskList\">\(serializeFragment(node.content, config))</ul>"
        case "taskItem":
            let checked = node.attrs["checked"]?.boolValue ?? false
            let box = "<input type=\"checkbox\"\(checked ? " checked=\"checked\"" : "")>"
            return "<li data-type=\"taskItem\" data-checked=\"\(checked)\">\(box)\(serializeFragment(node.content, config))</li>"
        case "tableCell", "tableHeader":
            let tag = node.type.name == "tableHeader" ? "th" : "td"
            var a = ""
            let cs = node.attrs["colspan"]?.intValue ?? 1, rs = node.attrs["rowspan"]?.intValue ?? 1
            if cs != 1 { a += " colspan=\"\(cs)\"" }
            if rs != 1 { a += " rowspan=\"\(rs)\"" }
            if case let .array(cw)? = node.attrs["colwidth"] {
                a += " data-colwidth=\"\(cw.map { String($0.intValue ?? 0) }.joined(separator: ","))\""
            }
            return "<\(tag)\(a)>\(serializeFragment(node.content, config))</\(tag)>"
        default:
            let tag = config.nodeTags[node.type.name] ?? "div"
            return "<\(tag)>\(serializeFragment(node.content, config))</\(tag)>"
        }
    }

    static func applyMarks(_ text: String, _ marks: [Mark], _ config: HTMLConfig) -> String {
        var result = text
        for mark in marks.reversed() {
            if mark.type.name == "link" {
                let href = mark.attrs["href"]?.stringValue ?? ""
                result = "<a href=\"\(escape(href))\">\(result)</a>"
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

    public static func parse(_ html: String, schema: Schema, config: HTMLConfig = .default) throws -> Node {
        let tokens = tokenize(html)
        var blocks = parseBlocks(tokens, schema, config)
        if blocks.isEmpty, let p = schema.nodes["paragraph"]?.createAndFill() {
            blocks = [p]
        }
        return try schema.node("doc", [:], content: Fragment.from(blocks))
    }

    // Tags whose children are spliced in transparently (document/section wrappers).
    private static let transparentWrappers: Set<String> = ["html", "body", "tbody", "thead", "tfoot"]
    // Tags dropped entirely along with their content (document metadata, CSS, JS).
    private static let skippedWrappers: Set<String> = ["head", "style", "script", "title", "noscript", "colgroup"]
    private static let blockTags: Set<String> = [
        "p", "div", "ul", "ol", "li", "table", "tr", "td", "th", "tbody", "thead", "tfoot",
        "blockquote", "pre", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article",
    ]

    private static func containsBlockTag(_ tokens: [Token]) -> Bool {
        for t in tokens { if case let .open(tag, _, _) = t, blockTags.contains(tag) { return true } }
        return false
    }

    private static func one(_ node: Node?) -> [Node] { node.map { [$0] } ?? [] }

    /// Wrap inline content as a textblock, but split it around any block-level
    /// atoms (e.g. a block `image`) so each becomes its own sibling rather than an
    /// invalid child of the textblock. With an inline-image schema nothing splits.
    private static func textblockSplittingBlocks(_ inline: [Node], wrap: ([Node]) -> Node?) -> [Node] {
        guard inline.contains(where: { $0.type.isBlock }) else {
            return one(wrap(inline)) // no block atoms → a single (possibly empty) textblock
        }
        var out: [Node] = []
        var run: [Node] = []
        func flush() { if !run.isEmpty { out.append(contentsOf: one(wrap(run))); run = [] } }
        for node in inline {
            if node.type.isBlock { flush(); out.append(node) } else { run.append(node) }
        }
        flush()
        return out
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
            return (textblockSplittingBlocks(inline) { try? schema.node("heading", ["level": .int(level)], content: Fragment.from($0)) }, end + 1)
        case "codeBlock":
            let text = innerText(tokens, start + 1, end)
            let content = text.isEmpty ? Fragment.empty : Fragment.from([schema.text(text)])
            return (one(try? schema.node("codeBlock", [:], content: content)), end + 1)
        case "paragraph":
            let inline = parseInline(Array(tokens[(start + 1)..<end]), schema, config)
            return (textblockSplittingBlocks(inline) { try? schema.node("paragraph", [:], content: Fragment.from($0)) }, end + 1)
        case "bulletList", "orderedList":
            // ul/ol may actually be a task list (Tiptap data-type, or items with checkboxes).
            return (one(parseList(tag, attrs, tokens, start, end, schema, config)), end + 1)
        case "tableCell", "tableHeader":
            let children = parseBlocks(Array(tokens[(start + 1)..<end]), schema, config)
            var a: Attrs = [:]
            if let cs = attrs["colspan"].flatMap({ Int($0) }), cs != 1 { a["colspan"] = .int(cs) }
            if let rs = attrs["rowspan"].flatMap({ Int($0) }), rs != 1 { a["rowspan"] = .int(rs) }
            if let cw = parseColwidth(attrs) { a["colwidth"] = .array(cw.map { .int($0) }) }
            if let type = schema.nodes[nodeName!] {
                if let n = try? type.create(a, content: Fragment.from(children)) { return ([n], end + 1) }
                if let filled = type.createAndFill(a, content: Fragment.from(children)) { return ([filled], end + 1) }
            }
            return ([], end + 1)
        case "blockquote", "listItem", "table", "tableRow":
            let children = parseBlocks(Array(tokens[(start + 1)..<end]), schema, config)
            let name = nodeName!
            if let type = schema.nodes[name] {
                if let n = try? type.create([:], content: Fragment.from(children)) { return ([n], end + 1) }
                if let filled = type.createAndFill([:], content: Fragment.from(children)) { return ([filled], end + 1) }
            }
            return ([], end + 1)
        default:
            // Unknown block: try its children as blocks.
            let children = parseBlocks(Array(tokens[(start + 1)..<end]), schema, config)
            return (children, end + 1)
        }
    }

    private static func parseBlocks(_ tokens: [Token], _ schema: Schema, _ config: HTMLConfig) -> [Node] {
        var result: [Node] = []
        var i = 0
        while i < tokens.count {
            if case let .open(tag, _, _) = tokens[i] {
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
            if !items.isEmpty, let n = try? listType.create([:], content: Fragment.from(items)) { return n }
        }
        let name = config.tagToNode[tag] ?? "bulletList"
        let children = parseBlocks(Array(tokens[(start + 1)..<end]), schema, config)
        guard let type = schema.nodes[name] else { return nil }
        if let n = try? type.create([:], content: Fragment.from(children)) { return n }
        return type.createAndFill([:], content: Fragment.from(children))
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
        let a: Attrs = ["checked": .bool(checked)]
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

    private static func parseColwidth(_ attrs: [String: String]) -> [Int]? {
        guard let s = attrs["data-colwidth"] else { return nil }
        let parts = s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parts.isEmpty ? nil : parts
    }

    // Parse inline content (text + marks + inline atoms) within a block.
    private static func parseInline(_ tokens: [Token], _ schema: Schema, _ config: HTMLConfig) -> [Node] {
        var result: [Node] = []
        var markStack: [Mark] = []
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case let .text(t):
                let text = decodeEntities(t)
                if !text.isEmpty { result.append(schema.text(text, markStack)) }
                i += 1
            case let .open(tag, attrs, selfClosing):
                if tag == "br", let br = try? schema.node("hardBreak") { result.append(br); i += 1; continue }
                if tag == "img" { if let img = makeImage(attrs, schema) { result.append(img) }; i += 1; continue }
                if tag == "span", let id = attrs["data-mention"], schema.nodes["mention"] != nil {
                    let close = matchingClose(tokens, i, tag)
                    var label = innerText(tokens, i + 1, close)
                    if label.hasPrefix("@") { label.removeFirst() }
                    if let m = try? schema.nodes["mention"]?.create(["id": .string(id), "label": .string(label)]) {
                        result.append(m); i = close + 1; continue
                    }
                }
                if tag == "a", attrs["data-wikilink"] != nil || schema.nodes["wikiLink"] != nil, attrs["data-wikilink"] != nil {
                    let target = attrs["data-wikilink"] ?? attrs["href"] ?? ""
                    let close = matchingClose(tokens, i, tag)
                    let label = innerText(tokens, i + 1, close)
                    if let wl = try? schema.nodes["wikiLink"]?.create(["target": .string(target), "label": .string(label)]) {
                        result.append(wl); i = close + 1; continue
                    }
                }
                if let markName = config.tagToMark[tag], let markType = schema.marks[markName] {
                    var attrsDict: Attrs = [:]
                    if markName == "link" { attrsDict["href"] = .string(attrs["href"] ?? "") }
                    markStack.append(markType.create(attrsDict))
                }
                if selfClosing, let markName = config.tagToMark[tag], schema.marks[markName] != nil {
                    markStack.removeLast()
                }
                i += 1
            case let .close(tag):
                if config.tagToMark[tag] != nil, !markStack.isEmpty { markStack.removeLast() }
                i += 1
            }
        }
        return result
    }

    private static func makeImage(_ attrs: [String: String], _ schema: Schema) -> Node? {
        guard let type = schema.nodes["image"], let src = attrs["src"] else { return nil }
        var a: Attrs = ["src": .string(src)]
        if let alt = attrs["alt"] { a["alt"] = .string(alt) }
        if let title = attrs["title"] { a["title"] = .string(title) }
        if let w = attrs["width"].flatMap({ Int($0) }) { a["width"] = .int(w) }
        return try? type.create(a)
    }

    private static func innerText(_ tokens: [Token], _ start: Int, _ end: Int) -> String {
        var text = ""
        var i = start
        while i < end {
            if case let .text(t) = tokens[i] { text += decodeEntities(t) }
            i += 1
        }
        return text
    }

    private static func matchingClose(_ tokens: [Token], _ openIndex: Int, _ tag: String) -> Int {
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

    static func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(html)
        var i = 0
        while i < chars.count {
            if chars[i] == "<" {
                // Markup declarations, comments, CDATA, and processing
                // instructions: <!DOCTYPE …>, <!-- … -->, <![CDATA[ … ]]>, <? … >.
                // These aren't elements — skip them (a leading <!DOCTYPE> from
                // Cocoa's HTML writer / Apple Notes would otherwise swallow the
                // whole document).
                if i + 1 < chars.count, chars[i + 1] == "!" || chars[i + 1] == "?" {
                    i = skipDeclaration(chars, from: i)
                    continue
                }
                // find end of tag
                var j = i + 1
                while j < chars.count && chars[j] != ">" { j += 1 }
                let raw = String(chars[(i + 1)..<min(j, chars.count)])
                if raw.hasPrefix("/") {
                    tokens.append(.close(tag: raw.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()))
                } else {
                    let (tag, attrs, selfClosing) = parseTag(raw)
                    tokens.append(.open(tag: tag, attrs: attrs, selfClosing: selfClosing || voidTags.contains(tag)))
                }
                i = j + 1
            } else {
                var j = i
                while j < chars.count && chars[j] != "<" { j += 1 }
                let text = String(chars[i..<j])
                tokens.append(.text(text))
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
    private static func skipDeclaration(_ chars: [Character], from start: Int) -> Int {
        func match(_ s: String, at j: Int) -> Bool {
            var k = j
            for c in s {
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
        while j < chars.count, chars[j] != ">" { j += 1 }
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

    private static let namedEntities: [String: Character] = [
        "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&", "nbsp": "\u{00A0}",
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
