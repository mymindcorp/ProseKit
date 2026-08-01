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
            // A heading is one line, so a line break inside its content — which
            // a mark spanning a soft wrap can carry — reads as a space.
            var text = serializeInline(node.content)
                .replacingOccurrences(of: "\n", with: " ")
            // A trailing run of "#" reads as a closing sequence, so escape it.
            if text.hasSuffix("#") {
                let run = text.reversed().prefix(while: { $0 == "#" }).count
                text.insert("\\", at: text.index(text.endIndex, offsetBy: -run))
            }
            return String(repeating: "#", count: level) + " " + text
        case "blockquote":
            let inner = (0..<node.childCount).map { serializeBlock(node.child($0), indent: indent) }.joined(separator: "\n\n")
            return inner.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        case "codeBlock":
            // Fence with the delimiter the code itself doesn't use.
            let fence = node.textContent.contains("```") ? "~~~" : "```"
            return "\(fence)\n\(node.textContent)\n\(fence)"
        case "horizontalRule":
            return "---"
        case "bulletList":
            return (0..<node.childCount).map { "- " + listItemText(node.child($0), continuation: "  ") }
                .joined(separator: "\n")
        case "taskList":
            // GitHub's checkbox syntax. Without this the list fell to the default
            // branch and serialized to nothing at all, taking its contents with it.
            return (0..<node.childCount).map { i -> String in
                let item = node.child(i)
                let box = (item.attrs["checked"]?.boolValue ?? false) ? "- [x] " : "- [ ] "
                return box + listItemText(item, continuation: "  ")
            }.joined(separator: "\n")
        case "orderedList":
            let start = node.attrs["order"]?.intValue ?? 1
            return (0..<node.childCount).map { i in
                let marker = "\(start + i). "
                return marker + listItemText(node.child(i),
                                             continuation: String(repeating: " ", count: marker.count))
            }.joined(separator: "\n")
        case "image":
            // An image is block-level in the default schema, and without a case
            // here it fell through to serializing an atom's content — which is
            // empty, so every image simply disappeared.
            let src = node.attrs["src"]?.stringValue ?? ""
            let alt = node.attrs["alt"]?.stringValue ?? ""
            if let title = node.attrs["title"]?.stringValue, !title.isEmpty {
                let q = title.contains("\"") ? "'" : "\""
                return "![\(alt)](\(destination(src)) \(q)\(title)\(q))"
            }
            return "![\(alt)](\(destination(src)))"
        case "blockMath":
            // The `$$…$$` display-math convention shared by Pandoc, MathJax, and
            // most Markdown renderers with math support.
            // No escaping needed: display math ends at a line that *starts* with
            // "$$", so dollars inside the formula are already safe.
            return "$$\n\(node.attrs["latex"]?.stringValue ?? "")\n$$"
        case "figure":
            // Markdig's figure fence: `^^^` around the content, with the caption
            // trailing the closing fence. Unlike `details` — which has no
            // Markdown spelling at all and falls back to raw HTML — a figure has
            // one, so it reads as Markdown when the nodes are registered. It is
            // a Markdig extension rather than CommonMark, so only our own parser
            // and Markdig will understand it; other readers see literal text.
            var body: [String] = []
            var caption = ""
            for i in 0..<node.childCount {
                let child = node.child(i)
                if child.type.name == "figcaption" {
                    caption = serializeInline(child.content)
                } else {
                    body.append(serializeBlock(child, indent: indent))
                }
            }
            let fenceEnd = caption.isEmpty ? "^^^" : "^^^ \(caption)"
            return "^^^\n\(body.joined(separator: "\n\n"))\n\(fenceEnd)"
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
        // A figure fence, when the figure nodes are registered. ("$$" needs no
        // case here — dollars are already escaped everywhere in prose.)
        if s.hasPrefix("^^^") { return "\\" + s }
        if first == "-" || first == "*" || first == "+", chars.count > 1, chars[1] == " " { return "\\" + s }
        var n = 0
        while n < chars.count, chars[n].isNumber { n += 1 }
        if n > 0, n < chars.count, chars[n] == ".", n + 1 < chars.count, chars[n + 1] == " " {
            return String(chars[0..<n]) + "\\." + String(chars[(n + 1)...])
        }
        return s
    }

    /// CommonMark keeps a block in a list item only while every one of its lines
    /// is indented to the content column — "indenting subsequent lines of Ls by
    /// W + N spaces". Indenting just the first line of each child left the rest
    /// of a multi-line block (a `$$` formula, a fenced code block) sitting at
    /// column 0, where it reads as a sibling of the list rather than part of it.
    static func listItemText(_ item: Node, continuation: String) -> String {
        // A `listItem` must begin with a paragraph, so an item whose real
        // content is a code block carries an empty one that `fitContent` added.
        // Writing it out would put a blank line after the marker, which reads
        // back as a different document — and the reader re-inserts the empty
        // paragraph anyway.
        var children = (0..<item.childCount).map { item.child($0) }
        if children.count > 1, children[0].type.name == "paragraph", children[0].content.size == 0 {
            children.removeFirst()
        }
        // Blocks are separated by a blank line here as everywhere else, or two
        // paragraphs in one item would read back as a single paragraph.
        let body = children
            .map { serializeBlock($0, indent: continuation) }
            .joined(separator: "\n\n")
        let lines = body.components(separatedBy: "\n")
        guard lines.count > 1 else { return body }
        return ([lines[0]] + lines.dropFirst().map { $0.isEmpty ? "" : continuation + $0 })
            .joined(separator: "\n")
    }

    /// Marks that wrap a run of inline content, outermost first. A mark can
    /// cover several nodes — `**[a](x) b**` is one bold run across a link and
    /// some text — so they are opened and closed around runs, not per node.
    private static let spanningMarks = ["link", "italic", "bold", "strike", "highlight"]

    private static func markOpen(_ mark: Mark) -> String {
        switch mark.type.name {
        case "link": return "["
        case "italic": return "*"
        case "bold": return "**"
        case "strike": return "~~"
        case "highlight": return "=="
        default: return ""
        }
    }

    private static func markClose(_ mark: Mark) -> String {
        switch mark.type.name {
        case "link":
            let href = mark.attrs["href"]?.stringValue ?? ""
            if let title = mark.attrs["title"]?.stringValue, !title.isEmpty {
                let q = title.contains("\"") ? "'" : "\""
                return "](\(destination(href)) \(q)\(title)\(q))"
            }
            return "](\(destination(href)))"
        case "italic": return "*"
        case "bold": return "**"
        case "strike": return "~~"
        case "highlight": return "=="
        default: return ""
        }
    }

    static func serializeInline(_ fragment: Fragment) -> String {
        var out = ""
        // Marks currently open, outermost first.
        var active: [Mark] = []
        func closeDown(to keep: Int) {
            while active.count > keep { out += markClose(active.removeLast()) }
        }
        func carries(_ node: Node, _ mark: Mark) -> Bool {
            node.marks.contains { $0.type === mark.type && $0.attrs == mark.attrs }
        }
        // Where a mark's unbroken run starting at `from` ends.
        func runEnd(_ mark: Mark, from: Int) -> Int {
            var j = from
            while j < fragment.childCount, carries(fragment.child(j), mark) { j += 1 }
            return j
        }
        for i in 0..<fragment.childCount {
            let node = fragment.child(i)
            // The spanning marks this node carries. A mark covering more of what
            // follows is written outside one covering less, so a bold run across
            // a link and the text after it comes out as `**[a](x) b**` rather
            // than as two bold runs with the link between them.
            let own = spanningMarks
                .compactMap { name in node.marks.first { $0.type.name == name } }
                .enumerated()
                .sorted { left, right in
                    let a = runEnd(left.element, from: i), b = runEnd(right.element, from: i)
                    return a == b ? left.offset < right.offset : a > b
                }
                .map(\.element)
            // A node that can't carry a mark shouldn't close it either. A code
            // span excludes every other mark, so closing and reopening emphasis
            // around one would emit delimiter runs that don't parse — and the
            // reader drops the excluded mark from the code span regardless.
            func canCarry(_ mark: Mark) -> Bool {
                !node.isText || mark.addToSet(node.marks).contains { $0.type === mark.type }
            }
            var wanted: [Mark] = []
            for mark in active
            where own.contains(where: { $0.type === mark.type && $0.attrs == mark.attrs })
                || !canCarry(mark) {
                wanted.append(mark)
            }
            for mark in own
            where !wanted.contains(where: { $0.type === mark.type && $0.attrs == mark.attrs }) {
                wanted.append(mark)
            }
            // Keep whatever the previous node already opened, in the same order.
            var shared = 0
            while shared < active.count, shared < wanted.count,
                  active[shared].type === wanted[shared].type,
                  active[shared].attrs == wanted[shared].attrs { shared += 1 }
            closeDown(to: shared)
            for mark in wanted[shared...] {
                // A "!" directly before a link's bracket would read back as an
                // image, so escape it. Only there — escaping every exclamation
                // mark in prose would be noise.
                if mark.type.name == "link", out.hasSuffix("!") {
                    out.removeLast()
                    out += "\\!"
                }
                out += markOpen(mark)
                active.append(mark)
            }
            out += inlineBody(node)
        }
        closeDown(to: 0)
        return out
    }

    /// A node's own text, with the marks that don't wrap a run — currently only
    /// `code`, whose fence length depends on the content it holds.
    private static func inlineBody(_ node: Node) -> String {
        if node.isText {
            let text = node.text ?? ""
            guard node.marks.contains(where: { $0.type.name == "code" }) else {
                // A delimiter character has to be escaped or it pairs with a
                // later one and becomes markup.
                return escapeInline(text)
            }
            // A code span is literal, so escapes inside one would read back as
            // backslashes; it is fenced by a run longer than any it contains.
            var longest = 0, current = 0
            for ch in text {
                current = ch == "`" ? current + 1 : 0
                longest = max(longest, current)
            }
            let fence = String(repeating: "`", count: longest + 1)
            let allSpaces = !text.isEmpty && text.allSatisfy { $0 == " " }
            let edgy = text.hasPrefix("`") || text.hasSuffix("`")
                || text.hasPrefix(" ") || text.hasSuffix(" ")
            let pad = (!allSpaces && edgy) ? " " : ""
            return "\(fence)\(pad)\(text)\(pad)\(fence)"
        }
        switch node.type.name {
        case "hardBreak":
            return "\\\n"
        case "image":
            // An image can sit inline as well as in its own block, so the title
            // has to be written on both paths.
            let src = node.attrs["src"]?.stringValue ?? ""
            let alt = node.attrs["alt"]?.stringValue ?? ""
            if let title = node.attrs["title"]?.stringValue, !title.isEmpty {
                let q = title.contains("\"") ? "'" : "\""
                return "![\(alt)](\(destination(src)) \(q)\(title)\(q))"
            }
            return "![\(alt)](\(destination(src)))"
        case "wikiLink":
            let target = node.attrs["target"]?.stringValue ?? ""
            if let label = node.attrs["label"]?.stringValue { return "[[\(target)|\(label)]]" }
            return "[[\(target)]]"
        case "inlineMath":
            // An empty formula has no spelling: "$$" opens display math, and no
            // dialect accepts "$$" as empty inline math. Emitting nothing beats
            // emitting a stray delimiter that swallows what follows.
            let latex = inlineMathSource(node.attrs["latex"]?.stringValue ?? "")
            return latex.isEmpty ? "" : "$\(latex)$"
        default:
            return ""
        }
    }

    /// Backslash-escape the characters this parser treats as inline markup, so
    /// text comes back as text. CommonMark allows any ASCII punctuation to be
    /// escaped, so the output stays portable.
    ///
    /// Without this, a document loses content on a save/load cycle:
    /// `snake_case_name` came back as `snakecasename`, `2 * 3 * 4` as `2  3  4`,
    /// and `====` as nothing at all — the delimiters were consumed as (empty)
    /// marks rather than read as text.
    static func escapeInline(_ text: String) -> String {
        // A backslash has to be escaped too, or it would escape whatever we add.
        let always: Set<Character> = ["\\", "`", "*", "_", "[", "]", "$", "&", "<"]
        // These only open markup when doubled (`==highlight==`, `~~strike~~`), so
        // a lone one is left alone — "x = y" shouldn't grow a backslash.
        let whenDoubled: Set<Character> = ["=", "~"]
        guard text.contains(where: { always.contains($0) || whenDoubled.contains($0) })
        else { return text }

        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count + 8)
        for (i, c) in chars.enumerated() {
            let doubled = whenDoubled.contains(c)
                && ((i > 0 && chars[i - 1] == c) || (i + 1 < chars.count && chars[i + 1] == c))
            if always.contains(c) || doubled { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Prepare a formula for `$…$`. A bare `$` would close the math early, so it
    /// becomes `\$` — already-escaped dollars are left alone, so a formula that
    /// spells its dollar correctly round-trips unchanged. Inline math is a single
    /// line by definition, and TeX treats a newline as whitespace, so folding one
    /// to a space keeps the formula's meaning.
    static func inlineMathSource(_ latex: String) -> String {
        var out = ""
        var escaped = false
        for c in latex {
            if c == "$" && !escaped {
                out += "\\$"
            } else if c == "\n" {
                out += " "
            } else {
                out.append(c)
            }
            escaped = (c == "\\" && !escaped)
        }
        return out
    }

    /// A destination that contains a space, a parenthesis or a backslash can't
    /// be written bare — CommonMark's answer is to wrap it in angle brackets.
    static func destination(_ url: String) -> String {
        url.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "\\" })
            ? "<\(url)>" : url
    }

    static func applyMarks(_ text: String, _ marks: [Mark]) -> String {
        var result = text
        // link is outermost; code innermost-ish
        if marks.contains(where: { $0.type.name == "code" }) {
            var longest = 0, current = 0
            for ch in result {
                current = ch == "`" ? current + 1 : 0
                longest = max(longest, current)
            }
            let fence = String(repeating: "`", count: longest + 1)
            // Pad when the content would otherwise start or end with a
            // backtick (which would extend the fence) or with a space (which
            // the reader strips). Content that is nothing but spaces is left
            // alone — the reader only strips when there's something between.
            let allSpaces = !result.isEmpty && result.allSatisfy { $0 == " " }
            let edgy = result.hasPrefix("`") || result.hasSuffix("`")
                || result.hasPrefix(" ") || result.hasSuffix(" ")
            let pad = (!allSpaces && edgy) ? " " : ""
            result = "\(fence)\(pad)\(result)\(pad)\(fence)"
        }
        if marks.contains(where: { $0.type.name == "highlight" }) { result = "==\(result)==" }
        if marks.contains(where: { $0.type.name == "strike" }) { result = "~~\(result)~~" }
        if marks.contains(where: { $0.type.name == "bold" }) { result = "**\(result)**" }
        if marks.contains(where: { $0.type.name == "italic" }) { result = "*\(result)*" }
        if let link = marks.first(where: { $0.type.name == "link" }) {
            let href = link.attrs["href"]?.stringValue ?? ""
            if let title = link.attrs["title"]?.stringValue, !title.isEmpty {
                let q = title.contains("\"") ? "'" : "\""
                result = "[\(result)](\(destination(href)) \(q)\(title)\(q))"
            } else {
                result = "[\(result)](\(destination(href)))"
            }
        }
        return result
    }
}

public extension Node {
    /// Serialize this node — typically the document — to Markdown.
    func toMarkdown() -> String { MarkdownSerializer.serialize(self) }
}

// MARK: - Parse

/// Why Markdown couldn't be parsed into a document.
public enum MarkdownParseError: Error, CustomStringConvertible, Equatable {
    /// The parsed content couldn't be fitted to the schema. Structural coercion
    /// handles the shapes Markdown produces, so this means the schema itself
    /// can't express the document — a bug rather than bad input.
    case invalidDocument(String)

    public var description: String {
        switch self {
        case let .invalidDocument(reason):
            return "MarkdownParseError: parsed content isn't a valid document — \(reason)"
        }
    }
}

public enum MarkdownParser {
    public static func parse(_ markdown: String, schema: Schema) throws -> Node {
        // A reference can appear before the definition it uses, so definitions
        // are collected — and their lines removed — before anything is parsed.
        let (lines, definitions) = collectDefinitions(
            markdown.components(separatedBy: "\n").map(expandLeadingTabs))
        return try parse(lines: lines, schema: schema, definitions: definitions)
    }

    /// Parse a nested run of lines — a quote's body, a list item's content —
    /// with the definitions collected so far still in scope.
    static func parseNested(_ text: String, schema: Schema,
                            definitions: [String: LinkDefinition]) throws -> Node {
        let (lines, local) = collectDefinitions(
            text.components(separatedBy: "\n").map(expandLeadingTabs))
        // An outer definition wins, matching the first-one-wins rule.
        return try parse(lines: lines, schema: schema,
                         definitions: definitions.merging(local) { outer, _ in outer })
    }

    static func parse(lines: [String], schema: Schema,
                      definitions: [String: LinkDefinition]) throws -> Node {
        var blocks: [Node] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            // Indented code block: four columns of indentation at the start of a
            // block. Checked before everything else because the indentation wins
            // over whatever the line would otherwise look like — "    ***" is
            // code, not a thematic break. (A paragraph can't be interrupted this
            // way: an indented line inside one is gathered as a lazy
            // continuation before ever reaching here.)
            if indentWidth(line) >= 4 {
                var code: [String] = []
                var blanks: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line belongs to the block only if indented
                        // code follows it, so hold it until we know.
                        blanks.append("")
                        i += 1
                        continue
                    }
                    guard indentWidth(l) >= 4 else { break }
                    code.append(contentsOf: blanks)
                    blanks = []
                    code.append(String(l.dropFirst(4)))
                    i += 1
                }
                i -= blanks.count  // trailing blanks are not part of the block
                let text = code.joined(separator: "\n")
                let content = text.isEmpty ? Fragment.empty : Fragment.from([schema.text(text)])
                if let cb = try? schema.node("codeBlock", [:], content: content) { blocks.append(cb) }
                continue
            }

            // Code fence: ``` or ~~~, closed by a run of the same character, so
            // a block fenced with one can contain the other.
            if isOpeningFence(trimmed) {
                let fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                let text = code.joined(separator: "\n")
                let content = text.isEmpty ? Fragment.empty : Fragment.from([schema.text(text)])
                if let cb = try? schema.node("codeBlock", [:], content: content) { blocks.append(cb) }
                continue
            }
            // Figure fence: `^^^` opens a figure that runs to the closing `^^^`,
            // which may carry the caption. Only recognized when the schema has
            // the nodes, so `^^^` stays literal text everywhere else — the same
            // rule the math fences follow.
            if trimmed.hasPrefix("^^^"), schema.nodes["figure"] != nil {
                // Markdig accepts the caption on either fence; prefer the
                // closing one, which is what we write.
                var caption = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("^^^") {
                    body.append(lines[i])
                    i += 1
                }
                if i < lines.count {
                    let closing = lines[i].trimmingCharacters(in: .whitespaces)
                    let trailing = String(closing.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if !trailing.isEmpty { caption = trailing }
                    i += 1  // consume the closing fence
                }
                if let figure = makeFigure(body, caption: caption, schema: schema) {
                    blocks.append(figure)
                }
                continue
            }
            // Display-math fence: `$$` on its own line opens a block formula that
            // runs to the closing `$$`, or `$$…$$` all on one line.
            if trimmed.hasPrefix("$$"), schema.nodes["blockMath"] != nil {
                let rest = String(trimmed.dropFirst(2))
                var latex: String
                if rest.hasSuffix("$$"), rest.count >= 2 {
                    latex = String(rest.dropLast(2)) // one-liner
                    i += 1
                } else {
                    var body: [String] = rest.isEmpty ? [] : [rest]
                    i += 1
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
                        body.append(lines[i]); i += 1
                    }
                    i += 1 // consume the closing fence
                    latex = body.joined(separator: "\n")
                }
                // An empty formula is a valid node — the editor makes one every
                // time a formula is inserted before anything is typed — so an
                // empty fence has to survive the round trip rather than vanish.
                latex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
                if let math = try? schema.node("blockMath", ["latex": .string(latex)]) {
                    blocks.append(math)
                }
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
            // Horizontal rule. Checked before lists: "- - -" and "* * *" are
            // thematic breaks, not one-item lists.
            if isThematicBreak(trimmed) {
                if let hr = try? schema.node("horizontalRule") { blocks.append(hr) }
                i += 1; continue
            }
            // Heading
            if let m = headingMatch(trimmed) {
                let inline = parseInline(m.text, schema, definitions)
                blocks.append(contentsOf: textblockSplittingBlocks(inline) {
                    try? schema.node("heading", ["level": .int(m.level)], content: Fragment.from($0))
                })
                i += 1; continue
            }
            // Blockquote
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                // Whether the previous quoted line was an open paragraph, which
                // is what an unprefixed line is allowed to continue.
                var inParagraph = false
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var l = t
                        l.removeFirst()
                        // One space after ">" is the marker's own padding. A tab
                        // there defines the quoted content's indentation, so
                        // expand it from the column the ">" left us in rather
                        // than dropping it whole.
                        if l.hasPrefix(" ") { l.removeFirst() }
                        else if l.hasPrefix("\t") { l = expandLeadingTabs(" " + l).dropFirst(2).description }
                        quote.append(l)
                        let inner = l.trimmingCharacters(in: .whitespaces)
                        inParagraph = !inner.isEmpty && !startsBlock(inner)
                        i += 1
                        continue
                    }
                    // Lazy continuation: a line without the marker continues a
                    // paragraph inside the quote, but can't start a block there
                    // — "> foo\n- bar" is a quote followed by a list.
                    if inParagraph, !t.isEmpty, !startsBlock(t) {
                        quote.append(t)
                        i += 1
                        continue
                    }
                    break
                }
                let inner = try parseNested(quote.joined(separator: "\n"), schema: schema, definitions: definitions)
                if let bq = try? schema.node("blockquote", [:], content: inner.content) { blocks.append(bq) }
                continue
            }
            // Lists
            if let bullet = bulletMatch(trimmed) {
                let (items, next) = collectList(lines, i, ordered: false)
                if let list = makeTaskList(items, schema: schema)
                    ?? makeList(items, ordered: false, schema: schema) { blocks.append(list) }
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
            // The first line keeps its trailing spaces for the same reason the
            // continuation lines below do: two of them are a hard break.
            var para: [String] = [String(lines[i].drop(while: { $0 == " " || $0 == "\t" }))]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || startsBlock(t) { break }
                // Only the leading whitespace is dropped: two or more spaces at
                // the end of a line are a hard break, so they have to survive to
                // the inline parser.
                para.append(String(lines[i].drop(while: { $0 == " " || $0 == "\t" })))
                i += 1
            }
            // Keep line breaks so the inline parser can turn a trailing `\` into a
            // hard break and collapse other soft wraps into spaces.
            let inline = parseInline(para.joined(separator: "\n"), schema, definitions)
            // A setext underline turns the paragraph just gathered into a
            // heading. This is why "---" under a paragraph is a heading and a
            // thematic break anywhere else: the paragraph branch gets there
            // first, and the block loop only sees a "---" that starts a block.
            if i < lines.count, let level = setextUnderline(lines[i]) {
                i += 1
                blocks.append(contentsOf: textblockSplittingBlocks(inline) {
                    try? schema.node("heading", ["level": .int(level)], content: Fragment.from($0))
                })
                continue
            }
            // `![alt](src)` reads as inline content, but an image is block-level
            // in the default schema — so it becomes its own block rather than an
            // invalid child of the paragraph.
            blocks.append(contentsOf: textblockSplittingBlocks(inline) {
                try? schema.node("paragraph", [:], content: Fragment.from($0))
            })
        }
        // Markdown's shapes don't always fit the schema: `![alt](src)` parses as
        // inline content, but an image is block-level in the default schema, so
        // the paragraph built around it would be invalid. Fit the blocks the
        // same way the HTML parser does rather than returning something the
        // editor can't use.
        var fitted = fitContent(blocks, into: schema.topNodeType, schema: schema)
        if fitted.isEmpty, let p = schema.nodes["paragraph"]?.createAndFill() { fitted = [p] }
        let doc = try schema.node("doc", [:], content: Fragment.from(fitted))
        // `create` computes attributes but doesn't check content, so without
        // this an invalid document would be returned silently.
        do {
            try doc.check()
        } catch {
            throw MarkdownParseError.invalidDocument(String(describing: error))
        }
        return doc
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
        let parsedSummary = parseInline(summaryText, schema)
        // A summary holds inline content only, so anything block-level in it —
        // `<summary>![pic](a.jpg)</summary>` in the default schema — moves to
        // the top of the body rather than making the summary invalid.
        let summaryInline = parsedSummary.filter { !$0.type.isBlock }
        let liftedFromSummary = parsedSummary.filter { $0.type.isBlock }
        guard let detailsType = schema.nodes["details"],
              let summaryType = schema.nodes["detailsSummary"],
              let contentType = schema.nodes["detailsContent"] else {
            var out: [Node] = []
            if !summaryInline.isEmpty, let para = try? schema.node("paragraph", [:], content: Fragment.from(summaryInline)) {
                out.append(para)
            }
            return out + liftedFromSummary + (0..<bodyDoc.childCount).map { bodyDoc.child($0) }
        }
        let bodyBlocks = liftedFromSummary + (0..<bodyDoc.childCount).map { bodyDoc.child($0) }
        guard let summary = (try? summaryType.create([:], content: Fragment.from(summaryInline))) ?? summaryType.createAndFill(),
              let content = (try? contentType.create([:], content: Fragment.from(fitContent(bodyBlocks, into: contentType, schema: schema))))
                ?? contentType.createAndFill(),
              let node = try? detailsType.create(["open": .bool(open)], content: Fragment.from([summary, content]))
        else { return nil }
        return [node]
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for c in line { if c == "#" { level += 1 } else { break } }
        let afterRun = line.count > level ? Array(line)[level] : nil
        guard level >= 1, level <= 6, afterRun == " " || afterRun == "\t" else { return nil }
        var text = String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
        // An optional closing run of "#" is decoration, not content — but only
        // when it's a run on its own, so "# foo #bar" keeps its hash.
        if text.hasSuffix("#") {
            let withoutRun = String(text.reversed().drop(while: { $0 == "#" }).reversed())
            if withoutRun.isEmpty || withoutRun.hasSuffix(" ") {
                text = withoutRun.trimmingCharacters(in: .whitespaces)
            }
        }
        return (level, text)
    }

    /// How many columns a line is indented by. Lines are tab-expanded first, so
    /// this is a plain count of leading spaces.
    static func indentWidth(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// Expand a line's *leading* tabs to spaces on four-column stops.
    ///
    /// CommonMark doesn't expand tabs in content — "tabs in lines are not
    /// expanded to spaces" — but "in contexts where spaces help define block
    /// structure, tabs behave as if they were replaced by spaces with a tab stop
    /// of 4 characters". Indentation is exactly such a context, so the leading
    /// run is expanded and a tab inside the text is left as the author typed it.
    static func expandLeadingTabs(_ line: String) -> String {
        guard let first = line.first, first == " " || first == "\t" else { return line }
        var column = 0
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == " " { column += 1 }
            else if line[i] == "\t" { column += 4 - (column % 4) }
            else { break }
            i = line.index(after: i)
        }
        return String(repeating: " ", count: column) + line[i...]
    }

    /// Whether a line opens a fenced code block.
    ///
    /// A backtick fence's info string may not itself contain a backtick — which
    /// is what keeps a line like ``` `` ``` ``` (an inline code span holding a
    /// backtick, written with a longer fence) from being read as a code block.
    private static func isOpeningFence(_ line: String) -> Bool {
        if line.hasPrefix("~~~") { return true }
        guard line.hasPrefix("```") else { return false }
        return !line.drop(while: { $0 == "`" }).contains("`")
    }

    /// A link's destination and title, defined once and referred to by label.
    struct LinkDefinition {
        let destination: String
        let title: String?
    }

    /// Definitions are matched by label case-insensitively, with surrounding and
    /// internal whitespace normalized, so `[Foo  bar]` and `[foo bar]` are one.
    static func normalizeLabel(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// Pull `[label]: destination "title"` lines out of the document, returning
    /// the remaining lines and the definitions found.
    ///
    /// This has to happen before anything else is parsed, because a reference may
    /// appear before the definition it uses. Definitions inside a fenced or
    /// indented code block are content, not definitions, so those regions are
    /// skipped.
    static func collectDefinitions(_ lines: [String]) -> ([String], [String: LinkDefinition]) {
        var remaining: [String] = []
        var definitions: [String: LinkDefinition] = [:]
        var fence: String?
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                remaining.append(line); i += 1; continue
            }
            if isOpeningFence(trimmed) {
                fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                remaining.append(line); i += 1; continue
            }
            // Four columns in is code, not a definition.
            guard indentWidth(line) < 4, let (label, rest) = parseDefinitionHead(line) else {
                remaining.append(line); i += 1; continue
            }
            var body = rest
            var consumed = 1
            // A title may sit on the line below the destination.
            if body.isEmpty {
                remaining.append(line); i += 1; continue
            }
            if titleOnly(body) == nil, i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if splitDestinationAndTitle(body).1 == nil, titleOnly(next) != nil {
                    body += " " + next
                    consumed = 2
                }
            }
            let (destination, title) = splitDestinationAndTitle(body)
            guard !destination.isEmpty else { remaining.append(line); i += 1; continue }
            let key = normalizeLabel(label)
            // The first definition of a label wins, as in CommonMark.
            if definitions[key] == nil {
                definitions[key] = LinkDefinition(destination: destination, title: title)
            }
            i += consumed
        }
        return (remaining, definitions)
    }

    /// `[label]:` at the head of a line, returning the label and what follows.
    private static func parseDefinitionHead(_ line: String) -> (label: String, rest: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[") else { return nil }
        let bytes = Array(t.utf8)
        guard let close = findUnescaped(bytes, 1, UInt8(ascii: "]")), close > 1,
              close + 1 < bytes.count, bytes[close + 1] == UInt8(ascii: ":") else { return nil }
        let label = slice(bytes, 1..<close)
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (label, slice(bytes, (close + 2)..<bytes.count)
            .trimmingCharacters(in: .whitespaces))
    }

    /// The contents of a line that is nothing but a quoted title.
    private static func titleOnly(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for (open, close) in [("\"", "\""), ("'", "'"), ("(", ")")]
        where t.hasPrefix(open) && t.hasSuffix(close) && t.count >= 2 {
            return String(t.dropFirst().dropLast())
        }
        return nil
    }

    /// Whether a line begins a block of its own, rather than continuing the
    /// paragraph above it. Shared by the paragraph gather and by a blockquote's
    /// lazy continuation, so the two always agree on where a paragraph ends.
    private static func startsBlock(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || isOpeningFence(trimmed)
            || trimmed.hasPrefix("$$") || isThematicBreak(trimmed)
            || setextUnderline(trimmed) != nil
            || bulletMatch(trimmed) != nil || orderedMatch(trimmed) != nil
            || trimmed.lowercased().hasPrefix("<details")
            || trimmed.lowercased().hasPrefix("</details>")
    }

    /// A setext heading's underline: a run of `=` (level 1) or `-` (level 2),
    /// indented no more than three columns. Any length counts, so "Foo\n--" is
    /// a heading. Only meaningful directly under a paragraph — the caller checks
    /// that, which is also what makes "---" a heading there and a thematic break
    /// anywhere else.
    private static func setextUnderline(_ line: String) -> Int? {
        guard indentWidth(line) <= 3 else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let first = t.first, first == "=" || first == "-",
              t.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    /// A thematic break: three or more of `-`, `*` or `_`, optionally separated
    /// by spaces (`***`, `___`, `* * *`, `- - -`).
    private static func isThematicBreak(_ line: String) -> Bool {
        var char: Character?
        var count = 0
        for c in line {
            if c == " " || c == "\t" { continue }
            guard c == "-" || c == "*" || c == "_" else { return false }
            if let char, c != char { return false }
            char = c
            count += 1
        }
        return count >= 3
    }

    private static func bulletMatch(_ line: String) -> String? {
        // A tab after the marker separates it from the content, as a space does.
        for marker in ["-", "*", "+"] where line.hasPrefix(marker) {
            let rest = line.dropFirst()
            guard let next = rest.first, next == " " || next == "\t" else { continue }
            return expandLeadingTabs(String(rest.dropFirst()))
        }
        return nil
    }

    private static func orderedMatch(_ line: String) -> Int? {
        var digits = ""
        for c in line { if c.isNumber { digits.append(c) } else { break } }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(".\t") else { return nil }
        return Int(digits)
    }

    /// Gather a list's items, each as its own lines. An item owns the lines
    /// below it that are indented to its content column — CommonMark's "W + N"
    /// rule — so a formula or code fence written under a bullet stays part of
    /// that bullet instead of ending the list.
    private static func collectList(_ lines: [String], _ start: Int, ordered: Bool) -> (items: [[String]], next: Int) {
        var items: [[String]] = []
        var indents: [Int] = []
        var i = start
        func isItem(_ t: String) -> Bool { ordered ? orderedMatch(t) != nil : bulletMatch(t) != nil }
        func continues(_ line: String) -> Bool {
            guard let indent = indents.last,
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            return indentWidth(line) >= indent
        }
        while i < lines.count {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                // A blank line continues the list when another item follows, or
                // when the next line is still indented inside the current item
                // (a loose item holding more than one block).
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.count else { break }
                if continues(lines[j]) {
                    items[items.count - 1].append("")
                    i = j
                    continue
                }
                if isItem(lines[j].trimmingCharacters(in: .whitespaces)) { i = j; continue }
                break
            }
            // Checked before the marker test: a line indented to the current
            // item's content column is that item's content even when it looks
            // like a marker itself, which is how a nested list is written.
            if continues(raw) {
                items[items.count - 1].append(String(raw.dropFirst(indents[indents.count - 1])))
                i += 1
                continue
            }
            if isItem(t) {
                let markerWidth: Int
                if ordered {
                    let digits = t.prefix(while: { $0.isNumber }).count
                    items.append([String(t.drop(while: { $0.isNumber }).dropFirst(2))])
                    markerWidth = digits + 2
                } else {
                    items.append([bulletMatch(t) ?? ""])
                    markerWidth = 2
                }
                // The content column is where the text after the marker starts,
                // so an item that is itself indented carries that indent.
                indents.append(indentWidth(raw) + markerWidth)
                i += 1
                continue
            }
            break
        }
        return (items, i)
    }

    /// Build a `figure` from a fence's body lines and caption. Returns nil if the
    /// schema can't hold one, so the caller leaves the text alone.
    private static func makeFigure(_ body: [String], caption: String, schema: Schema) -> Node? {
        guard let figureType = schema.nodes["figure"] else { return nil }
        let inner = (try? parse(body.joined(separator: "\n"), schema: schema))?.content
        var children = inner.map { frag in (0..<frag.childCount).map { frag.child($0) } } ?? []
        if !caption.isEmpty, let captionType = schema.nodes["figcaption"],
           let node = try? captionType.create([:], content: Fragment.from(parseInline(caption, schema))) {
            children.append(node)
        }
        let fitted = fitContent(children, into: figureType, schema: schema)
        if let figure = try? figureType.create([:], content: Fragment.from(fitted)) { return figure }
        return figureType.createAndFill([:], content: Fragment.from(fitted))
    }

    /// A checkbox at the head of a list item, as GitHub writes them. Returns the
    /// checked state and the rest of the line.
    private static func taskMarker(_ line: String) -> (checked: Bool, rest: String)? {
        let boxes: [(String, Bool)] = [("[ ] ", false), ("[x] ", true), ("[X] ", true),
                                       ("[ ]", false), ("[x]", true), ("[X]", true)]
        for (box, checked) in boxes where line.hasPrefix(box) {
            return (checked, String(line.dropFirst(box.count)))
        }
        return nil
    }

    /// Build a `taskList` when every item carries a checkbox and the schema has
    /// the nodes; otherwise nil, so the caller falls back to a plain list and the
    /// brackets stay literal text.
    private static func makeTaskList(_ items: [[String]], schema: Schema) -> Node? {
        guard let listType = schema.nodes["taskList"], let itemType = schema.nodes["taskItem"],
              !items.isEmpty, items.allSatisfy({ taskMarker($0.first ?? "") != nil }) else { return nil }
        var itemNodes: [Node] = []
        for var lines in items {
            guard let marker = taskMarker(lines[0]) else { return nil }
            lines[0] = marker.rest
            let content = fitContent(itemBlocks(lines, schema: schema), into: itemType, schema: schema)
            guard let item = try? itemType.create(["checked": .bool(marker.checked)],
                                                  content: Fragment.from(content)) else { return nil }
            itemNodes.append(item)
        }
        return try? listType.create([:], content: Fragment.from(itemNodes))
    }

    /// The blocks of one list item. An item that carried continuation lines is
    /// parsed as a document, the way a blockquote's contents are.
    private static func itemBlocks(_ lines: [String], schema: Schema) -> [Node] {
        if lines.count > 1 {
            let inner = (try? parse(lines.joined(separator: "\n"), schema: schema))?.content
            return inner.map { frag in (0..<frag.childCount).map { frag.child($0) } } ?? []
        }
        let inline = parseInline(lines[0], schema)
        return textblockSplittingBlocks(inline) {
            try? schema.node("paragraph", [:], content: Fragment.from($0))
        }
    }

    private static func makeList(_ items: [[String]], ordered: Bool, schema: Schema, start: Int = 1) -> Node? {
        guard let itemType = schema.nodes["listItem"] else { return nil }
        var itemNodes: [Node] = []
        for lines in items {
            if lines.count > 1 {
                let content = fitContent(itemBlocks(lines, schema: schema), into: itemType, schema: schema)
                if let item = try? itemType.create([:], content: Fragment.from(content)) {
                    itemNodes.append(item)
                }
                continue
            }
            let inline = parseInline(lines[0], schema)
            // A list item holds blocks, so a block-level image in its text
            // becomes a sibling block rather than an invalid child of the
            // paragraph. `fitContent` then puts the item's content in order.
            let blocks = textblockSplittingBlocks(inline) {
                try? schema.node("paragraph", [:], content: Fragment.from($0))
            }
            let content = fitContent(blocks, into: itemType, schema: schema)
            guard let item = try? itemType.create([:], content: Fragment.from(content)) else { continue }
            itemNodes.append(item)
        }
        let listName = ordered ? "orderedList" : "bulletList"
        let attrs: Attrs = ordered ? ["order": .int(start)] : [:]
        return try? schema.node(listName, attrs, content: Fragment.from(itemNodes))
    }

    // Inline parser: handles **bold**, *italic*/_italic_, `code`, ~~strike~~,
    // ==highlight==, [text](url), ![alt](src), and [[wiki|link]].
    static func parseInline(_ text: String, _ schema: Schema,
                            _ definitions: [String: LinkDefinition] = [:]) -> [Node] {
        // Everything except emphasis is resolved as the text is scanned. Runs of
        // "*" and "_" are set aside as delimiters and paired afterwards, because
        // which of them open and which close can't be known until the whole line
        // has been seen.
        enum Piece {
            case node(Node)
            case delimiter(Int)  // index into `delimiters`
        }
        var pieces: [Piece] = []
        var delimiters: [Delimiter] = []
        // UTF-8 bytes, not characters: every delimiter this scanner branches on
        // is ASCII, and no byte of a multi-byte character is ASCII, so the two
        // agree on where everything starts and ends. Comparing bytes is an
        // integer compare rather than a string compare, and pulling a range out
        // is a copy rather than a per-character append.
        let chars = Array(text.utf8)
        var i = 0
        var buffer: [UInt8] = []
        func flush(_ marks: [Mark] = []) {
            // Character references are text, not markup: "&amp;" is an ampersand.
            // The HTML parser already knows every named, decimal and hex form, so
            // reuse it rather than growing a second table. Code spans flush their
            // own literal text and never come through here.
            if !buffer.isEmpty {
                pieces.append(.node(schema.text(String(decoding: buffer, as: UTF8.self), marks)))
                buffer = []
            }
        }
        func appendNode(_ node: Node) { pieces.append(.node(node)) }
        func mark(_ name: String, _ attrs: Attrs = [:]) -> [Mark] {
            schema.marks[name].map { [$0.create(attrs)] } ?? []
        }
        let asciiPunct = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".utf8)
        while i < chars.count {
            let c = chars[i]
            // Backslash: a hard break before a newline, otherwise an escape that
            // emits the next punctuation character literally.
            if c == UInt8(ascii: "\\"), i + 1 < chars.count {
                let next = chars[i + 1]
                if next == UInt8(ascii: "\n") {
                    flush()
                    if let br = try? schema.nodes["hardBreak"]?.create() { appendNode(br) }
                    i += 2; continue
                }
                if asciiPunct.contains(next) { buffer.append(next); i += 2; continue }
            }
            // A line break: two or more spaces before it make it hard (the form
            // most editors emit), otherwise it is a soft wrap and reads as one
            // space. Either way the trailing spaces themselves are not content.
            if c == UInt8(ascii: "\n") {
                var spaces = 0
                while buffer.last == UInt8(ascii: " ") { buffer.removeLast(); spaces += 1 }
                if spaces >= 2 {
                    flush()
                    if let br = try? schema.nodes["hardBreak"]?.create() { appendNode(br) }
                } else {
                    buffer.append(UInt8(ascii: " "))
                }
                i += 1; continue
            }
            // A character reference is text: "&amp;" is an ampersand. Decoded
            // here rather than over the finished buffer so that an escaped "\&"
            // — already resolved to a literal "&" — isn't decoded a second time.
            if c == UInt8(ascii: "&"), let semi = findByte(chars, i + 1, UInt8(ascii: ";")), semi - i <= 32 {
                let reference = slice(chars, i..<(semi + 1))
                let decoded = HTMLParser.decodeEntities(reference)
                // "&#10;" is a newline, which is block structure in this model,
                // not text — decoding it would produce a document we can't write
                // back. Leave those references as written.
                if decoded != reference, !decoded.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                    buffer += Array(decoded.utf8)
                    i = semi + 1; continue
                }
            }
            // Autolink <scheme:...> — a bare URL in angle brackets.
            if c == UInt8(ascii: "<"), let close = findByte(chars, i + 1, UInt8(ascii: ">")),
               case let url = slice(chars, (i + 1)..<close), isAutolink(url),
               let href = sanitizeURL(url, for: .link) {
                flush()
                appendNode(schema.text(url, mark("link", ["href": .string(href)])))
                i = close + 1; continue
            }
            // Wiki link [[...]]
            if c == UInt8(ascii: "[") && i + 1 < chars.count && chars[i + 1] == UInt8(ascii: "[") {
                if let close = findSeq(chars, i + 2, Array("]]".utf8)) {
                    flush()
                    let inner = slice(chars, (i + 2)..<close)
                    let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
                    var attrs: Attrs = ["target": .string(parts[0])]
                    if parts.count > 1 { attrs["label"] = .string(parts[1]) }
                    if let wl = try? schema.nodes["wikiLink"]?.create(attrs) { appendNode(wl) }
                    i = close + 2
                    continue
                }
            }
            // Image by reference: ![alt][label], ![alt][] or ![alt]. The inline
            // form takes precedence, and it is checked for below, so this only
            // runs when the brackets aren't followed by a destination.
            if c == UInt8(ascii: "!") && i + 1 < chars.count && chars[i + 1] == UInt8(ascii: "["),
               !definitions.isEmpty, parseLinkLike(chars, i + 1) == nil,
               let (alt, definition, next) = parseReference(chars, i + 1, definitions) {
                flush()
                var attrs: Attrs = ["src": .null, "alt": .string(unescapeInline(alt))]
                if let title = definition.title { attrs["title"] = .string(title) }
                if let src = sanitizeURL(definition.destination, for: .image),
                   let type = schema.nodes["image"] {
                    attrs["src"] = .string(src)
                    if let img = try? type.create(attrs) { appendNode(img) }
                }
                i = next; continue
            }
            // Image ![alt](src)
            if c == UInt8(ascii: "!") && i + 1 < chars.count && chars[i + 1] == UInt8(ascii: "[") {
                if let (alt, url, title, next) = parseLinkLike(chars, i + 1) {
                    flush()
                    var attrs: Attrs = ["src": .null, "alt": .string(unescapeInline(alt))]
                    if let title { attrs["title"] = .string(title) }
                    if let src = sanitizeURL(url, for: .image), let type = schema.nodes["image"] {
                        attrs["src"] = .string(src)
                        if let img = try? type.create(attrs) { appendNode(img) }
                    }
                    i = next; continue
                }
            }
            // Link [text](url)
            if c == UInt8(ascii: "[") {
                if let (label, url, title, next) = parseLinkLike(chars, i) {
                    flush()
                    // Markdown reaches the editor from the same untrusted places
                    // HTML does, so `[x](javascript:…)` gets the same treatment:
                    // the link is dropped, the text kept.
                    let text = unescapeInline(label)
                    if let href = sanitizeURL(url, for: .link) {
                        var attrs: Attrs = ["href": .string(href)]
                        if let title { attrs["title"] = .string(title) }
                        appendNode(schema.text(text, mark("link", attrs)))
                    } else if !text.isEmpty {
                        appendNode(schema.text(text))
                    }
                    i = next; continue
                }
            }
            // Link by reference: [text][label], [label][] or [label]. Tried
            // after the inline form, which takes precedence.
            if c == UInt8(ascii: "["), let (label, definition, next) = parseReference(chars, i, definitions) {
                flush()
                let linkText = unescapeInline(label)
                if let href = sanitizeURL(definition.destination, for: .link) {
                    var attrs: Attrs = ["href": .string(href)]
                    if let title = definition.title { attrs["title"] = .string(title) }
                    appendNode(schema.text(linkText, mark("link", attrs)))
                } else if !linkText.isEmpty {
                    appendNode(schema.text(linkText))
                }
                i = next; continue
            }
            // Emphasis: a run of "*" or "_" is set aside for pairing later. A
            // run that can neither open nor close is just text.
            if c == UInt8(ascii: "*") || c == UInt8(ascii: "_") {
                let run = runLength(chars, i, c)
                let sides = flanking(chars, i, i + run)
                if sides.canOpen || sides.canClose {
                    flush()
                    delimiters.append(Delimiter(char: c, count: run, original: run,
                                                canOpen: sides.canOpen, canClose: sides.canClose))
                    pieces.append(.delimiter(delimiters.count - 1))
                } else {
                    buffer += Array(repeating: c, count: run)
                }
                i += run
                continue
            }
            // Strike ~~ ~~
            if c == UInt8(ascii: "~") && i + 1 < chars.count && chars[i + 1] == UInt8(ascii: "~") {
                if let close = findSeq(chars, i + 2, Array("~~".utf8)), close > i + 2 {
                    flush()
                    appendNode(schema.text(unescapeInline(slice(chars, (i + 2)..<close)), mark("strike")))
                    i = close + 2; continue
                }
            }
            // Highlight == ==
            // A run of "=" is a setext heading underline or a divider far more
            // often than it is an empty highlight, so require content.
            if c == UInt8(ascii: "=") && i + 1 < chars.count && chars[i + 1] == UInt8(ascii: "=") {
                if let close = findSeq(chars, i + 2, Array("==".utf8)), close > i + 2 {
                    flush()
                    appendNode(schema.text(unescapeInline(slice(chars, (i + 2)..<close)), mark("highlight")))
                    i = close + 2; continue
                }
            }
            // Inline math $ $ — only when the schema has the node, so a lone `$`
            // (or a price like "$5 and $6") stays literal text elsewhere.
            if c == UInt8(ascii: "$"), let type = schema.nodes["inlineMath"],
               i + 1 < chars.count, chars[i + 1] != UInt8(ascii: "$"),
               !(scalarAt(i + 1, chars).map(isUnicodeWhitespace) ?? true),
               let close = findMathClose(chars, i + 1),
               let math = try? type.create(["latex": .string(slice(chars, (i + 1)..<close))]) {
                flush()
                appendNode(math)
                i = close + 1; continue
            }
            // Code span: a run of N backticks closes on the next run of exactly
            // N, which is how a span holds a backtick of its own. Contents are
            // literal — no escapes — but line endings read as spaces, and one
            // space of padding at each end is dropped (it exists so a span can
            // start or end with a backtick).
            if c == UInt8(ascii: "`") {
                let run = runLength(chars, i, UInt8(ascii: "`"))
                if let close = findBacktickRun(chars, i + run, run) {
                    var content = slice(chars, (i + run)..<close)
                        .replacingOccurrences(of: "\n", with: " ")
                    if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
                       content.contains(where: { $0 != " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    if !content.isEmpty {
                        flush()
                        appendNode(schema.text(content, mark("code")))
                        i = close + run; continue
                    }
                }
            }
            buffer.append(c)
            i += 1
        }
        // Trailing spaces at the very end are not content (two before a newline
        // were already consumed as a hard break above).
        while buffer.last == UInt8(ascii: " ") { buffer.removeLast() }
        flush()

        // Pair the delimiters, then hand every piece the marks of the pairs that
        // enclose it. Marks nest by set membership here rather than by wrapping,
        // so `***foo***` is one text node carrying both.
        let positions = pieces.indices.compactMap { index -> Int? in
            if case .delimiter = pieces[index] { return index }
            return nil
        }
        let pairs = processEmphasis(&delimiters, positions)
        // How many pairs of each kind cover each piece. Counting over the pairs'
        // ranges once beats asking, for every piece, which pairs enclose it —
        // and the two marks are built once rather than per piece.
        var strongDepth = [Int](repeating: 0, count: pieces.count)
        var emphasisDepth = [Int](repeating: 0, count: pieces.count)
        for pair in pairs {
            let range = (positions[pair.open] + 1)..<positions[pair.close]
            for index in range {
                if pair.strong { strongDepth[index] += 1 } else { emphasisDepth[index] += 1 }
            }
        }
        let boldMark = mark("bold"), italicMark = mark("italic")
        var result: [Node] = []
        for (index, piece) in pieces.enumerated() {
            var marks: [Mark] = []
            if strongDepth[index] > 0 { for m in boldMark { marks = m.addToSet(marks) } }
            if emphasisDepth[index] > 0 { for m in italicMark { marks = m.addToSet(marks) } }
            switch piece {
            case let .node(node):
                result.append(marks.isEmpty ? node : node.mark(marks.reduce(node.marks) { $1.addToSet($0) }))
            case let .delimiter(d):
                // Whatever the pairing didn't use is literal text.
                let leftover = delimiters[d].count
                if leftover > 0 {
                    let character = Character(UnicodeScalar(delimiters[d].char))
                    result.append(schema.text(String(repeating: character, count: leftover), marks))
                }
            }
        }
        return mergeAdjacentText(result, schema)
    }

    /// Emphasis leaves runs of text that carry the same marks side by side —
    /// `Fragment.from` merges those, but the callers that build textblocks want
    /// them merged before schema fitting sees them.
    private static func mergeAdjacentText(_ nodes: [Node], _ schema: Schema) -> [Node] {
        var merged: [Node] = []
        for node in nodes {
            if let last = merged.last, last.isText, node.isText,
               Mark.sameSet(last.marks, node.marks) {
                merged[merged.count - 1] = schema.text((last.text ?? "") + (node.text ?? ""), last.marks)
            } else {
                merged.append(node)
            }
        }
        return merged
    }

    /// An autolink's contents: a scheme, then anything but spaces or angles.
    /// Bare `<tag>` markup and `<a@b.c>` addresses are deliberately not matched.
    private static func isAutolink(_ s: String) -> Bool {
        guard let colon = s.firstIndex(of: ":"), colon != s.startIndex else { return false }
        let scheme = s[s.startIndex..<colon]
        guard scheme.first?.isLetter == true,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" })
        else { return false }
        let rest = s[s.index(after: colon)...]
        return !rest.isEmpty && !rest.contains(where: { $0 == " " || $0 == "<" || $0 == ">" || $0 == "\n" })
    }

    /// A `String` from a range of the byte buffer. Ranges only ever start and end
    /// on ASCII delimiters, so they never split a multi-byte character, and this
    /// is a copy of the bytes rather than a per-character append.
    private static func slice(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    private static func parseLinkLike(_ bytes: [UInt8], _ start: Int)
        -> (text: String, url: String, title: String?, next: Int)? {
        guard bytes[start] == UInt8(ascii: "[") else { return nil }
        guard let closeBracket = findUnescaped(bytes, start + 1, UInt8(ascii: "]")) else { return nil }
        guard closeBracket + 1 < bytes.count,
              bytes[closeBracket + 1] == UInt8(ascii: "(") else { return nil }
        guard let closeParen = findLinkClose(bytes, closeBracket + 2) else { return nil }
        let label = slice(bytes, (start + 1)..<closeBracket)
        let (url, title) = splitDestinationAndTitle(slice(bytes, (closeBracket + 2)..<closeParen))
        return (label, url, title, closeParen + 1)
    }

    /// One run of `*` or `_`, as the emphasis algorithm sees it.
    struct Delimiter {
        let char: UInt8
        /// How many characters of the run are still unused.
        var count: Int
        /// The run's full length, which the rule of three is stated in terms of.
        let original: Int
        let canOpen: Bool
        let canClose: Bool
    }

    /// A resolved pair of delimiters and what it wraps, as indices into the
    /// piece list.
    struct EmphasisPair {
        let open: Int
        let close: Int
        let strong: Bool
    }

    /// CommonMark's "process emphasis": walk the delimiter runs left to right and
    /// match each closer with the nearest opener that can pair with it.
    ///
    /// Pair matching alone can't express `***foo***` or `*foo **bar** baz*` —
    /// the first needs one run to supply two different pairs, and the second
    /// needs an inner pair to be matched before the outer one can close past it.
    /// Working from the closers, and dropping any delimiters left stranded
    /// between a matched pair, is what gets both right.
    static func processEmphasis(_ delimiters: inout [Delimiter],
                                _ positions: [Int]) -> [EmphasisPair] {
        var pairs: [EmphasisPair] = []
        // Delimiters still available to match, as indices into `delimiters`.
        var stack = Array(positions.indices)
        var closerAt = 0
        while closerAt < stack.count {
            let closer = stack[closerAt]
            guard delimiters[closer].canClose, delimiters[closer].count > 0 else {
                closerAt += 1
                continue
            }
            // The nearest opener of the same character that may pair with it.
            var openerAt: Int?
            var scan = closerAt - 1
            while scan >= 0 {
                let opener = stack[scan]
                if delimiters[opener].char == delimiters[closer].char,
                   delimiters[opener].canOpen, delimiters[opener].count > 0,
                   canPair(delimiters[opener], delimiters[closer]) {
                    openerAt = scan
                    break
                }
                scan -= 1
            }
            guard let openerAt else {
                // A closer that can't also open is spent; anything else may
                // still serve as an opener for a later closer.
                if !delimiters[closer].canOpen { stack.remove(at: closerAt) } else { closerAt += 1 }
                continue
            }
            let opener = stack[openerAt]
            // Two characters make it strong when both runs can spare them.
            let strong = delimiters[opener].count >= 2 && delimiters[closer].count >= 2
            let used = strong ? 2 : 1
            pairs.append(EmphasisPair(open: opener, close: closer, strong: strong))
            delimiters[opener].count -= used
            delimiters[closer].count -= used
            // Delimiters caught between the pair can never match anything now.
            if closerAt > openerAt + 1 {
                stack.removeSubrange((openerAt + 1)..<closerAt)
                closerAt = openerAt + 1
            }
            if delimiters[closer].count == 0 { stack.remove(at: closerAt) }
            if delimiters[opener].count == 0 {
                stack.remove(at: openerAt)
                closerAt -= 1
            }
        }
        return pairs
    }

    /// The "rule of three": when either run can both open and close, their
    /// lengths may not sum to a multiple of three unless both are multiples of
    /// three. It exists to keep `*foo**bar**baz*` from pairing across the middle.
    private static func canPair(_ opener: Delimiter, _ closer: Delimiter) -> Bool {
        let eitherIsBoth = (opener.canOpen && opener.canClose) || (closer.canOpen && closer.canClose)
        guard eitherIsBoth, (opener.original + closer.original) % 3 == 0 else { return true }
        return opener.original % 3 == 0 && closer.original % 3 == 0
    }

    /// A reference link or image: `[text][label]`, `[label][]` or `[label]`.
    ///
    /// Returns the text to display, the definition it resolves to, and where to
    /// continue. Nil when the brackets don't name a definition, so unmatched
    /// brackets stay literal text — which is what keeps prose like "see [1]"
    /// intact.
    private static func parseReference(_ bytes: [UInt8], _ start: Int,
                                       _ definitions: [String: LinkDefinition])
        -> (text: String, definition: LinkDefinition, next: Int)? {
        guard !definitions.isEmpty, bytes[start] == UInt8(ascii: "[") else { return nil }
        guard let closeBracket = findUnescaped(bytes, start + 1, UInt8(ascii: "]")) else { return nil }
        let first = slice(bytes, (start + 1)..<closeBracket)
        var label = first
        var next = closeBracket + 1
        // A second bracket pair makes it a full or collapsed reference.
        if closeBracket + 1 < bytes.count, bytes[closeBracket + 1] == UInt8(ascii: "[") {
            guard let closeSecond = findUnescaped(bytes, closeBracket + 2,
                                                  UInt8(ascii: "]")) else { return nil }
            let second = slice(bytes, (closeBracket + 2)..<closeSecond)
            // `[text][]` is collapsed: the text is its own label.
            label = second.trimmingCharacters(in: .whitespaces).isEmpty ? first : second
            next = closeSecond + 1
        }
        guard let definition = definitions[normalizeLabel(label)] else { return nil }
        return (first, definition, next)
    }

    /// The `)` that closes a link, skipping the parts that may contain one:
    /// an angle-bracketed destination, a quoted title, and balanced parentheses
    /// (which is also the `(title)` spelling).
    private static func findLinkClose(_ bytes: [UInt8], _ from: Int) -> Int? {
        var i = from
        var depth = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\\") { i += 2; continue }
            if b == UInt8(ascii: "<"),
               let close = findUnescaped(bytes, i + 1, UInt8(ascii: ">")) { i = close + 1; continue }
            if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'"),
               let close = findUnescaped(bytes, i + 1, b) { i = close + 1; continue }
            if b == UInt8(ascii: "(") { depth += 1; i += 1; continue }
            if b == UInt8(ascii: ")") {
                if depth == 0 { return i }
                depth -= 1
                i += 1
                continue
            }
            i += 1
        }
        return nil
    }

    /// Split a destination from an optional title. Shared by inline links and by
    /// reference definitions, which spell this part the same way.
    static func splitDestinationAndTitle(_ s: String) -> (String, String?) {
        var url = s
        var title: String?
        // An angle-bracketed destination ends at its ">", so anything after it
        // is the title with no whitespace required between them.
        let head = s.trimmingCharacters(in: .whitespaces)
        if head.hasPrefix("<"), let close = head.firstIndex(of: ">") {
            let rest = String(head[head.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            let destination = String(head[head.index(after: head.startIndex)..<close])
            return (destination, rest.isEmpty ? nil : titleOnly(rest))
        }
        // The title is quoted with "", '' or (). Split on the whitespace before
        // the quote, so a destination that itself contains one isn't cut in half.
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        for (open, close) in [("\"", "\""), ("'", "'"), ("(", ")")] where trimmed.hasSuffix(close) {
            if let openIndex = trimmed.dropLast().lastIndex(of: Character(open)),
               openIndex > trimmed.startIndex,
               trimmed[trimmed.index(before: openIndex)] == " " {
                title = String(trimmed[trimmed.index(after: openIndex)..<trimmed.index(before: trimmed.endIndex)])
                url = String(trimmed[trimmed.startIndex..<openIndex]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // A destination may be wrapped in angle brackets to allow spaces.
        let bare = url.trimmingCharacters(in: .whitespaces)
        if bare.hasPrefix("<"), bare.hasSuffix(">"), !bare.dropFirst().dropLast().contains("\n") {
            url = String(bare.dropFirst().dropLast())
        }
        return (url.trimmingCharacters(in: .whitespaces), title)
    }

    /// The closing `$` of inline math, following Pandoc's `tex_math_dollars`:
    /// the next unescaped `$` with a non-space immediately to its left and no
    /// digit immediately to its right. Those two conditions are what stop
    /// "costs $5 and $6" from pairing its dollars into a formula. Returns nil at
    /// end of line — inline math never spans lines.
    /// Whether a run of `*` or `_` can open and/or close emphasis, by
    /// CommonMark's delimiter-run rules.
    ///
    /// A run is *left-flanking* when it isn't followed by whitespace, and either
    /// isn't followed by punctuation or is preceded by whitespace or
    /// punctuation; *right-flanking* is the mirror image. `*` opens when
    /// left-flanking and closes when right-flanking.
    ///
    /// `_` additionally may not open or close inside a word, which is what keeps
    /// `snake_case_name` from turning into emphasis when it arrives in Markdown
    /// somebody else wrote.
    private static func flanking(_ bytes: [UInt8], _ start: Int, _ end: Int)
        -> (canOpen: Bool, canClose: Bool) {
        // The rules are stated over code points, so the characters either side of
        // the run are decoded rather than read as bytes. Everything else in the
        // scanner can stay bytes because it only ever branches on ASCII.
        let before = scalarBefore(start, bytes)
        let after = scalarAt(end, bytes)
        // Absent means "start/end of line", which counts as whitespace.
        let spaceBefore = before.map(isUnicodeWhitespace) ?? true
        let spaceAfter = after.map(isUnicodeWhitespace) ?? true
        let punctBefore = before.map(isUnicodePunctuation) ?? false
        let punctAfter = after.map(isUnicodePunctuation) ?? false

        let left = !spaceAfter && (!punctAfter || spaceBefore || punctBefore)
        let right = !spaceBefore && (!punctBefore || spaceAfter || punctAfter)
        guard bytes[start] == UInt8(ascii: "_") else { return (left, right) }
        return (left && (!right || punctBefore), right && (!left || punctAfter))
    }

    private static func isUnicodeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x80 ? (scalar == " " || scalar == "\t" || scalar == "\n"
                               || scalar == "\r" || scalar.value == 0x0B || scalar.value == 0x0C)
            : scalar.properties.isWhitespace
    }

    private static func isUnicodePunctuation(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x80 {
            return "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars.contains(scalar)
        }
        let character = Character(scalar)
        return character.isPunctuation || character.isSymbol
    }

    /// The scalar beginning at `index`, or nil at the end of the buffer.
    private static func scalarAt(_ index: Int, _ bytes: [UInt8]) -> Unicode.Scalar? {
        guard index < bytes.count else { return nil }
        let lead = bytes[index]
        if lead < 0x80 { return Unicode.Scalar(lead) }
        let width = lead >= 0xF0 ? 4 : (lead >= 0xE0 ? 3 : 2)
        let end = min(index + width, bytes.count)
        return String(decoding: bytes[index..<end], as: UTF8.self).unicodeScalars.first
    }

    /// The scalar ending just before `index`, or nil at the start of the buffer.
    private static func scalarBefore(_ index: Int, _ bytes: [UInt8]) -> Unicode.Scalar? {
        guard index > 0 else { return nil }
        var start = index - 1
        // Step back over the continuation bytes of a multi-byte character.
        while start > 0, bytes[start] & 0xC0 == 0x80 { start -= 1 }
        return scalarAt(start, bytes)
    }

    /// The length of the run of `byte` starting at `from`.
    private static func runLength(_ bytes: [UInt8], _ from: Int, _ byte: UInt8) -> Int {
        var n = 0
        while from + n < bytes.count, bytes[from + n] == byte { n += 1 }
        return n
    }

    /// The start of the next run of exactly `length` backticks.
    private static func findBacktickRun(_ bytes: [UInt8], _ from: Int, _ length: Int) -> Int? {
        let tick = UInt8(ascii: "`")
        var i = from
        while i < bytes.count {
            guard bytes[i] == tick else { i += 1; continue }
            let run = runLength(bytes, i, tick)
            if run == length { return i }
            i += run
        }
        return nil
    }

    /// The start of the next run of `byte` at least `length` long that can close
    /// emphasis, skipping escaped delimiters.
    private static func findClosingRun(_ bytes: [UInt8], _ from: Int,
                                       _ byte: UInt8, _ length: Int) -> Int? {
        var i = from
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
            if bytes[i] == byte {
                let run = runLength(bytes, i, byte)
                if run >= length, flanking(bytes, i, i + run).canClose { return i }
                i += run
                continue
            }
            i += 1
        }
        return nil
    }

    /// The next `byte` that isn't backslash-escaped. A closing delimiter has to
    /// skip `\*`, or emphasis ends at an asterisk the author escaped precisely
    /// so that it would be text. (`findSeq` needs no equivalent: an escaped
    /// delimiter can't form a run of two.)
    private static func findUnescaped(_ bytes: [UInt8], _ from: Int, _ byte: UInt8) -> Int? {
        var i = from
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
            if bytes[i] == byte { return i }
            i += 1
        }
        return nil
    }

    /// Resolve backslash escapes inside a mark's text.
    ///
    /// The inline scanner handles escapes as it walks, but a mark's content is
    /// lifted out as a raw substring, so it never passes through that path — a
    /// `\*` written inside `**…**` would survive as a literal backslash. Code
    /// spans are excluded by their callers: they're literal by definition, and
    /// CommonMark doesn't resolve escapes inside them either.
    private static func unescapeInline(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        let asciiPunct = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(after: i)
            if s[i] == "\\", next < s.endIndex, asciiPunct.contains(s[next]) {
                out.append(s[next])
                i = s.index(after: next)
            } else {
                out.append(s[i])
                i = next
            }
        }
        return out
    }

    private static func findMathClose(_ bytes: [UInt8], _ from: Int) -> Int? {
        var i = from
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\n") { return nil }
            if b == UInt8(ascii: "\\") { i += 2; continue }  // an escaped "$" doesn't close
            if b == UInt8(ascii: "$"),
               !(scalarBefore(i, bytes).map(isUnicodeWhitespace) ?? true),
               i + 1 >= bytes.count || !(bytes[i + 1] >= UInt8(ascii: "0")
                                         && bytes[i + 1] <= UInt8(ascii: "9")) {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func findByte(_ bytes: [UInt8], _ from: Int, _ byte: UInt8) -> Int? {
        var i = from
        while i < bytes.count { if bytes[i] == byte { return i }; i += 1 }
        return nil
    }

    private static func findSeq(_ bytes: [UInt8], _ from: Int, _ seq: [UInt8]) -> Int? {
        guard !seq.isEmpty else { return nil }
        var i = from
        while i + seq.count <= bytes.count {
            if Array(bytes[i..<(i + seq.count)]) == seq { return i }
            i += 1
        }
        return nil
    }
}
