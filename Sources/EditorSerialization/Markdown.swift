import Foundation
import DocumentModel

// MARK: - Serialize

public enum MarkdownSerializer {
    public static func serialize(_ doc: Node) -> String {
        var blocks: [String] = []
        for i in 0..<doc.childCount {
            blocks.append(serializeBlock(doc.child(i), indent: ""))
        }
        return blocks.joined(separator: "\n\n")
    }

    static func serializeBlock(_ node: Node, indent: String) -> String {
        switch node.type.name {
        case "paragraph":
            return escapeLeadingBlockMarker(serializeInline(node.content))
        case "heading":
            let level = node.attrs["level"]?.intValue ?? 1
            return String(repeating: "#", count: level) + " " + serializeInline(node.content)
        case "blockquote":
            let inner = (0..<node.childCount).map { serializeBlock(node.child($0), indent: indent) }.joined(separator: "\n\n")
            return inner.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        case "codeBlock":
            return "```\n\(node.textContent)\n```"
        case "horizontalRule":
            return "---"
        case "bulletList":
            return (0..<node.childCount).map { "- " + listItemText(node.child($0)) }.joined(separator: "\n")
        case "orderedList":
            let start = node.attrs["order"]?.intValue ?? 1
            return (0..<node.childCount).map { "\(start + $0). " + listItemText(node.child($0)) }.joined(separator: "\n")
        case "details":
            // Markdown has no collapsible section; emit the HTML block form that
            // GitHub-flavored Markdown (and our parser) understands.
            let open = node.attrs["open"]?.boolValue ?? false
            let summary = node.childCount > 0 ? serializeInline(node.child(0).content) : ""
            let content = node.childCount > 1 ? node.child(1) : nil
            let body = content.map { c in
                (0..<c.childCount).map { serializeBlock(c.child($0), indent: indent) }.joined(separator: "\n\n")
            } ?? ""
            return "<details\(open ? " open" : "")>\n<summary>\(summary)</summary>\n\n\(body)\n\n</details>"
        default:
            return serializeInline(node.content)
        }
    }

    /// Escape a leading `#`/`>`/`-`/`*`/`+`/`1.` so a paragraph that happens to
    /// start with block-marker syntax round-trips as a paragraph, not a heading/
    /// quote/list.
    private static func escapeLeadingBlockMarker(_ s: String) -> String {
        let chars = Array(s)
        guard let first = chars.first else { return s }
        if first == "#" {
            var n = 0
            while n < chars.count, chars[n] == "#" { n += 1 }
            if n <= 6, n == chars.count || chars[n] == " " { return "\\" + s }
        }
        if first == ">" { return "\\" + s }
        if first == "-" || first == "*" || first == "+", chars.count > 1, chars[1] == " " { return "\\" + s }
        var n = 0
        while n < chars.count, chars[n].isNumber { n += 1 }
        if n > 0, n < chars.count, chars[n] == ".", n + 1 < chars.count, chars[n + 1] == " " {
            return String(chars[0..<n]) + "\\." + String(chars[(n + 1)...])
        }
        return s
    }

    static func listItemText(_ item: Node) -> String {
        (0..<item.childCount).map { serializeBlock(item.child($0), indent: "  ") }.joined(separator: "\n  ")
    }

    static func serializeInline(_ fragment: Fragment) -> String {
        var out = ""
        for i in 0..<fragment.childCount {
            let node = fragment.child(i)
            if node.isText {
                out += applyMarks(node.text ?? "", node.marks)
            } else if node.type.name == "hardBreak" {
                out += "\\\n"
            } else if node.type.name == "image" {
                let src = node.attrs["src"]?.stringValue ?? ""
                let alt = node.attrs["alt"]?.stringValue ?? ""
                out += "![\(alt)](\(src))"
            } else if node.type.name == "wikiLink" {
                let target = node.attrs["target"]?.stringValue ?? ""
                if let label = node.attrs["label"]?.stringValue { out += "[[\(target)|\(label)]]" }
                else { out += "[[\(target)]]" }
            }
        }
        return out
    }

    static func applyMarks(_ text: String, _ marks: [Mark]) -> String {
        var result = text
        // link is outermost; code innermost-ish
        if marks.contains(where: { $0.type.name == "code" }) { result = "`\(result)`" }
        if marks.contains(where: { $0.type.name == "highlight" }) { result = "==\(result)==" }
        if marks.contains(where: { $0.type.name == "strike" }) { result = "~~\(result)~~" }
        if marks.contains(where: { $0.type.name == "bold" }) { result = "**\(result)**" }
        if marks.contains(where: { $0.type.name == "italic" }) { result = "*\(result)*" }
        if let link = marks.first(where: { $0.type.name == "link" }) {
            result = "[\(result)](\(link.attrs["href"]?.stringValue ?? ""))"
        }
        return result
    }
}

public extension Node {
    /// Serialize this node — typically the document — to Markdown.
    func toMarkdown() -> String { MarkdownSerializer.serialize(self) }
}

// MARK: - Parse

public enum MarkdownParser {
    public static func parse(_ markdown: String, schema: Schema) throws -> Node {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [Node] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            // Code fence
            if trimmed.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1
                let text = code.joined(separator: "\n")
                let content = text.isEmpty ? Fragment.empty : Fragment.from([schema.text(text)])
                if let cb = try? schema.node("codeBlock", [:], content: content) { blocks.append(cb) }
                continue
            }
            // A `<details>` HTML block (what the serializer emits for a
            // collapsible section, and the GFM convention for one).
            if trimmed.lowercased().hasPrefix("<details") {
                var inner: [String] = []
                let open = detailsIsOpen(trimmed)
                i += 1
                var depth = 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces).lowercased()
                    if t.hasPrefix("<details") { depth += 1 }
                    if t.hasPrefix("</details>") {
                        depth -= 1
                        if depth == 0 { i += 1; break }
                    }
                    inner.append(lines[i]); i += 1
                }
                if let section = try makeDetails(inner, open: open, schema: schema) {
                    blocks.append(contentsOf: section)
                }
                continue
            }
            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                if let hr = try? schema.node("horizontalRule") { blocks.append(hr) }
                i += 1; continue
            }
            // Heading
            if let m = headingMatch(trimmed) {
                let inline = parseInline(m.text, schema)
                if let h = try? schema.node("heading", ["level": .int(m.level)], content: Fragment.from(inline)) {
                    blocks.append(h)
                }
                i += 1; continue
            }
            // Blockquote
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var l = lines[i].trimmingCharacters(in: .whitespaces)
                    l.removeFirst()
                    if l.hasPrefix(" ") { l.removeFirst() }
                    quote.append(l)
                    i += 1
                }
                let inner = try parse(quote.joined(separator: "\n"), schema: schema)
                if let bq = try? schema.node("blockquote", [:], content: inner.content) { blocks.append(bq) }
                continue
            }
            // Lists
            if let bullet = bulletMatch(trimmed) {
                let (items, next) = collectList(lines, i, ordered: false)
                if let list = makeList(items, ordered: false, schema: schema) { blocks.append(list) }
                i = next
                _ = bullet
                continue
            }
            if let ordered = orderedMatch(trimmed) {
                let (items, next) = collectList(lines, i, ordered: true)
                if let list = makeList(items, ordered: true, schema: schema, start: ordered) { blocks.append(list) }
                i = next
                continue
            }
            // Paragraph (gather consecutive non-blank, non-special lines)
            var para: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```")
                    || t.lowercased().hasPrefix("<details") || t.lowercased().hasPrefix("</details>")
                    || bulletMatch(t) != nil || orderedMatch(t) != nil { break }
                para.append(t); i += 1
            }
            // Keep line breaks so the inline parser can turn a trailing `\` into a
            // hard break and collapse other soft wraps into spaces.
            let inline = parseInline(para.joined(separator: "\n"), schema)
            if let p = try? schema.node("paragraph", [:], content: Fragment.from(inline)) { blocks.append(p) }
        }
        if blocks.isEmpty, let p = schema.nodes["paragraph"]?.createAndFill() { blocks = [p] }
        return try schema.node("doc", [:], content: Fragment.from(blocks))
    }

    /// Whether a `<details …>` opening line carries the `open` attribute.
    private static func detailsIsOpen(_ line: String) -> Bool {
        let body = line.lowercased().dropFirst("<details".count)
        return body.contains("open")
    }

    /// Build `details(detailsSummary, detailsContent)` from the lines inside a
    /// `<details>` block. Without those nodes in the schema (or without a
    /// `<summary>`), it degrades to a paragraph plus the body blocks.
    private static func makeDetails(_ lines: [String], open: Bool, schema: Schema) throws -> [Node]? {
        var summaryText = ""
        var body: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if summaryText.isEmpty, trimmed.lowercased().hasPrefix("<summary>") {
                var s = String(trimmed.dropFirst("<summary>".count))
                if let close = s.range(of: "</summary>", options: [.backwards, .caseInsensitive]) {
                    s = String(s[..<close.lowerBound])
                }
                summaryText = s
                continue
            }
            body.append(line)
        }
        let bodyDoc = try parse(body.joined(separator: "\n"), schema: schema)
        let summaryInline = parseInline(summaryText, schema)
        guard let detailsType = schema.nodes["details"],
              let summaryType = schema.nodes["detailsSummary"],
              let contentType = schema.nodes["detailsContent"] else {
            var out: [Node] = []
            if !summaryInline.isEmpty, let para = try? schema.node("paragraph", [:], content: Fragment.from(summaryInline)) {
                out.append(para)
            }
            return out + (0..<bodyDoc.childCount).map { bodyDoc.child($0) }
        }
        guard let summary = (try? summaryType.create([:], content: Fragment.from(summaryInline))) ?? summaryType.createAndFill(),
              let content = (try? contentType.create([:], content: bodyDoc.content)) ?? contentType.createAndFill(),
              let node = try? detailsType.create(["open": .bool(open)], content: Fragment.from([summary, content]))
        else { return nil }
        return [node]
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for c in line { if c == "#" { level += 1 } else { break } }
        guard level >= 1, level <= 6, line.count > level, Array(line)[level] == " " else { return nil }
        let text = String(line.dropFirst(level + 1))
        return (level, text)
    }

    private static func bulletMatch(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(2))
        }
        return nil
    }

    private static func orderedMatch(_ line: String) -> Int? {
        var digits = ""
        for c in line { if c.isNumber { digits.append(c) } else { break } }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return Int(digits)
    }

    private static func collectList(_ lines: [String], _ start: Int, ordered: Bool) -> (items: [String], next: Int) {
        var items: [String] = []
        var i = start
        func isItem(_ t: String) -> Bool { ordered ? orderedMatch(t) != nil : bulletMatch(t) != nil }
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                // A blank line continues the list (loose list) only if another item
                // of the same kind follows; otherwise the list ends here.
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count, isItem(lines[j].trimmingCharacters(in: .whitespaces)) { i = j; continue }
                break
            }
            if ordered, orderedMatch(t) != nil {
                items.append(String(t.drop(while: { $0.isNumber }).dropFirst(2)))
                i += 1
            } else if !ordered, let text = bulletMatch(t) {
                items.append(text); i += 1
            } else { break }
        }
        return (items, i)
    }

    private static func makeList(_ items: [String], ordered: Bool, schema: Schema, start: Int = 1) -> Node? {
        guard let itemType = schema.nodes["listItem"] else { return nil }
        var itemNodes: [Node] = []
        for text in items {
            let inline = parseInline(text, schema)
            guard let p = try? schema.node("paragraph", [:], content: Fragment.from(inline)) else { continue }
            guard let item = try? itemType.create([:], content: Fragment.from([p])) else { continue }
            itemNodes.append(item)
        }
        let listName = ordered ? "orderedList" : "bulletList"
        let attrs: Attrs = ordered ? ["order": .int(start)] : [:]
        return try? schema.node(listName, attrs, content: Fragment.from(itemNodes))
    }

    // Inline parser: handles **bold**, *italic*/_italic_, `code`, ~~strike~~,
    // ==highlight==, [text](url), ![alt](src), and [[wiki|link]].
    static func parseInline(_ text: String, _ schema: Schema) -> [Node] {
        var nodes: [Node] = []
        let chars = Array(text)
        var i = 0
        var buffer = ""
        func flush(_ marks: [Mark] = []) {
            if !buffer.isEmpty { nodes.append(schema.text(buffer, marks)); buffer = "" }
        }
        func mark(_ name: String, _ attrs: Attrs = [:]) -> [Mark] {
            schema.marks[name].map { [$0.create(attrs)] } ?? []
        }
        let asciiPunct = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        while i < chars.count {
            let c = chars[i]
            // Backslash: a hard break before a newline, otherwise an escape that
            // emits the next punctuation character literally.
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "\n" {
                    flush()
                    if let br = try? schema.nodes["hardBreak"]?.create() { nodes.append(br) }
                    i += 2; continue
                }
                if asciiPunct.contains(next) { buffer.append(next); i += 2; continue }
            }
            // Soft line break collapses to a space.
            if c == "\n" { buffer.append(" "); i += 1; continue }
            // Wiki link [[...]]
            if c == "[" && i + 1 < chars.count && chars[i + 1] == "[" {
                if let close = findSeq(chars, i + 2, "]]") {
                    flush()
                    let inner = String(chars[(i + 2)..<close])
                    let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
                    var attrs: Attrs = ["target": .string(parts[0])]
                    if parts.count > 1 { attrs["label"] = .string(parts[1]) }
                    if let wl = try? schema.nodes["wikiLink"]?.create(attrs) { nodes.append(wl) }
                    i = close + 2
                    continue
                }
            }
            // Image ![alt](src)
            if c == "!" && i + 1 < chars.count && chars[i + 1] == "[" {
                if let (alt, url, next) = parseLinkLike(chars, i + 1) {
                    flush()
                    if let src = sanitizeURL(url, for: .image), let type = schema.nodes["image"],
                       let img = try? type.create(["src": .string(src), "alt": .string(alt)]) {
                        nodes.append(img)
                    }
                    i = next; continue
                }
            }
            // Link [text](url)
            if c == "[" {
                if let (label, url, next) = parseLinkLike(chars, i) {
                    flush()
                    // Markdown reaches the editor from the same untrusted places
                    // HTML does, so `[x](javascript:…)` gets the same treatment:
                    // the link is dropped, the text kept.
                    if let href = sanitizeURL(url, for: .link) {
                        nodes.append(schema.text(label, mark("link", ["href": .string(href)])))
                    } else if !label.isEmpty {
                        nodes.append(schema.text(label))
                    }
                    i = next; continue
                }
            }
            // Bold ** **
            if c == "*" && i + 1 < chars.count && chars[i + 1] == "*" {
                if let close = findSeq(chars, i + 2, "**") {
                    flush()
                    nodes.append(schema.text(String(chars[(i + 2)..<close]), mark("bold")))
                    i = close + 2; continue
                }
            }
            // Italic * * or _ _
            if c == "*" || c == "_" {
                if let close = findChar(chars, i + 1, c) {
                    flush()
                    nodes.append(schema.text(String(chars[(i + 1)..<close]), mark("italic")))
                    i = close + 1; continue
                }
            }
            // Strike ~~ ~~
            if c == "~" && i + 1 < chars.count && chars[i + 1] == "~" {
                if let close = findSeq(chars, i + 2, "~~") {
                    flush()
                    nodes.append(schema.text(String(chars[(i + 2)..<close]), mark("strike")))
                    i = close + 2; continue
                }
            }
            // Highlight == ==
            if c == "=" && i + 1 < chars.count && chars[i + 1] == "=" {
                if let close = findSeq(chars, i + 2, "==") {
                    flush()
                    nodes.append(schema.text(String(chars[(i + 2)..<close]), mark("highlight")))
                    i = close + 2; continue
                }
            }
            // Code ` `
            if c == "`" {
                if let close = findChar(chars, i + 1, "`") {
                    flush()
                    nodes.append(schema.text(String(chars[(i + 1)..<close]), mark("code")))
                    i = close + 1; continue
                }
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return nodes
    }

    private static func parseLinkLike(_ chars: [Character], _ start: Int) -> (text: String, url: String, next: Int)? {
        guard chars[start] == "[" else { return nil }
        guard let closeBracket = findChar(chars, start + 1, "]") else { return nil }
        guard closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(" else { return nil }
        guard let closeParen = findChar(chars, closeBracket + 2, ")") else { return nil }
        let text = String(chars[(start + 1)..<closeBracket])
        let url = String(chars[(closeBracket + 2)..<closeParen])
        return (text, url, closeParen + 1)
    }

    private static func findChar(_ chars: [Character], _ from: Int, _ ch: Character) -> Int? {
        var i = from
        while i < chars.count { if chars[i] == ch { return i }; i += 1 }
        return nil
    }

    private static func findSeq(_ chars: [Character], _ from: Int, _ seq: String) -> Int? {
        let s = Array(seq)
        var i = from
        while i + s.count <= chars.count {
            if Array(chars[i..<(i + s.count)]) == s { return i }
            i += 1
        }
        return nil
    }
}
