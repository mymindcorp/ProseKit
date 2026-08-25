import Foundation
public import DocumentModel

// MARK: - Serialize

public enum MarkdownSerializer {
    public static func serialize(_ doc: Node) -> String {
        serializeBlocks(doc.content, indent: "")
    }

    /// Write a run of sibling blocks. Two lists of the same kind in a row have
    /// to use different markers — "- a" then "+ b", or "1. a" then "2) b" —
    /// because a reader joins two lists that look alike into one, which is
    /// exactly what told them apart in the source.
    static func serializeBlocks(_ fragment: Fragment, indent: String,
                                separator: String = "\n\n") -> String {
        serializeBlocks(fragment.content, indent: indent, separator: separator)
    }

    static func serializeBlocks(_ nodes: [Node], indent: String,
                                separator: String = "\n\n") -> String {
        var out = ""
        var alternate = false
        var previous: String?
        for node in nodes {
            let name = node.type.name
            let isList = name == "bulletList" || name == "orderedList"
            if isList, name == previous { alternate.toggle() } else if isList { alternate = false }
            if previous != nil { out += separator }
            out += serializeBlock(node, indent: indent, alternate: isList && alternate)
            previous = name
        }
        return out
    }

    /// A heading's inline content on one line. A hard break wrote `\` and a
    /// newline; the backslash alone reads back as a literal backslash — a stray
    /// `\` in the title — so the break is spelled the way a table cell spells
    /// one instead. Any other newline is a soft wrap and reads as a space.
    private static func flattenHeadingLines(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        // A literal backslash in the text is written as two, so only an odd run
        // of them ends in the one a hard break put there.
        var backslashes = 0
        for character in text {
            if character == "\n" {
                if backslashes % 2 == 1 {
                    out.removeLast()
                    out += "<br>"
                } else {
                    out += " "
                }
                backslashes = 0
                continue
            }
            backslashes = character == "\\" ? backslashes + 1 : 0
            out.append(character)
        }
        return out
    }

    /// The longest run of `^` opening a line of the given text — the fence a
    /// figure written around it has to beat.
    private static func longestCaretRun(_ text: String) -> Int {
        var longest = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let run = line.drop { $0 == " " || $0 == "\t" }.prefix { $0 == "^" }.count
            longest = max(longest, run)
        }
        return longest
    }

    static func serializeBlock(_ node: Node, indent: String, alternate: Bool = false) -> String {
        switch node.type.name {
        case "paragraph":
            return escapeLeadingBlockMarker(serializeInline(node.content))
        case "heading":
            let level = node.attrs["level"]?.intValue ?? 1
            // A heading is one line, so a line break inside its content — which
            // a mark spanning a soft wrap can carry — reads as a space.
            var text = serializeInline(node.content)
            if text.utf8.contains(UInt8(ascii: "\n")) {
                text = flattenHeadingLines(text)
            }
            // A trailing run of "#" reads as a closing sequence, so escape it.
            if text.hasSuffix("#") {
                let run = text.reversed().prefix(while: { $0 == "#" }).count
                text.insert("\\", at: text.index(text.endIndex, offsetBy: -run))
            }
            return String(repeating: "#", count: level) + " " + text
        case "blockquote":
            return prefixLines(serializeBlocks(node.content, indent: indent), with: "> ")
        case "codeBlock":
            // Fence with the delimiter the code itself doesn't use.
            let fence = node.textContent.contains("```") ? "~~~" : "```"
            let language = node.attrs["language"]?.stringValue ?? ""
            return "\(fence)\(language)\n\(node.textContent)\n\(fence)"
        case "horizontalRule":
            return "---"
        case "bulletList":
            let tight = node.attrs["tight"]?.boolValue ?? false
            let bullet = alternate ? "+" : "-"
            if needsGapAfterMarker(node) {
                return "\(bullet)\n\n  " + listItemText(node.child(0), continuation: "  ", tight: tight)
            }
            return (0..<node.childCount)
                .map { "\(bullet) " + listItemText(node.child($0), continuation: "  ", tight: tight) }
                .joined(separator: itemSeparator(node))
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
            let tight = node.attrs["tight"]?.boolValue ?? false
            let delimiter = alternate ? ")" : "."
            if needsGapAfterMarker(node) {
                let pad = String(repeating: " ", count: "\(start)\(delimiter) ".count)
                return "\(start)\(delimiter)\n\n" + pad
                    + listItemText(node.child(0), continuation: pad, tight: tight)
            }
            return (0..<node.childCount).map { i in
                let marker = "\(start + i)\(delimiter) "
                return marker + listItemText(node.child(i),
                                             continuation: String(repeating: " ", count: marker.count),
                                             tight: tight)
            }.joined(separator: itemSeparator(node))
        case "image":
            // An image is block-level in the default schema, and without a case
            // here it fell through to serializing an atom's content — which is
            // empty, so every image simply disappeared.
            let src = node.attrs["src"]?.stringValue ?? ""
            let alt = altText(node.attrs["alt"]?.stringValue ?? "")
            if let title = node.attrs["title"]?.stringValue, !title.isEmpty {
                let q = title.contains("\"") ? "'" : "\""
                return "![\(alt)](\(destination(src)) \(q)\(titleText(title))\(q))"
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
            // A figure holding a figure needs the longer fence, the way a code
            // fence does: with both written `^^^`, the inner closing fence ends
            // the outer figure and the two come apart into siblings.
            let bodyText = body.joined(separator: "\n\n")
            let fence = String(repeating: "^", count: max(3, longestCaretRun(bodyText) + 1))
            let fenceEnd = caption.isEmpty ? fence : "\(fence) \(caption)"
            return "\(fence)\n\(bodyText)\n\(fenceEnd)"
        case "details":
            // Markdown has no collapsible section; emit the HTML block form that
            // GitHub-flavored Markdown (and our parser) understands.
            let open = node.attrs["open"]?.boolValue ?? false
            let summary = node.childCount > 0 ? serializeInline(node.child(0).content) : ""
            let content = node.childCount > 1 ? node.child(1) : nil
            let body = content.map { serializeBlocks($0.content, indent: indent) } ?? ""
            return "<details\(open ? " open" : "")>\n<summary>\(summary)</summary>\n\n\(body)\n\n</details>"
        case "footnoteDefinition":
            // `[^label]: ` then the note. Blocks after the first are indented
            // four columns, which is what keeps them part of the note rather
            // than the document that follows it.
            let label = node.attrs["label"]?.stringValue ?? ""
            var body = ""
            for (i, block) in node.content.content.enumerated() {
                if i > 0 { body += "\n\n" }
                body += serializeBlock(block, indent: indent)
            }
            return "[^\(label)]: "
                + prefixLines(body, with: "    ", skippingFirst: true, blankLines: false)
        case "table":
            return serializeTable(node)
        default:
            return serializeInline(node.content)
        }
    }

    /// A table as a GitHub pipe table, or as HTML when the pipes can't hold it.
    ///
    /// A pipe table is a rectangle of single-line cells under a header row: it
    /// has no way to spell a `colspan`, a cell holding two paragraphs, or a
    /// stored column width. A table needing any of those is written as the HTML
    /// block the parser reads back — the same fallback `details` uses — because
    /// the alternative is flattening a structure the document really has.
    static func serializeTable(_ node: Node) -> String {
        guard let table = pipeTableRows(node), let columns = table.rows.first?.count else {
            return HTMLSerializer.serialize(fragment: Fragment.from([node]))
        }
        func line(_ cells: [String]) -> String {
            "|" + cells.map { " \($0) " }.joined(separator: "|") + "|"
        }
        let delimiters = (0..<columns).map { column -> String in
            switch column < table.alignments.count ? table.alignments[column] : nil {
            case "left": return ":--"
            case "center": return ":-:"
            case "right": return "--:"
            default: return "---"
            }
        }
        var out = [line(table.rows[0]), line(delimiters)]
        out.append(contentsOf: table.rows.dropFirst().map(line))
        return out.joined(separator: "\n")
    }

    /// The table's cells as pipe-table text with each column's alignment, or
    /// nil if the shape doesn't fit: a header row and only a header row, every
    /// row the same width, one paragraph to a cell, no spans and no stored
    /// widths — and every cell in a column aligned the same way, since a
    /// delimiter row can only say one thing per column.
    private static func pipeTableRows(_ table: Node) -> (rows: [[String]], alignments: [String?])? {
        var rows: [[String]] = []
        var alignments: [String?] = []
        for r in 0..<table.childCount {
            let row = table.child(r)
            guard row.type.name == "tableRow", row.childCount > 0 else { return nil }
            var cells: [String] = []
            for c in 0..<row.childCount {
                let cell = row.child(c)
                // The first row is the header and no other row may be one.
                guard (cell.type.name == "tableHeader") == (r == 0) else { return nil }
                guard cell.attrs["colspan"]?.intValue ?? 1 == 1,
                      cell.attrs["rowspan"]?.intValue ?? 1 == 1,
                      cell.attrs["colwidth"]?.isNull ?? true else { return nil }
                // The first row sets each column's alignment; a later cell that
                // disagrees is something the pipes can't say.
                let align = cell.attrs["align"]?.stringValue
                if r == 0 { alignments.append(align) }
                else if c < alignments.count, alignments[c] != align { return nil }
                // An empty cell is a cell; more than one block in one isn't
                // something a row of pipes can say.
                guard cell.childCount <= 1 else { return nil }
                guard let block = cell.childCount == 1 ? cell.child(0) : nil else {
                    cells.append(""); continue
                }
                guard block.type.name == "paragraph" else { return nil }
                let text = serializeInline(block.content)
                // A hard break inside a cell writes as a newline, which would
                // end the row.
                guard !text.contains("\n") else { return nil }
                cells.append(text.replacingOccurrences(of: "|", with: "\\|"))
            }
            guard cells.count == (rows.first?.count ?? cells.count) else { return nil }
            rows.append(cells)
        }
        return rows.isEmpty ? nil : (rows, alignments)
    }

    /// Escape a leading `#`/`>`/`-`/`*`/`+`/`1.` so a paragraph that happens to
    /// start with block-marker syntax round-trips as a paragraph, not a heading/
    /// quote/list.
    ///
    /// Only the first few characters can spell a marker, so this walks the start
    /// of the string instead of copying all of it into an array first: a
    /// paragraph pays for its opening run here, not for its whole text.
    private static func escapeLeadingBlockMarker(_ s: String) -> String {
        guard let first = s.first else { return s }
        if first == "#" {
            var n = 0
            var i = s.startIndex
            while i < s.endIndex, s[i] == "#" { n += 1; i = s.index(after: i) }
            if n <= 6, i == s.endIndex || s[i] == " " { return "\\" + s }
        }
        if first == ">" { return "\\" + s }
        // A figure fence, when the figure nodes are registered. ("$$" needs no
        // case here — dollars are already escaped everywhere in prose.)
        if s.hasPrefix("^^^") { return "\\" + s }
        if first == "-" || first == "*" || first == "+" {
            let second = s.index(after: s.startIndex)
            if second < s.endIndex, s[second] == " " { return "\\" + s }
        }
        guard first.isNumber else { return s }
        var i = s.startIndex
        while i < s.endIndex, s[i].isNumber { i = s.index(after: i) }
        guard i < s.endIndex, s[i] == "." else { return s }
        let afterDot = s.index(after: i)
        guard afterDot < s.endIndex, s[afterDot] == " " else { return s }
        return s[..<i] + "\\." + s[afterDot...]
    }

    /// `body` with `prefix` in front of each of its lines — how a blockquote
    /// marks the blocks inside it, and how a list item indents the ones it
    /// holds. A list item skips its first line, which already sits after the
    /// marker, and leaves blank lines blank rather than filling them with the
    /// trailing spaces the indent would be.
    ///
    /// The lines are cut and copied as UTF-8: a newline byte can't be part of
    /// any other character, so the split is exact, and each line moves in one
    /// piece rather than a character or a scalar at a time. A list nested `d`
    /// deep re-indents its innermost text `d` times, so what this costs per
    /// line is paid over and over.
    private static func prefixLines(_ body: String, with prefix: String,
                                    skippingFirst: Bool = false,
                                    blankLines: Bool = true) -> String {
        let newline = UInt8(ascii: "\n")
        let utf8 = body.utf8
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count + prefix.utf8.count * 4)
        var lineStart = utf8.startIndex
        var first = true
        while true {
            let end = utf8[lineStart...].firstIndex(of: newline) ?? utf8.endIndex
            let line = utf8[lineStart..<end]
            if !first { out.append(newline) }
            if !(first && skippingFirst) && !(line.isEmpty && !blankLines) {
                out.append(contentsOf: prefix.utf8)
            }
            out.append(contentsOf: line)
            first = false
            if end == utf8.endIndex { return String(decoding: out, as: UTF8.self) }
            lineStart = utf8.index(after: end)
        }
    }

    /// CommonMark keeps a block in a list item only while every one of its lines
    /// is indented to the content column — "indenting subsequent lines of Ls by
    /// W + N spaces". Indenting just the first line of each child left the rest
    /// of a multi-line block (a `$$` formula, a fenced code block) sitting at
    /// column 0, where it reads as a sibling of the list rather than part of it.
    static func listItemText(_ item: Node, continuation: String, tight: Bool = false) -> String {
        // A `listItem` must begin with a paragraph, so an item whose real
        // content is a code block carries an empty one that `fitContent` added.
        // Writing it out would put a blank line after the marker, which reads
        // back as a different document — and the reader re-inserts the empty
        // paragraph anyway.
        var children = item.content.content[...]
        if children.count > 1, children[0].type.name == "paragraph", children[0].content.size == 0 {
            children.removeFirst()
        }
        // Blocks are separated by a blank line here as everywhere else, or two
        // paragraphs in one item would read back as a single paragraph. Not in a
        // tight item: a blank line between two blocks is exactly what would make
        // the whole list loose again, and two paragraphs can't arise there for
        // the same reason.
        let separator = tight ? "\n" : "\n\n"
        var body = ""
        for (i, child) in children.enumerated() {
            if i > 0 { body += separator }
            body += child.type.name == "horizontalRule"
                ? "***" : serializeBlock(child, indent: continuation)
        }
        guard body.unicodeScalars.contains("\n") else { return body }
        return prefixLines(body, with: continuation, skippingFirst: true, blankLines: false)
    }

    /// A loose list normally shows it with a blank line between two items — but
    /// a one-item list has no gap to put one in, and neither has an item holding
    /// a single block. Its other spelling is a blank line after the marker,
    /// which is how such a list is usually written in the first place.
    private static func needsGapAfterMarker(_ list: Node) -> Bool {
        list.attrs["tight"]?.boolValue == false && list.childCount == 1
            && list.child(0).childCount == 1
    }

    /// What goes between two items. A loose list keeps the blank line that made
    /// it loose, so reading the result back gives the same list — without this,
    /// every list came back tight.
    private static func itemSeparator(_ list: Node) -> String {
        list.attrs["tight"]?.boolValue == false ? "\n\n" : "\n"
    }

    /// Marks that wrap a run of inline content, outermost first. A mark can
    /// cover several nodes — `**[a](x) b**` is one bold run across a link and
    /// some text — so they are opened and closed around runs, not per node.
    ///
    /// The rank also breaks the tie between two marks covering exactly the same
    /// text, which can be nested either way round.
    private static let spanningRank: [String: Int] = [
        "link": 0, "italic": 1, "bold": 2, "strike": 3,
        "highlight": 4, "underline": 5, "subscript": 6, "superscript": 7,
    ]

    /// Marks Markdown has no spelling for, written as the HTML tags they came
    /// from — which the parser now reads back. They used to be dropped, so
    /// exporting to Markdown quietly lost them.
    private static let markTags = ["underline": "u", "subscript": "sub", "superscript": "sup"]

    private static func markOpen(_ mark: Mark) -> String {
        switch mark.type.name {
        case "link": return "["
        case "italic": return "*"
        case "bold": return "**"
        case "strike": return "~~"
        case "highlight": return "=="
        default: return markTags[mark.type.name].map { "<\($0)>" } ?? ""
        }
    }

    private static func markClose(_ mark: Mark) -> String {
        switch mark.type.name {
        case "link":
            let href = mark.attrs["href"]?.stringValue ?? ""
            if let title = mark.attrs["title"]?.stringValue, !title.isEmpty {
                let q = title.contains("\"") ? "'" : "\""
                return "](\(destination(href)) \(q)\(titleText(title))\(q))"
            }
            return "](\(destination(href)))"
        case "italic": return "*"
        case "bold": return "**"
        case "strike": return "~~"
        case "highlight": return "=="
        default: return markTags[mark.type.name].map { "</\($0)>" } ?? ""
        }
    }

    /// The HTML spelling of a mark that is normally a delimiter run. CommonMark
    /// only lets `*`/`**` open or close where the characters around them allow
    /// it (see `writeInline`), and where they don't, the tag form is the only
    /// spelling that survives being read back.
    private static func markHTMLOpen(_ mark: Mark) -> String {
        switch mark.type.name {
        case "italic": return "<em>"
        case "bold": return "<strong>"
        default: return markOpen(mark)
        }
    }

    private static func markHTMLClose(_ mark: Mark) -> String {
        switch mark.type.name {
        case "italic": return "</em>"
        case "bold": return "</strong>"
        default: return markClose(mark)
        }
    }

    /// CommonMark's "punctuation character" — ASCII punctuation, or a Unicode
    /// punctuation or symbol character. Which side of a delimiter run one sits
    /// on is what decides whether the run may open or close emphasis.
    private static func isPunctuation(_ character: Character) -> Bool {
        if let ascii = character.asciiValue {
            return (ascii >= 33 && ascii <= 47) || (ascii >= 58 && ascii <= 64)
                || (ascii >= 91 && ascii <= 96) || (ascii >= 123 && ascii <= 126)
        }
        return character.isPunctuation || character.isSymbol
    }

    static func serializeInline(_ fragment: Fragment) -> String {
        var out = ""
        // Text is what most of a document is, so the buffer starts out big
        // enough for it and grows only for the markup around it.
        out.reserveCapacity(fragment.size + 16)
        writeInline(fragment, into: &out)
        return out
    }

    static func writeInline(_ fragment: Fragment, into out: inout String) {
        let children = fragment.content
        // Marks currently open, outermost first, and whether each was opened as
        // an HTML tag rather than as a delimiter run.
        var active: [Mark] = []
        var activeHTML: [Bool] = []
        func closeDown(to keep: Int) {
            guard active.count > keep else { return }
            // A closing delimiter run preceded by whitespace closes nothing —
            // the whitespace has to end up on the outside of it. Only spaces
            // and tabs: a newline here is the one a hard break just wrote.
            if (keep..<active.count).contains(where: { expelsWhitespace(active[$0]) && !activeHTML[$0] }) {
                var held = ""
                while true {
                    // Only spaces and tabs — and the newline of a hard break,
                    // which closes nothing either and has to move out with
                    // whatever whitespace surrounds it.
                    let before = held.count
                    while let last = out.last, last == " " || last == "\t" {
                        held.insert(last, at: held.startIndex)
                        out.removeLast()
                    }
                    if out.hasSuffix("\\\n") {
                        out.removeLast(2)
                        held = "\\\n" + held
                    }
                    if held.count == before { break }
                }
                // `held` came before whatever is already pending.
                pending = held + pending
            }
            while active.count > keep {
                let mark = active.removeLast()
                out += activeHTML.removeLast() ? markHTMLClose(mark) : markClose(mark)
            }
        }
        // A hard break held over a mark that is written as a tag has to be a tag
        // too: no reader accepts a newline inside one, so `<sup>a\<newline>b</sup>`
        // comes back as literal angle brackets with the mark gone. `closeDown`
        // has already run by the time this is called, so what is still open is
        // exactly what the break would land inside.
        func flushPending() {
            guard !pending.isEmpty else { return }
            let inTag = activeHTML.contains(true)
                || active.contains { markTags[$0.type.name] != nil }
            out += inTag ? pending.replacingOccurrences(of: "\\\n", with: "<br>") : pending
            pending = ""
        }
        func same(_ a: Mark, _ b: Mark) -> Bool { a.type === b.type && a.attrs == b.attrs }
        func carries(_ node: Node, _ mark: Mark) -> Bool {
            node.marks.contains { same($0, mark) }
        }
        // Marks written as a delimiter run that obeys the flanking rules.
        // CommonMark will not open such a run when it is followed by
        // whitespace, or close one preceded by it, so `**foo **bar` is not
        // bold — it is those eleven characters. The whitespace has to move
        // outside the delimiters.
        //
        // `~~` and `==` are written as runs too but are deliberately paired
        // without the flanking rules (see the note where they are read back),
        // so whitespace beside one of those closes it perfectly well and is
        // content the mark is entitled to keep. Expelling it there would only
        // throw the whitespace away.
        //
        // The cost is that a strike we write with an inner space — `~~gone ~~`
        // — is read back by *this* parser and not by cmark-gfm, which does
        // flank `~~`. Worth revisiting if these documents have to travel; it
        // belongs with the pairing decision rather than here.
        func expelsWhitespace(_ mark: Mark) -> Bool {
            switch mark.type.name {
            case "italic", "bold": return true
            default: return false
            }
        }
        // Written-but-not-yet-placed output: whitespace taken out of a closing
        // delimiter run, and hard breaks. Both have to end up outside the
        // delimiters, and both are dropped if nothing follows them — a `\` at
        // the end of a block reads back as a literal backslash.
        var pending = ""
        // Where each mark's current run ends, remembered across the loop below.
        //
        // A run that ends at `e` ends at `e` from every position inside it, so
        // the scan happens once per run instead of once per node in it. Without
        // that, one mark spanning N children costs O(N²) — and a bolded passage
        // with links or emphasis inside it is exactly that shape, since those
        // children can't merge into one text node. A paragraph of 6000 such
        // children took 160 ms to write out.
        var runEnds: [(mark: Mark, end: Int)] = []
        func runEnd(_ mark: Mark, from: Int) -> Int {
            let cached = runEnds.firstIndex { same($0.mark, mark) }
            if let cached, runEnds[cached].end > from { return runEnds[cached].end }
            var j = from
            while j < children.count, carries(children[j], mark) { j += 1 }
            if let cached { runEnds[cached].end = j } else { runEnds.append((mark, j)) }
            return j
        }
        // A `*`/`**` run only opens emphasis when the character after it isn't
        // whitespace and — where that character is punctuation — only when the
        // one before the run is whitespace or punctuation. Closing has the rule
        // mirrored. So `a**~~x~~**` is eleven literal characters rather than a
        // bolded strike, and `**x.**a` isn't bold either. Where the delimiters
        // would land like that, the mark is written as a tag instead, which has
        // no such rule and which the reader takes back as the same mark.
        //
        // Only `italic` and `bold` need it: `~~` and `==` are paired here
        // without the flanking rules (see `expelsWhitespace`), and a link's
        // brackets aren't a delimiter run at all.
        func writtenEdges(_ node: Node) -> (first: Character?, last: Character?) {
            // An atom is spelled with punctuation at both ends — `![a](b)`,
            // `[[Page]]`, `$x$` — whichever one it is.
            guard node.isText else { return ("!", ")") }
            if node.marks.contains(where: { $0.type.name == "code" }) { return ("`", "`") }
            return (node.text?.first, node.text?.last)
        }
        // `*` and `**` written back to back merge into one delimiter run, and
        // the flanking rule is asked about the run, not about the halves — the
        // `***` in `**a***.b*` is followed by `.` and preceded by `a`, so
        // neither half can open. Marks spelled with an asterisk are therefore
        // looked through when working out what sits on either side.
        func isStarRun(_ mark: Mark) -> Bool { expelsWhitespace(mark) }
        // A node that can't hold the mark doesn't close it either (see `canCarry`
        // in the loop below), so the mark stays open across it and its closing
        // delimiter lands further along than the run of carriers ends.
        func cannotCarry(_ node: Node, _ mark: Mark) -> Bool {
            guard node.isText else { return false }
            if node.marks.contains(where: { $0.type === mark.type }) { return false }
            return !mark.addToSet(node.marks).contains { $0.type === mark.type }
        }
        func spellAsHTML(_ mark: Mark, at index: Int, opening: ArraySlice<Mark>, offset: Int) -> Bool {
            guard expelsWhitespace(mark) else { return false }

            // Where the closing delimiter lands, and whether the mark has to
            // stay open across a line break to get there — which it can't do as
            // a tag, since no reader accepts a newline inside one.
            var closeAt = index + 1
            var crossedBreak = false
            var breakBeforeClose = false
            var scan = index
            while scan < children.count {
                let child = children[scan]
                if child.type.name == "hardBreak" {
                    crossedBreak = true
                    breakBeforeClose = true
                    scan += 1
                    continue
                }
                if carries(child, mark) {
                    if crossedBreak { return false }
                    if child.isText, child.text?.contains("\n") ?? false { return false }
                    breakBeforeClose = false
                } else if !cannotCarry(child, mark) {
                    break
                }
                closeAt = scan + 1
                scan += 1
            }

            // The character before the run this opening delimiter joins.
            var opens = true
            var cut = out.endIndex
            while cut > out.startIndex, out[out.index(before: cut)] == "*" { cut = out.index(before: cut) }
            if cut > out.startIndex {
                let before = out[out.index(before: cut)]
                if !before.isWhitespace, !isPunctuation(before) {
                    // What lands after it: the first delimiter opened behind this
                    // one that isn't part of the same run, or else the content.
                    let after = opening.dropFirst(offset + 1).first(where: { !isStarRun($0) })
                        .flatMap { markOpen($0).first } ?? writtenEdges(children[index]).first
                    opens = !(after.map(isPunctuation) ?? false)
                }
            }

            var closes = true
            if closeAt < children.count {
                let last = children[closeAt - 1]
                // A mark nested inside this one closes first, and its closing
                // delimiter is punctuation — unless it is another asterisk run,
                // which merges with this one.
                let closesInside = last.marks.contains { other in
                    !same(other, mark) && spanningRank[other.type.name] != nil && !isStarRun(other)
                        && runEnd(other, from: closeAt - 1) == closeAt
                }
                let before = closesInside ? Character(")") : writtenEdges(last).last
                if before.map(isPunctuation) ?? false {
                    let next = children[closeAt]
                    let opensNext = next.marks.contains { other in
                        spanningRank[other.type.name] != nil && !isStarRun(other) && !carries(last, other)
                    }
                    let after: Character? = breakBeforeClose ? "\\"
                        : (opensNext ? "[" : writtenEdges(next).first)
                    closes = after.map { $0.isWhitespace || isPunctuation($0) } ?? true
                }
            }
            return !(opens && closes)
        }

        // The spanning marks a node carries, outermost first, reused each pass
        // so the loop doesn't allocate two arrays per child.
        var own: [Mark] = []
        var ranked: [(mark: Mark, rank: Int, end: Int)] = []
        var wanted: [Mark] = []
        for i in children.indices {
            let node = children[i]
            // A hard break is held rather than written. Markdown has no
            // spelling for one at the end of a block, and a closing delimiter
            // run written directly after one would not close — so it waits
            // until there is something after it, and the marks it interrupts
            // close before it rather than after.
            if node.type.name == "hardBreak" {
                pending += "\\\n"
                continue
            }
            // Plain text between marked runs — the bulk of most paragraphs —
            // has nothing to open or close.
            if node.marks.isEmpty, active.isEmpty, pending.isEmpty {
                inlineBody(node, into: &out)
                continue
            }
            // A link that is nothing but its own destination is written the way
            // it was typed — bare — rather than as `[url](url)`. Only when the
            // link covers exactly this node and carries nothing else, and only
            // when reading the bare form back would give this link again, which
            // `isWholeLiteralAutolink` is the precise test for.
            if node.isText, node.marks.count == 1, let link = node.marks.first,
               link.type.name == "link",
               (link.attrs["title"]?.stringValue ?? "").isEmpty,
               let href = link.attrs["href"]?.stringValue,
               let text = node.text, text == href, MarkdownParser.isWholeLiteralAutolink(text),
               i == 0 || !carries(children[i - 1], link),
               runEnd(link, from: i) == i + 1 {
                closeDown(to: 0)
                flushPending()
                out += text
                continue
            }
            // A mark covering more of what follows is written outside one
            // covering less, so a bold run across a link and the text after it
            // comes out as `**[a](x) b**` rather than as two bold runs with the
            // link between them.
            //
            // Each run end is measured once here rather than inside the
            // comparison, which asked for it O(m log m) times per node.
            ranked.removeAll(keepingCapacity: true)
            for mark in node.marks {
                guard let rank = spanningRank[mark.type.name] else { continue }
                ranked.append((mark, rank, runEnd(mark, from: i)))
            }
            ranked.sort { $0.end == $1.end ? $0.rank < $1.rank : $0.end > $1.end }
            own.removeAll(keepingCapacity: true)
            for entry in ranked { own.append(entry.mark) }
            // A node that can't carry a mark shouldn't close it either. A code
            // span excludes every other mark, so closing and reopening emphasis
            // around one would emit delimiter runs that don't parse — and the
            // reader drops the excluded mark from the code span regardless.
            func canCarry(_ mark: Mark) -> Bool {
                if !node.isText { return true }
                if node.marks.contains(where: { $0.type === mark.type }) { return true }
                return mark.addToSet(node.marks).contains { $0.type === mark.type }
            }
            wanted.removeAll(keepingCapacity: true)
            for mark in active
            where own.contains(where: { same($0, mark) }) || !canCarry(mark) {
                wanted.append(mark)
            }
            for mark in own where !wanted.contains(where: { same($0, mark) }) {
                wanted.append(mark)
            }
            // Keep whatever the previous node already opened, in the same order.
            var shared = 0
            while shared < active.count, shared < wanted.count,
                  same(active[shared], wanted[shared]) { shared += 1 }
            // A text node that is nothing but whitespace gives the delimiters
            // nothing to wrap, so none are opened around it. It still closes
            // the marks that end here; the whitespace itself is held, because
            // whether it belongs inside or outside the marks around it is
            // decided by what comes next — and if nothing does, it is dropped.
            //
            // Only for the marks that can't hold whitespace against a delimiter
            // — the same test the leading-whitespace expulsion below uses. A
            // mark paired without the flanking rules keeps whitespace perfectly
            // well, so suppressing its delimiters doesn't move the whitespace
            // outside the mark, it deletes the mark.
            //
            // `code` has to be asked for separately: it isn't a spanning mark,
            // so it never reaches `wanted` — `inlineBody` writes it around the
            // node's own text. It is also the case that matters most, since
            // `` ` ` `` is a code span holding a space, and CommonMark's "strip
            // one space from each end" rule explicitly spares a span that is
            // all spaces.
            if node.isText, let text = node.text, !text.isEmpty,
               text.allSatisfy({ $0 == " " || $0 == "\t" }),
               wanted[shared...].allSatisfy(expelsWhitespace),
               !node.marks.contains(where: { $0.type.name == "code" }) {
                closeDown(to: shared)
                pending += text
                continue
            }
            // An opening delimiter run followed by whitespace opens nothing,
            // so whitespace at the front of the text moves out ahead of it.
            var body = node
            var leading = ""
            if wanted[shared...].contains(where: expelsWhitespace), node.isText, let text = node.text {
                let lead = text.prefix { $0 == " " || $0 == "\t" }
                if !lead.isEmpty {
                    leading = String(lead)
                    body = node.withText(String(text.dropFirst(lead.count)))
                }
            }
            closeDown(to: shared)
            flushPending()
            out += leading
            let opening = wanted[shared...]
            for (offset, mark) in opening.enumerated() {
                // A "!" directly before a link's bracket would read back as an
                // image, so escape it. Only there — escaping every exclamation
                // mark in prose would be noise.
                if mark.type.name == "link", out.hasSuffix("!") {
                    out.removeLast()
                    out += "\\!"
                }
                let asHTML = spellAsHTML(mark, at: i, opening: opening, offset: offset)
                out += asHTML ? markHTMLOpen(mark) : markOpen(mark)
                active.append(mark)
                activeHTML.append(asHTML)
            }
            inlineBody(body, into: &out)
        }
        closeDown(to: 0)
        // Whatever is still held at the end is dropped rather than written: no
        // parser keeps trailing spaces on a line, and two of them would read
        // back as a hard break.
    }

    /// A node's own text, with the marks that don't wrap a run — currently only
    /// `code`, whose fence length depends on the content it holds.
    private static func inlineBody(_ node: Node, into out: inout String) {
        if node.isText {
            let text = node.text ?? ""
            guard node.marks.contains(where: { $0.type.name == "code" }) else {
                // A delimiter character has to be escaped or it pairs with a
                // later one and becomes markup.
                escapeInline(text, into: &out)
                return
            }
            // A code span is literal, so escapes inside one would read back as
            // backslashes; it is fenced by a run longer than any it contains.
            var longest = 0, current = 0
            for ch in text.utf8 {
                current = ch == UInt8(ascii: "`") ? current + 1 : 0
                longest = max(longest, current)
            }
            let fence = String(repeating: "`", count: longest + 1)
            let allSpaces = !text.isEmpty && text.allSatisfy { $0 == " " }
            let edgy = text.hasPrefix("`") || text.hasSuffix("`")
                || text.hasPrefix(" ") || text.hasSuffix(" ")
            let pad = (!allSpaces && edgy) ? " " : ""
            out += fence
            out += pad
            out += text
            out += pad
            out += fence
            return
        }
        switch node.type.name {
        case "hardBreak":
            out += "\\\n"
        case "image":
            // An image can sit inline as well as in its own block, so the title
            // has to be written on both paths.
            let src = node.attrs["src"]?.stringValue ?? ""
            let alt = altText(node.attrs["alt"]?.stringValue ?? "")
            if let title = node.attrs["title"]?.stringValue, !title.isEmpty {
                let q = title.contains("\"") ? "'" : "\""
                out += "![\(alt)](\(destination(src)) \(q)\(title)\(q))"
            } else {
                out += "![\(alt)](\(destination(src)))"
            }
        case "wikiLink":
            out += "[[\(node.type.spec.leafText?(node) ?? "")]]"
        case "footnoteReference":
            out += "[^\(node.attrs["label"]?.stringValue ?? "")]"
        case "inlineMath":
            // An empty formula has no spelling: "$$" opens display math, and no
            // dialect accepts "$$" as empty inline math. Emitting nothing beats
            // emitting a stray delimiter that swallows what follows.
            let latex = inlineMathSource(node.attrs["latex"]?.stringValue ?? "")
            if !latex.isEmpty { out += "$\(latex)$" }
        default:
            break
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
        var out = ""
        escapeInline(text, into: &out)
        return out
    }

    /// A backslash has to be escaped too, or it would escape whatever we add.
    private static func alwaysEscaped(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "\\"), UInt8(ascii: "`"), UInt8(ascii: "*"), UInt8(ascii: "_"),
             UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "$"), UInt8(ascii: "&"),
             UInt8(ascii: "<"): true
        default: false
        }
    }

    /// These only open markup when doubled (`==highlight==`, `~~strike~~`), so a
    /// lone one is left alone — "x = y" shouldn't grow a backslash.
    private static func escapedWhenDoubled(_ b: UInt8) -> Bool {
        b == UInt8(ascii: "=") || b == UInt8(ascii: "~")
    }

    /// Every character this looks for is ASCII, so it scans UTF-8 bytes: a
    /// multi-byte character's bytes are all above 0x7F and can never be mistaken
    /// for one, and the text never has to be broken into grapheme clusters —
    /// which is what a `Set<Character>` lookup per character was paying for.
    /// Text needing no escape at all, which is nearly all of it, is copied
    /// across whole.
    static func escapeInline(_ text: String, into out: inout String) {
        let utf8 = text.utf8
        var needsEscape = false
        for b in utf8 where alwaysEscaped(b) || escapedWhenDoubled(b) {
            needsEscape = true
            break
        }
        guard needsEscape else {
            out += text
            return
        }

        var escaped: [UInt8] = []
        escaped.reserveCapacity(utf8.count + 8)
        var previous: UInt8 = 0
        var i = utf8.startIndex
        while i < utf8.endIndex {
            let b = utf8[i]
            let next = utf8.index(after: i)
            let doubled = escapedWhenDoubled(b)
                && (previous == b || (next < utf8.endIndex && utf8[next] == b))
            if alwaysEscaped(b) || doubled { escaped.append(UInt8(ascii: "\\")) }
            escaped.append(b)
            previous = b
            i = next
        }
        out += String(decoding: escaped, as: UTF8.self)
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
        // The reader takes backslash escapes off a destination, so a backslash
        // that belongs to the URL has to be written as two.
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\")
        return escaped.contains(where: { $0 == " " || $0 == "(" || $0 == ")" })
            ? "<\(escaped)>" : escaped
    }

    /// A title, with the escapes the reader will resolve written out.
    /// An image's alt text sits between brackets, so its own brackets are
    /// escaped — otherwise the reader would close the label at the first one.
    static func altText(_ alt: String) -> String {
        var out = ""
        for c in alt {
            if c == "[" || c == "]" || c == "\\" { out.append("\\") }
            out.append(c)
        }
        return out
    }

    static func titleText(_ title: String) -> String {
        title.replacingOccurrences(of: "\\", with: "\\\\")
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
                result = "[\(result)](\(destination(href)) \(q)\(titleText(title))\(q))"
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

    /// The source nests blocks deeper than the parser will recurse.
    case nestingTooDeep(limit: Int)

    public var description: String {
        switch self {
        case let .invalidDocument(reason):
            return "MarkdownParseError: parsed content isn't a valid document — \(reason)"
        case let .nestingTooDeep(limit):
            return "MarkdownParseError: blocks nest deeper than \(limit)"
        }
    }
}

public enum MarkdownParser {
    /// How deep blocks may nest before the source is rejected.
    ///
    /// Every nested block — a quote inside a quote, a list inside a list item, a
    /// footnote's body — is a recursive call, and nothing about `> > > …` costs
    /// the writer anything, so a kilobyte of markers is enough to run the stack
    /// out and take the process down. That isn't recoverable: a stack overflow
    /// isn't a Swift error, so the `try?` at the paste site can't catch it.
    ///
    /// Lower than `HTMLParser.maxNestingDepth`, which caps the same class of
    /// input, because these frames are far bigger: the block parser carries a
    /// whole document's worth of locals, about 2.5 KB per level in release, so
    /// a limit of 256 still overflows the 512 KB a secondary thread gets by
    /// default. At 64 the deepest legal document needs ~160 KB, which clears
    /// every stack we parse on — and stays well above anything written on
    /// purpose, where even a long quoted mail thread stops around 20.
    public static let maxNestingDepth = 64

    public static func parse(_ markdown: String, schema: Schema) throws -> Node {
        try parse(markdown, schema: schema, depth: 0)
    }

    static func parse(_ markdown: String, schema: Schema, depth: Int) throws -> Node {
        // A reference can appear before the definition it uses, so definitions
        // are collected — and their lines removed — before anything is parsed.
        let expanded = markdown.components(separatedBy: "\n").map { expandLeadingTabs($0) }
        let (lines, definitions) = collectDefinitions(expanded)
        // A definition inside a quote still belongs to the document.
        let all = definitions.merging(collectNestedDefinitions(expanded)) { outer, _ in outer }
        return try parse(lines: lines, schema: schema, definitions: all, depth: depth)
    }

    /// Definitions found anywhere in a document, including inside quotes and
    /// list items — a reference resolves against every definition in the
    /// document, not only those at the top level.
    static func collectNestedDefinitions(_ lines: [String]) -> [String: LinkDefinition] {
        var found: [String: LinkDefinition] = [:]
        var quoted: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else {
                if !quoted.isEmpty {
                    for (key, value) in collectDefinitions(quoted).1 where found[key] == nil {
                        found[key] = value
                    }
                    quoted = []
                }
                continue
            }
            var inner = trimmed
            inner.removeFirst()
            if inner.hasPrefix(" ") { inner.removeFirst() }
            quoted.append(inner)
        }
        for (key, value) in collectDefinitions(quoted).1 where found[key] == nil {
            found[key] = value
        }
        return found
    }

    /// Parse a nested run of lines — a quote's body, a list item's content —
    /// with the definitions collected so far still in scope.
    static func parseNested(_ text: String, schema: Schema,
                            definitions: [String: LinkDefinition], depth: Int) throws -> Node {
        let (lines, local) = collectDefinitions(
            text.components(separatedBy: "\n").map { expandLeadingTabs($0) })
        // An outer definition wins, matching the first-one-wins rule.
        return try parse(lines: lines, schema: schema,
                         definitions: definitions.merging(local) { outer, _ in outer },
                         depth: depth)
    }

    static func parse(lines: [String], schema: Schema,
                      definitions: [String: LinkDefinition], depth: Int) throws -> Node {
        // Every route into a nested block — quotes, list items, footnotes,
        // details, figures — comes back through here, so one check covers all
        // of them.
        if depth > maxNestingDepth { throw MarkdownParseError.nestingTooDeep(limit: maxNestingDepth) }
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
                        // code follows it, so hold it until we know. Its own
                        // spaces past the fourth column are content.
                        blanks.append(String(l.dropFirst(min(4, l.count))))
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

            // Code fence: ``` or ~~~, closed by a run of the same character at
            // least as long, so a block fenced with four can hold a run of three
            // — of either character.
            if let fence = openingFence(line) {
                var code: [String] = []
                i += 1
                while i < lines.count, !closesFence(lines[i], fence) {
                    // An indented fence takes that indentation off its content.
                    code.append(String(lines[i].dropFirst(
                        min(fence.indent, indentWidth(lines[i])))))
                    i += 1
                }
                // An unclosed fence runs to the end of the document.
                if i < lines.count { i += 1 }
                let text = code.joined(separator: "\n")
                let content = text.isEmpty ? Fragment.empty : Fragment.from([schema.text(text)])
                var attrs: Attrs = [:]
                // The info string names the language, when the schema keeps one.
                if !fence.info.isEmpty,
                   schema.nodes["codeBlock"]?.spec.attrs["language"] != nil {
                    let language = fence.info.split(whereSeparator: { $0.isWhitespace }).first
                    if let language {
                        attrs["language"] = .string(resolveEscapes(String(language)))
                    }
                }
                if let cb = try? schema.node("codeBlock", attrs, content: content) { blocks.append(cb) }
                continue
            }
            // Figure fence: `^^^` opens a figure that runs to the closing `^^^`,
            // which may carry the caption. Only recognized when the schema has
            // the nodes, so `^^^` stays literal text everywhere else — the same
            // rule the math fences follow.
            if trimmed.hasPrefix("^^^"), schema.nodes["figure"] != nil {
                // Only a fence at least as long as the opening one closes it, so
                // a figure can hold a figure the way a code fence can hold a
                // code fence.
                let opening = trimmed.prefix { $0 == "^" }.count
                // Markdig accepts the caption on either fence; prefer the
                // closing one, which is what we write.
                var caption = String(trimmed.dropFirst(opening)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                func closesFigure(_ line: String) -> Bool {
                    line.trimmingCharacters(in: .whitespaces).prefix { $0 == "^" }.count >= opening
                }
                while i < lines.count, !closesFigure(lines[i]) {
                    body.append(lines[i])
                    i += 1
                }
                if i < lines.count {
                    let closing = lines[i].trimmingCharacters(in: .whitespaces)
                    let trailing = String(closing.drop { $0 == "^" }).trimmingCharacters(in: .whitespaces)
                    if !trailing.isEmpty { caption = trailing }
                    i += 1  // consume the closing fence
                }
                if let figure = makeFigure(body, caption: caption, schema: schema, depth: depth + 1) {
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
                if let section = try makeDetails(inner, open: open, schema: schema, depth: depth + 1) {
                    blocks.append(contentsOf: section)
                }
                continue
            }
            // A footnote's note: `[^label]:` and everything that belongs to it —
            // the rest of that line, the blocks indented four columns under it,
            // and a plain line straight after, which continues its paragraph the
            // way a lazy line continues a quote's.
            if let head = footnoteHead(trimmed), schema.nodes["footnoteDefinition"] != nil {
                var body = [head.rest]
                i += 1
                while i < lines.count {
                    let raw = lines[i]
                    let t = raw.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {
                        // A blank line belongs to the note only if indented
                        // content follows it.
                        var j = i + 1
                        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                        guard j < lines.count, indentWidth(lines[j]) >= 4 else { break }
                        body.append(contentsOf: repeatElement("", count: j - i))
                        i = j
                        continue
                    }
                    if indentWidth(raw) >= 4 { body.append(String(raw.dropFirst(4))); i += 1; continue }
                    guard body.last?.isEmpty == false, !startsBlock(t), footnoteHead(t) == nil
                    else { break }
                    body.append(t); i += 1
                }
                let inner = try parseNested(body.joined(separator: "\n"), schema: schema,
                                            definitions: definitions, depth: depth + 1)
                var content = (0..<inner.childCount).map { inner.child($0) }
                // A note with nothing in it is still a note; `block+` needs a
                // block to hold, so it gets the empty paragraph it would have
                // been typed into.
                if content.isEmpty, let empty = try? schema.node("paragraph") { content = [empty] }
                if let definition = try? schema.node("footnoteDefinition",
                                                     ["label": .string(head.label)],
                                                     content: Fragment.from(content)) {
                    blocks.append(definition)
                    continue
                }
            }
            // A `<table>` HTML block — what the serializer writes for a table
            // the pipes can't hold, and what a document pasted from the web
            // carries. Handed to the HTML parser, which already builds the
            // whole grid, spans and all.
            if trimmed.lowercased().hasPrefix("<table"), schema.nodes["table"] != nil {
                var html: [String] = []
                while i < lines.count {
                    html.append(lines[i])
                    let closed = lines[i].lowercased().contains("</table>")
                    i += 1
                    if closed { break }
                }
                if let parsed = try? HTMLParser.parse(html.joined(separator: "\n"), schema: schema) {
                    blocks.append(contentsOf: (0..<parsed.childCount).map { parsed.child($0) })
                }
                continue
            }
            // A GitHub pipe table: a header row, the delimiter row under it,
            // then a body that runs to the first blank line or new block.
            if startsPipeTable(lines, i, schema) {
                let header = pipeCells(lines[i])
                let alignments = pipeAlignments(lines[i + 1], columns: header.count) ?? []
                var rows: [[String]] = [header]
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|"), !startsBlock(t) else { break }
                    // A short row is padded and a long one truncated, which is
                    // what the header row promised the width would be.
                    var cells = pipeCells(t)
                    if cells.count > header.count { cells = Array(cells.prefix(header.count)) }
                    while cells.count < header.count { cells.append("") }
                    rows.append(cells)
                    i += 1
                }
                if let table = makePipeTable(rows, alignments: alignments, schema: schema,
                                             definitions: definitions) {
                    blocks.append(table)
                    continue
                }
                // Without the nodes to build it, the lines are ordinary text;
                // fall through so they parse as the paragraph they look like.
                i -= rows.count + 1
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
                        // Indented content inside the quote is code, which
                        // leaves no paragraph for a later line to continue. A
                        // nested quote may leave one open inside itself, and
                        // only its own parse knows — so let the line through and
                        // let the recursion decide.
                        inParagraph = !inner.isEmpty && indentWidth(l) < 4
                            && (inner.hasPrefix(">") || !startsBlock(inner))
                        i += 1
                        continue
                    }
                    // Lazy continuation: a line without the marker continues a
                    // paragraph inside the quote, but can't start a block there
                    // — "> foo\n- bar" is a quote followed by a list.
                    // A run of "=" only ever underlines a heading, and it can't
                    // do that across the quote's edge — so it continues the
                    // paragraph as text. A run of "-" is also a thematic break,
                    // which does end the quote.
                    let underlineOnly = setextUnderline(t) == 1
                    if inParagraph, !t.isEmpty,
                       indentWidth(lines[i]) >= 4 || underlineOnly || !startsBlock(t) {
                        // Escaped, because a lazy line only ever continues a
                        // paragraph — the quote's own parse would otherwise read
                        // the run as underlining a heading.
                        if underlineOnly {
                            quote.append("\\" + t); i += 1; continue
                        }
                        // Keep the indentation: it is what stops the line from
                        // starting a block when the quote's contents are parsed.
                        quote.append(lines[i])
                        i += 1
                        continue
                    }
                    break
                }
                let inner = try parseNested(quote.joined(separator: "\n"), schema: schema, definitions: definitions,
                                            depth: depth + 1)
                if let bq = try? schema.node("blockquote", [:], content: inner.content) { blocks.append(bq) }
                continue
            }
            // Lists
            if let bullet = bulletMatch(trimmed) {
                let (items, next, tight) = collectList(lines, i, ordered: false)
                if let list = try makeTaskList(items, schema: schema, depth: depth + 1)
                    ?? makeList(items, ordered: false, schema: schema, tight: tight, depth: depth + 1) {
                    blocks.append(list)
                }
                i = next
                _ = bullet
                continue
            }
            if let ordered = orderedMatch(trimmed) {
                let (items, next, tight) = collectList(lines, i, ordered: true)
                if let list = try makeList(items, ordered: true, schema: schema,
                                       start: ordered, tight: tight, depth: depth + 1) {
                    blocks.append(list)
                }
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
                // Four columns in would be code, and code can't interrupt a
                // paragraph — so an indented line continues this one, whatever
                // it would otherwise start.
                if t.isEmpty || (indentWidth(lines[i]) < 4 && startsBlock(t)) { break }
                // A header row and the delimiter under it end the paragraph:
                // the table starts here, as it does on GitHub.
                if startsPipeTable(lines, i, schema) { break }
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
    private static func makeDetails(_ lines: [String], open: Bool, schema: Schema, depth: Int) throws -> [Node]? {
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
        let bodyDoc = try parse(body.joined(separator: "\n"), schema: schema, depth: depth)
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
        // One pass for both the run and the character after it. Reading that
        // character used to be `Array(line)[level]`, which built an array of
        // the whole line to look at one position of it — on every line of the
        // document, whether or not it began with a hash.
        var level = 0
        var afterRun: Character?
        for c in line {
            if c == "#" { level += 1 } else { afterRun = c; break }
        }
        // A hash run alone is an empty heading; otherwise a space has to follow
        // it, or "#foo" would be one.
        guard level >= 1, level <= 6,
              afterRun == nil || afterRun == " " || afterRun == "\t" else { return nil }
        // `dropFirst` already clamps, so the old `min(level + 1, line.count)`
        // only bought another walk of the line.
        var text = String(line.dropFirst(level + 1))
            .trimmingCharacters(in: .whitespaces)
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
    ///
    /// `startColumn` is the column the text begins at, for callers passing the
    /// remainder of a line rather than a whole one. A tab stop is a position on
    /// the *line*, so expanding what follows a list marker as if it started at
    /// column zero puts the stops in the wrong place: in `-\t\tfoo` the first
    /// tab advances to column 4, not to column 4 past the marker.
    static func expandLeadingTabs(_ line: String, startColumn: Int = 0) -> String {
        guard let first = line.first, first == " " || first == "\t" else { return line }
        var column = startColumn
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == " " { column += 1 }
            else if line[i] == "\t" { column += 4 - (column % 4) }
            else { break }
            i = line.index(after: i)
        }
        return String(repeating: " ", count: column - startColumn) + line[i...]
    }

    /// Whether a line opens a fenced code block.
    ///
    /// A backtick fence's info string may not itself contain a backtick — which
    /// is what keeps a line like ``` `` ``` ``` (an inline code span holding a
    /// backtick, written with a longer fence) from being read as a code block.
    /// An opening code fence: which character, how long, how far indented, and
    /// the info string after it.
    struct CodeFence {
        let character: Character
        let length: Int
        let indent: Int
        let info: String
    }

    /// The fence a line opens, if it opens one. Indented four columns it would
    /// be code, and a backtick fence's info string may not contain a backtick.
    static func openingFence(_ line: String) -> CodeFence? {
        let indent = indentWidth(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let length = rest.prefix(while: { $0 == character }).count
        guard length >= 3 else { return nil }
        let info = String(rest.dropFirst(length)).trimmingCharacters(in: .whitespaces)
        if character == "`", info.contains("`") { return nil }
        return CodeFence(character: character, length: length, indent: indent, info: info)
    }

    /// Whether a line closes the given fence: the same character, at least as
    /// long, and nothing else on the line — a closing fence carries no info
    /// string, which is what lets a block hold a shorter run of its own fence.
    static func closesFence(_ line: String, _ fence: CodeFence) -> Bool {
        guard indentWidth(line) <= 3 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.length && trimmed.allSatisfy { $0 == fence.character }
    }

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
            // Four columns in is code, and a definition has to begin a block —
            // "Foo\n[bar]: /baz" is a paragraph that happens to contain
            // brackets, and reading it as a definition would make the line
            // disappear from the document.
            // A definition can't interrupt a paragraph, but it may follow any
            // other block — a heading, say — so what matters is whether the
            // line before it was paragraph text rather than whether it was
            // blank.
            let previous = remaining.last?.trimmingCharacters(in: .whitespaces) ?? ""
            let startsABlock = previous.isEmpty || startsBlock(previous)
            // The label itself may run across lines, so join until it closes.
            let labelExtra = (indentWidth(line) < 4 && startsABlock)
                ? labelLines(lines, from: i) : nil
            let head = labelExtra.map { extra -> String in
                guard extra > 0 else { return line }
                return ([line] + lines[(i + 1)...(i + extra)]
                    .map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")
            }
            guard let head, let (label, rest) = parseDefinitionHead(head),
                  // `[^1]: …` is a footnote, not a link: the labels share a
                  // syntax, and taking this one would delete the note from the
                  // document before the block parser ever saw it.
                  !label.hasPrefix("^") else {
                remaining.append(line); i += 1; continue
            }
            let labelConsumed = labelExtra ?? 0
            // The destination may sit on the line below the label, and a title
            // below that, so the body is scanned across the following lines
            // rather than assumed to be on this one. A blank line ends it.
            var following: [String] = []
            var j = i + 1 + labelConsumed
            while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                following.append(lines[j])
                j += 1
            }
            guard let body = parseDefinitionBody(([rest] + following).joined(separator: "\n")) else {
                remaining.append(line); i += 1; continue
            }
            let key = normalizeLabel(label)
            // The first definition of a label wins, as in CommonMark.
            if definitions[key] == nil {
                definitions[key] = LinkDefinition(destination: body.destination, title: body.title)
            }
            // Whatever the definition didn't consume is content again.
            let consumed = 1 + labelConsumed + body.lines
            i += consumed
        }
        return (remaining, definitions)
    }

    /// A destination, title or info string as written: character references
    /// resolved, and backslash escapes taken off. Both are text there, not
    /// markup, so `/bar\*` is a path containing an asterisk.
    static func resolveEscapes(_ s: String) -> String {
        unescapeInline(HTMLParser.decodeEntities(s, cappingNumericDigits: true))
    }

    /// A definition's destination and optional title, and how many *extra* lines
    /// they took beyond the one carrying the label.
    ///
    /// Both may sit on lines of their own, and a title may run across lines —
    /// but not across a blank one. A title that doesn't parse doesn't spoil the
    /// definition: the destination stands and the rest goes back to being text,
    /// which is why the two are reported separately.
    static func parseDefinitionBody(_ text: String)
        -> (destination: String, title: String?, lines: Int)? {
        let chars = Array(text)
        var i = 0
        var newlines = 0
        // Whitespace between the parts may include a single line ending.
        func skipSpace() {
            var seenNewline = false
            while i < chars.count {
                if chars[i] == " " || chars[i] == "\t" { i += 1 }
                else if chars[i] == "\n", !seenNewline { seenNewline = true; newlines += 1; i += 1 }
                else { break }
            }
        }
        skipSpace()
        guard i < chars.count else { return nil }

        var destination = ""
        if chars[i] == "<" {
            var j = i + 1
            while j < chars.count, chars[j] != ">", chars[j] != "\n" { j += 1 }
            guard j < chars.count, chars[j] == ">" else { return nil }
            destination = String(chars[(i + 1)..<j])
            i = j + 1
        } else {
            while i < chars.count, !chars[i].isWhitespace { destination.append(chars[i]); i += 1 }
        }
        guard !destination.isEmpty else { return nil }
        // Nothing but space may follow the destination on its line, or this is
        // an ordinary paragraph that happens to look like a definition.
        var afterDestination = i
        while afterDestination < chars.count,
              chars[afterDestination] == " " || chars[afterDestination] == "\t" {
            afterDestination += 1
        }
        let destinationEndsLine = afterDestination >= chars.count || chars[afterDestination] == "\n"
        let withoutTitle = destinationEndsLine
            ? (resolveEscapes(destination), String?.none, newlines)
            : nil

        let beforeGap = i
        skipSpace()
        // Whitespace has to separate the destination from a title, or
        // `[foo]: <bar>(baz)` would read as one.
        guard i > beforeGap, i < chars.count,
              chars[i] == "\"" || chars[i] == "'" || chars[i] == "(" else {
            return withoutTitle
        }
        let closing: Character = chars[i] == "(" ? ")" : chars[i]
        var title = ""
        var titleNewlines = 0
        var j = i + 1
        while j < chars.count, chars[j] != closing {
            // A backslash escapes what follows, so an escaped quote doesn't
            // close the title.
            if chars[j] == "\\", j + 1 < chars.count {
                title.append(chars[j]); title.append(chars[j + 1]); j += 2; continue
            }
            // A blank line ends the title, which means there wasn't one.
            if chars[j] == "\n" {
                if j + 1 < chars.count, chars[j + 1] == "\n" { return withoutTitle }
                titleNewlines += 1
            }
            title.append(chars[j])
            j += 1
        }
        guard j < chars.count else { return withoutTitle }
        // Nothing but space may follow the closing quote on its line.
        var k = j + 1
        while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
        guard k >= chars.count || chars[k] == "\n" else { return withoutTitle }
        return (resolveEscapes(destination), resolveEscapes(title), newlines + titleNewlines)
    }

    /// `[label]:` at the head of a line, returning the label and what follows.
    /// How many extra lines a definition's label needs, when it runs across
    /// them: `[\nfoo\n]: /url` is a label of "foo". Nil when the label never
    /// closes, which means this isn't a definition.
    static func labelLines(_ lines: [String], from start: Int) -> Int? {
        guard lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("[") else { return nil }
        var joined = lines[start]
        var extra = 0
        while parseDefinitionHead(joined) == nil, start + extra + 1 < lines.count, extra < 8 {
            let next = lines[start + extra + 1]
            if next.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            joined += " " + next.trimmingCharacters(in: .whitespaces)
            extra += 1
        }
        return parseDefinitionHead(joined) == nil ? nil : extra
    }

    private static func parseDefinitionHead(_ line: String) -> (label: String, rest: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[") else { return nil }
        let bytes = Array(t.utf8)
        guard let close = findUnescaped(bytes, 1, UInt8(ascii: "]")), close > 1,
              close + 1 < bytes.count, bytes[close + 1] == UInt8(ascii: ":") else { return nil }
        let label = slice(bytes, 1..<close)
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // An unescaped bracket can't appear in a label, so this isn't one.
        guard findUnescaped(Array(label.utf8), 0, UInt8(ascii: "[")) == nil else { return nil }
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
        startsAnyBlock(trimmed, listsMayInterrupt: false)
    }

    /// Build the table: the first row's cells are headers, the rest are not.
    private static func makePipeTable(_ rows: [[String]], alignments: [String?],
                                      schema: Schema,
                                      definitions: [String: LinkDefinition]) -> Node? {
        var rowNodes: [Node] = []
        for (index, cells) in rows.enumerated() {
            let cellType = index == 0 ? "tableHeader" : "tableCell"
            var cellNodes: [Node] = []
            for (column, text) in cells.enumerated() {
                let inline = parseInline(text, schema, definitions)
                // The delimiter row speaks for the whole column, so every cell
                // in it carries the alignment — that is what makes it survive
                // being written back out.
                var attrs: Attrs = [:]
                if column < alignments.count, let align = alignments[column] {
                    attrs["align"] = .string(align)
                }
                guard let paragraph = try? schema.node("paragraph", [:], content: Fragment.from(inline)),
                      let cell = try? schema.node(cellType, attrs, content: Fragment.from([paragraph]))
                else { return nil }
                cellNodes.append(cell)
            }
            guard let row = try? schema.node("tableRow", [:], content: Fragment.from(cellNodes))
            else { return nil }
            rowNodes.append(row)
        }
        return try? schema.node("table", [:], content: Fragment.from(rowNodes))
    }

    /// A pipe-table row's cells, split on the "|" that aren't escaped.
    ///
    /// The outer pipes are optional in GitHub's tables, so one at either end is
    /// the row's edge rather than an empty cell. A "\|" stays as written: the
    /// inline parser resolves the escape, the same as anywhere else.
    static func pipeCells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        // Only an unescaped pipe closes the row.
        if body.hasSuffix("|"), !body.dropLast().hasSuffix("\\") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for c in body {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { current.append(c); escaped = true; continue }
            if c == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(c)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The alignments in the `| --- | :---: |` row under a table's header, or
    /// nil when the line isn't one — including when its width disagrees with
    /// the header's, which GitHub requires it to match.
    ///
    /// A colon on the left is "left", on both "center", on the right "right",
    /// and neither is nil: `---` and `:---` render differently, so the absence
    /// of a colon is worth keeping rather than folding into "left".
    static func pipeAlignments(_ line: String, columns: Int) -> [String?]? {
        let cells = pipeCells(line)
        guard cells.count == columns, !cells.isEmpty else { return nil }
        var alignments: [String?] = []
        for cell in cells {
            var body = Substring(cell)
            let left = body.hasPrefix(":")
            if left { body = body.dropFirst() }
            let right = body.hasSuffix(":")
            if right { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? "center" : left ? "left" : right ? "right" : nil)
        }
        return alignments
    }

    static func isPipeDelimiterRow(_ line: String, columns: Int) -> Bool {
        pipeAlignments(line, columns: columns) != nil
    }

    /// Whether a table starts here: a row of cells, then a delimiter row of the
    /// same width. Both lines are needed, which is why this takes the lookahead
    /// rather than a single line the way the other block tests do.
    static func startsPipeTable(_ lines: [String], _ i: Int, _ schema: Schema) -> Bool {
        guard schema.nodes["table"] != nil, schema.nodes["tableRow"] != nil,
              schema.nodes["tableCell"] != nil, schema.nodes["tableHeader"] != nil,
              i + 1 < lines.count else { return false }
        // Asked of every line in the document, and answered "no" for almost all
        // of them, so the order of these two checks is most of the cost of
        // parsing prose. A pipe can't be introduced or removed by trimming, so
        // scan the raw line's bytes: `contains("|")` on a `String` resolves to
        // Foundation's generic substring search, which was a quarter of the
        // time spent parsing a document that contains hardly any tables.
        guard lines[i].utf8.contains(UInt8(ascii: "|")), indentWidth(lines[i]) < 4 else { return false }
        let header = lines[i].trimmingCharacters(in: .whitespaces)
        return isPipeDelimiterRow(lines[i + 1], columns: pipeCells(header).count)
    }

    /// Whether a line begins a block, asked without a paragraph above it to
    /// protect — which is the question an item's own content asks. "2. foo" is
    /// a list here even though it couldn't have interrupted a paragraph.
    private static func startsAnyBlock(_ trimmed: String) -> Bool {
        startsAnyBlock(trimmed, listsMayInterrupt: true)
    }

    private static func startsAnyBlock(_ trimmed: String, listsMayInterrupt: Bool) -> Bool {
        let list = listsMayInterrupt
            ? (bulletMatch(trimmed) != nil || orderedMatch(trimmed) != nil)
            : interruptingList(trimmed)
        return trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || isOpeningFence(trimmed)
            || trimmed.hasPrefix("$$") || isThematicBreak(trimmed)
            || setextUnderline(trimmed) != nil
            || list
            || trimmed.lowercased().hasPrefix("<details")
            || trimmed.lowercased().hasPrefix("</details>")
            || trimmed.lowercased().hasPrefix("<table")
            || footnoteHead(trimmed) != nil
    }

    /// Whether a list marker here would end the paragraph above it. Two markers
    /// that start a list at the top of a document can't interrupt one: an
    /// ordered list has to be numbered 1, so a sentence ending "…is\n14. The
    /// number…" stays one paragraph, and an empty item never interrupts, so a
    /// lone "*" under a line of prose is part of it.
    private static func interruptingList(_ trimmed: String) -> Bool {
        if let content = bulletMatch(trimmed) { return !content.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let number = orderedMatch(trimmed) else { return false }
        let content = listMarker(trimmed, ordered: true)?.content ?? ""
        return number == 1 && !content.trimmingCharacters(in: .whitespaces).isEmpty
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

    /// A list marker at the head of a line: the content that follows it, and how
    /// many columns the marker and its spaces occupy.
    ///
    /// That width is the item's content column — where its continuation lines
    /// have to be indented to — so it has to count the spaces actually written,
    /// not assume one. `1.  foo` puts content at column 4, and treating it as 3
    /// left every continuation line one space too deep, which turned indented
    /// code inside the item into code with a stray leading space.
    ///
    /// Five or more spaces would make the content indented code, so in that case
    /// the content column is one past the marker and the rest stays as content.
    /// `startColumn` is the column `line` begins at, so that a tab after the
    /// marker lands on the right stop for an item that is itself indented.
    static func listMarker(_ line: String, ordered: Bool, startColumn: Int = 0)
        -> (content: String, width: Int)? {
        let markerLength: Int
        if ordered {
            // More than nine digits isn't a list marker — "1234567890. x" is a
            // paragraph that happens to begin with a number.
            let digits = line.prefix(while: { $0.isNumber }).count
            let after = line.dropFirst(digits)
            guard digits > 0, digits <= 9,
                  after.first == "." || after.first == ")" else { return nil }
            markerLength = digits + 1
        } else {
            guard let first = line.first, first == "-" || first == "*" || first == "+" else { return nil }
            markerLength = 1
        }
        let rest = expandLeadingTabs(String(line.dropFirst(markerLength)),
                                     startColumn: startColumn + markerLength)
        guard rest.isEmpty || rest.first == " " else { return nil }
        let spaces = rest.prefix(while: { $0 == " " }).count
        let padding = (spaces == 0 || spaces > 4) ? 1 : spaces
        return (String(rest.dropFirst(min(padding, spaces))), markerLength + padding)
    }

    private static func bulletMatch(_ line: String) -> String? {
        // A tab after the marker separates it from the content, as a space does,
        // and a marker alone on its line is an empty item.
        for marker in ["-", "*", "+"] where line.hasPrefix(marker) {
            let rest = line.dropFirst()
            guard let next = rest.first else { return "" }
            guard next == " " || next == "\t" else { continue }
            return expandLeadingTabs(String(rest.dropFirst()))
        }
        return nil
    }

    private static func orderedMatch(_ line: String) -> Int? {
        var digits = ""
        for c in line { if c.isNumber { digits.append(c) } else { break } }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = line.dropFirst(digits.count)
        // Either delimiter starts a list: "1." and "1)" are both markers.
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        let after = rest.dropFirst()
        guard after.isEmpty || after.hasPrefix(" ") || after.hasPrefix("\t") else { return nil }
        return Int(digits)
    }

    /// Gather a list's items, each as its own lines. An item owns the lines
    /// below it that are indented to its content column — CommonMark's "W + N"
    /// rule — so a formula or code fence written under a bullet stays part of
    /// that bullet instead of ending the list.
    private static func collectList(_ lines: [String], _ start: Int,
                                    ordered: Bool) -> (items: [[String]], next: Int, tight: Bool) {
        var items: [[String]] = []
        // A blank line anywhere inside the list makes it loose, whether it
        // separates two items or two blocks within one.
        var tight = true
        // The marker the list opened with. Changing it — "-" to "+", or "1." to
        // "1)" — starts a separate list rather than adding to this one.
        var delimiter: Character?
        func markerDelimiter(_ t: String) -> Character? {
            if ordered { return t.drop(while: { $0.isNumber }).first }
            return t.first
        }
        var indents: [Int] = []
        var i = start
        func isItem(_ t: String) -> Bool {
            // "* * *" is a thematic break, which wins over the list marker it
            // starts with — the same precedence the top-level scan applies.
            guard !isThematicBreak(t) else { return false }
            guard ordered ? orderedMatch(t) != nil : bulletMatch(t) != nil else { return false }
            // A different marker belongs to the next list, so the blank line
            // before it ends this one rather than making it loose.
            return delimiter == nil || markerDelimiter(t) == delimiter
        }
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
                    // Every blank line, not one standing for the run: inside an
                    // item's code block they are content, and collapsing them
                    // rewrote the code. Between two blocks any number reads the
                    // same, so keeping them costs nothing there.
                    items[items.count - 1].append(contentsOf: repeatElement("", count: j - i))
                    tight = false
                    i = j
                    continue
                }
                if isItem(lines[j].trimmingCharacters(in: .whitespaces)) {
                    tight = false
                    i = j
                    continue
                }
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
            if !isThematicBreak(t), let marker = listMarker(t, ordered: ordered,
                                                            startColumn: indentWidth(raw)) {
                let here = markerDelimiter(t)
                if let delimiter, here != delimiter { break }
                delimiter = here
                items.append([marker.content])
                // The content column is where the text after the marker starts,
                // so an item that is itself indented carries that indent.
                indents.append(indentWidth(raw) + marker.width)
                i += 1
                continue
            }
            break
        }
        return (items, i, tight)
    }

    /// Build a `figure` from a fence's body lines and caption. Returns nil if the
    /// schema can't hold one, so the caller leaves the text alone.
    private static func makeFigure(_ body: [String], caption: String, schema: Schema, depth: Int) -> Node? {
        guard let figureType = schema.nodes["figure"] else { return nil }
        let inner = (try? parse(body.joined(separator: "\n"), schema: schema, depth: depth))?.content
        var children = inner.map { frag in (0..<frag.childCount).map { frag.child($0) } } ?? []
        if !caption.isEmpty, let captionType = schema.nodes["figcaption"],
           let node = try? captionType.create([:], content: Fragment.from(parseInline(caption, schema))) {
            children.append(node)
        }
        let fitted = fitContent(children, into: figureType, schema: schema)
        if let figure = try? figureType.create([:], content: Fragment.from(fitted)) { return figure }
        return figureType.createAndFill([:], content: Fragment.from(fitted))
    }

    /// A footnote's opening: `[^label]:` and the rest of that line.
    ///
    /// A label may not contain whitespace, which keeps it apart from a link
    /// definition's label and matches how footnotes are written in practice.
    static func footnoteHead(_ line: String) -> (label: String, rest: String)? {
        guard line.hasPrefix("[^") else { return nil }
        let afterBracket = line.dropFirst(2)
        guard let close = afterBracket.firstIndex(of: "]") else { return nil }
        let label = String(afterBracket[afterBracket.startIndex..<close])
        guard !label.isEmpty, !label.contains(where: { $0.isWhitespace }) else { return nil }
        var rest = afterBracket[afterBracket.index(after: close)...]
        guard rest.hasPrefix(":") else { return nil }
        rest = rest.dropFirst()
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return (label, String(rest))
    }

    /// A checkbox at the head of a list item, as GitHub writes them. Returns the
    /// checked state and the rest of the line.
    ///
    /// The box has to be followed by whitespace, or end the line. Without that
    /// rule `- [x]foo` read as a checked item holding "foo" — and writing it
    /// back put in a space the author never typed, so the text came out
    /// different from how it went in. GitHub requires the whitespace and treats
    /// anything else as an ordinary item whose text begins with a bracket.
    ///
    /// Ending the line is allowed because that is how an empty item is written,
    /// which is what Markdig accepts. GitHub asks for whitespace there too, so
    /// `- [x]` alone is a checkbox here and a literal bracket there.
    private static func taskMarker(_ line: String) -> (checked: Bool, rest: String)? {
        let boxes: [(String, Bool)] = [("[ ]", false), ("[x]", true), ("[X]", true)]
        for (box, checked) in boxes where line.hasPrefix(box) {
            let rest = line.dropFirst(box.count)
            guard let next = rest.first else { return (checked, "") }
            guard next == " " || next == "\t" else { return nil }
            return (checked, String(rest.dropFirst()))
        }
        return nil
    }

    /// Build a `taskList` when every item carries a checkbox and the schema has
    /// the nodes; otherwise nil, so the caller falls back to a plain list and the
    /// brackets stay literal text.
    private static func makeTaskList(_ items: [[String]], schema: Schema, depth: Int) throws -> Node? {
        guard let listType = schema.nodes["taskList"], let itemType = schema.nodes["taskItem"],
              !items.isEmpty, items.allSatisfy({ taskMarker($0.first ?? "") != nil }) else { return nil }
        var itemNodes: [Node] = []
        for var lines in items {
            guard let marker = taskMarker(lines[0]) else { return nil }
            lines[0] = marker.rest
            let content = fitContent(try itemBlocks(lines, schema: schema, depth: depth), into: itemType, schema: schema)
            guard let item = try? itemType.create(["checked": .bool(marker.checked)],
                                                  content: Fragment.from(content)) else { return nil }
            itemNodes.append(item)
        }
        return try? listType.create([:], content: Fragment.from(itemNodes))
    }

    /// The blocks of one list item. An item that carried continuation lines is
    /// parsed as a document, the way a blockquote's contents are.
    private static func itemBlocks(_ lines: [String], schema: Schema, depth: Int) throws -> [Node] {
        // Indented content is a block even on its own line: a marker followed by
        // five or more spaces leaves the content four columns in, which is code.
        if lines.count > 1 || indentWidth(lines[0]) >= 4
            || startsAnyBlock(lines[0].trimmingCharacters(in: .whitespaces)) {
            let inner = try parse(lines.joined(separator: "\n"), schema: schema, depth: depth).content
            return (0..<inner.childCount).map { inner.child($0) }
        }
        // A list item holds blocks, so a block-level image in its text becomes a
        // sibling block rather than an invalid child of the paragraph.
        // `fitContent` then puts the item's content in order.
        let inline = parseInline(lines[0], schema)
        return textblockSplittingBlocks(inline) {
            try? schema.node("paragraph", [:], content: Fragment.from($0))
        }
    }

    private static func makeList(_ items: [[String]], ordered: Bool, schema: Schema,
                                 start: Int = 1, tight: Bool = false, depth: Int) throws -> Node? {
        guard let itemType = schema.nodes["listItem"] else { return nil }
        var itemNodes: [Node] = []
        for lines in items {
            // `itemBlocks` decides whether the content is inline or its own
            // blocks; this used to repeat that test and so never saw the
            // indented single-line case.
            let content = fitContent(try itemBlocks(lines, schema: schema, depth: depth), into: itemType, schema: schema)
            guard let item = try? itemType.create([:], content: Fragment.from(content)) else { continue }
            itemNodes.append(item)
        }
        let listName = ordered ? "orderedList" : "bulletList"
        var attrs: Attrs = ordered ? ["order": .int(start)] : [:]
        if schema.nodes[listName]?.spec.attrs["tight"] != nil { attrs["tight"] = .bool(tight) }
        return try? schema.node(listName, attrs, content: Fragment.from(itemNodes))
    }

    // Inline parser: handles **bold**, *italic*/_italic_, `code`, ~~strike~~,
    // ==highlight==, [text](url), ![alt](src), and [[wiki|link]].

    /// An HTML tag as the inline scanner sees it.
    private struct InlineTag {
        let name: String
        let attrs: [String: String]
        let isClosing: Bool
        let selfClosing: Bool
        /// One past the tag's ">".
        let end: Int
    }

    /// Recognize an HTML tag, comment or declaration at `start`. Returns nil for
    /// anything that isn't one, so "a < b" stays text.
    private static func inlineTag(_ bytes: [UInt8], _ start: Int) -> InlineTag? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "<") else { return nil }
        var i = start + 1
        // Comments, declarations, processing instructions and CDATA carry no
        // content we can keep, so they're reported as a nameless tag to skip.
        func skipped(_ terminator: [UInt8]) -> InlineTag? {
            guard let close = findSeq(bytes, i, terminator) else { return nil }
            return InlineTag(name: "", attrs: [:], isClosing: false, selfClosing: true,
                             end: close + terminator.count)
        }
        if matches(bytes, i, "!--") { i += 3; return skipped(Array("-->".utf8)) }
        if matches(bytes, i, "![CDATA[") { i += 8; return skipped(Array("]]>".utf8)) }
        if i < bytes.count, bytes[i] == UInt8(ascii: "!") || bytes[i] == UInt8(ascii: "?") {
            i += 1; return skipped(Array(">".utf8))
        }
        var isClosing = false
        if i < bytes.count, bytes[i] == UInt8(ascii: "/") { isClosing = true; i += 1 }
        // A tag name is a letter followed by letters, digits or hyphens.
        let nameStart = i
        guard i < bytes.count, isASCIILetter(bytes[i]) else { return nil }
        while i < bytes.count, isASCIILetter(bytes[i]) || isASCIIDigit(bytes[i])
            || bytes[i] == UInt8(ascii: "-") { i += 1 }
        let name = slice(bytes, nameStart..<i).lowercased()

        var attrs: [String: String] = [:]
        while i < bytes.count {
            while i < bytes.count, isHTMLSpace(bytes[i]) { i += 1 }
            guard i < bytes.count else { return nil }
            if bytes[i] == UInt8(ascii: ">") { return InlineTag(name: name, attrs: attrs,
                                                               isClosing: isClosing,
                                                               selfClosing: false, end: i + 1) }
            if bytes[i] == UInt8(ascii: "/"), i + 1 < bytes.count,
               bytes[i + 1] == UInt8(ascii: ">") {
                return InlineTag(name: name, attrs: attrs, isClosing: isClosing,
                                 selfClosing: true, end: i + 2)
            }
            // An attribute name, optionally followed by a value.
            let attrStart = i
            guard isASCIILetter(bytes[i]) || bytes[i] == UInt8(ascii: "_")
                || bytes[i] == UInt8(ascii: ":") else { return nil }
            while i < bytes.count, !isHTMLSpace(bytes[i]), bytes[i] != UInt8(ascii: "="),
                  bytes[i] != UInt8(ascii: ">"), bytes[i] != UInt8(ascii: "/") { i += 1 }
            let attrName = slice(bytes, attrStart..<i).lowercased()
            while i < bytes.count, isHTMLSpace(bytes[i]) { i += 1 }
            guard i < bytes.count, bytes[i] == UInt8(ascii: "=") else { attrs[attrName] = ""; continue }
            i += 1
            while i < bytes.count, isHTMLSpace(bytes[i]) { i += 1 }
            guard i < bytes.count else { return nil }
            if bytes[i] == UInt8(ascii: "\"") || bytes[i] == UInt8(ascii: "'") {
                let quote = bytes[i]
                guard let close = findByte(bytes, i + 1, quote) else { return nil }
                attrs[attrName] = HTMLParser.decodeEntities(slice(bytes, (i + 1)..<close))
                i = close + 1
            } else {
                let from = i
                while i < bytes.count, !isHTMLSpace(bytes[i]), bytes[i] != UInt8(ascii: ">") { i += 1 }
                attrs[attrName] = HTMLParser.decodeEntities(slice(bytes, from..<i))
            }
        }
        return nil
    }

    private static func isASCIILetter(_ b: UInt8) -> Bool { (b | 0x20) >= 97 && (b | 0x20) <= 122 }
    private static func isASCIIDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
    private static func isHTMLSpace(_ b: UInt8) -> Bool {
        b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") || b == UInt8(ascii: "\n")
            || b == UInt8(ascii: "\r")
    }
    private static func matches(_ bytes: [UInt8], _ at: Int, _ text: String) -> Bool {
        let want = Array(text.utf8)
        guard at + want.count <= bytes.count else { return false }
        return Array(bytes[at..<(at + want.count)]) == want
    }

    /// The index of the `</name>` closing `openAt`, counting nested opens of the
    /// same name so `<b>a<b>c</b>d</b>` closes at the outer one.
    private static func closingTag(_ bytes: [UInt8], _ from: Int, _ name: String) -> InlineTag? {
        var depth = 1
        var i = from
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<"), let tag = inlineTag(bytes, i) else { i += 1; continue }
            if tag.name == name, !tag.selfClosing {
                depth += tag.isClosing ? -1 : 1
                if depth == 0 { return tag }
            }
            i = tag.end
        }
        return nil
    }

    /// The words a label renders to, which is what an image's alt text is: the
    /// markup inside it counts as what it produces, not as how it's spelled.
    private static func renderedText(_ label: String, _ schema: Schema,
                                     _ definitions: [String: LinkDefinition]) -> String {
        parseInline(label, schema, definitions).map { node in
            if node.isText { return node.text ?? "" }
            // An image inside the label contributes the words of its own alt
            // text, which is all a nested image has to give.
            if node.type.name == "image" { return node.attrs["alt"]?.stringValue ?? "" }
            return node.textContent
        }.joined()
    }

    /// A link's label is inline content — emphasis, code and images inside it are
    /// markup, not literal text — so it's parsed like any other run and the link
    /// mark laid over what comes back. Falls back to plain text if the label
    /// parses to nothing.
    private static func linkContent(_ label: String, _ link: Mark?, _ schema: Schema,
                                    _ definitions: [String: LinkDefinition]) -> [Node] {
        let inner = parseInline(label, schema, definitions, literals: link == nil)
        guard !inner.isEmpty else { return [] }
        guard let link else { return inner }
        return inner.map { $0.mark(link.addToSet($0.marks)) }
    }

    /// `literals` is false while parsing a link's own label, where a bare URL
    /// must stay text — the outer link already claims it.
    static func parseInline(_ text: String, _ schema: Schema,
                            _ definitions: [String: LinkDefinition] = [:],
                            literals: Bool = true) -> [Node] {
        // Everything except the marks written as delimiter runs is resolved as
        // the text is scanned. Runs of "*", "_", "~" and "=" are set aside as
        // delimiters and paired afterwards, because which of them open and which
        // close can't be known until the whole line has been seen.
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
        // Both of these cost a pass over the line, and prose asks them nothing —
        // only a `[` or `<` ever reaches a scan that consults them — so neither
        // is built until something actually needs it.
        var lastByteCache: LastByte?
        func lastBytes() -> LastByte {
            if let lastByteCache { return lastByteCache }
            let built = LastByte(chars)
            lastByteCache = built
            return built
        }
        var bracketCache: BracketMatches?
        func bracketMatches() -> BracketMatches {
            if let bracketCache { return bracketCache }
            // The table is this path's only allocation, so a line that opens no
            // bracket doesn't get one.
            let built = lastBytes().opensBracket ? BracketMatches(chars) : .none
            bracketCache = built
            return built
        }
        // Where a two-byte delimiter search has already come up empty.
        var pairExhausted: [Int: Int] = [:]
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
                let decoded = HTMLParser.decodeEntities(reference, cappingNumericDigits: true)
                // "&#10;" is a newline, which is block structure in this model,
                // not text — decoding it would produce a document we can't write
                // back. Leave those references as written.
                if decoded != reference, !decoded.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                    buffer += Array(decoded.utf8)
                    i = semi + 1; continue
                }
            }
            // A bare URL in running text. Checked before the angle-bracket
            // form below, which can't match here anyway — that one starts at a
            // "<" and this one at the scheme itself.
            //
            // Not inside a link's label: a link within a link is not a thing
            // the document model can hold, and `[see https://x.test](/y)` means
            // the outer link.
            if literals, (c | 0x20) == UInt8(ascii: "h") || (c | 0x20) == UInt8(ascii: "m"),
               literalAutolinkBoundary(chars, i),
               let (url, next) = literalAutolink(chars, i),
               let href = sanitizeURL(url, for: .link) {
                flush()
                appendNode(schema.text(url, mark("link", ["href": .string(href)])))
                i = next; continue
            }
            // Autolink <scheme:...> — a bare URL in angle brackets — or
            // <someone@example.com>, which links to the address. The text stays
            // as written either way; only the href gains the "mailto:".
            // Both of these need a `>` to close on, and both scan forward
            // looking for one — so on a line of bare `<`, which has none, each
            // `<` would walk the rest of the line before failing.
            if c == UInt8(ascii: "<"), lastBytes().has(UInt8(ascii: ">"), atOrAfter: i + 1),
               let close = findByte(chars, i + 1, UInt8(ascii: ">")),
               case let url = slice(chars, (i + 1)..<close),
               case let target = isAutolink(url) ? url : emailAutolink(url),
               let candidate = target, let href = sanitizeURL(candidate, for: .link) {
                flush()
                appendNode(schema.text(url, mark("link", ["href": .string(href)])))
                i = close + 1; continue
            }
            // Inline HTML. Markdown written for the web is full of it — a
            // `<br>` in a table cell, `<sub>` in a formula, `<kbd>` in a
            // keyboard shortcut — and it used to arrive as escaped text. Tags
            // that map onto the schema become marks and nodes.
            //
            // Anything else is left exactly as written rather than dropped:
            // an unknown tag is still the author's text, and deleting it would
            // lose content — including, before this was tightened, the whole of
            // `<javascript:alert(1)>`, which reaches here once the sanitizer has
            // refused to make it a link.
            if c == UInt8(ascii: "<"), lastBytes().has(UInt8(ascii: ">"), atOrAfter: i + 1),
               let tag = inlineTag(chars, i) {
                // A comment, declaration or CDATA section is left as written:
                // dropping one changes the spacing around it, and `<!-- -->` is
                // a real idiom for splitting two lists apart.
                if tag.name == "br", !tag.isClosing {
                    flush()
                    if let br = try? schema.nodes["hardBreak"]?.create() { appendNode(br) }
                    i = tag.end
                    // A break swallows the whitespace after it, as the two-space
                    // spelling does — otherwise the space couldn't be written
                    // back, since a line's leading whitespace is stripped.
                    while i < chars.count, chars[i] == UInt8(ascii: " ")
                        || chars[i] == UInt8(ascii: "\t") { i += 1 }
                    continue
                }
                if tag.name == "img", !tag.isClosing,
                   let source = tag.attrs["src"], let src = sanitizeURL(source, for: .image),
                   let type = schema.nodes["image"] {
                    var attrs: Attrs = ["src": .string(src), "alt": .string(tag.attrs["alt"] ?? "")]
                    if let title = tag.attrs["title"] { attrs["title"] = .string(title) }
                    if let img = try? type.create(attrs) {
                        flush(); appendNode(img); i = tag.end; continue
                    }
                }
                if !tag.isClosing, !tag.selfClosing,
                   let markName = HTMLConfig.default.tagToMark[tag.name],
                   schema.marks[markName] != nil,
                   let close = closingTag(chars, tag.end, tag.name),
                   !slice(chars, tag.end..<(close.end - tag.name.count - 3)).contains("\n") {
                    var applied: Mark?
                    if markName == "link" {
                        if let target = tag.attrs["href"], let href = sanitizeURL(target, for: .link) {
                            var attrs: Attrs = ["href": .string(href)]
                            if let title = tag.attrs["title"] { attrs["title"] = .string(title) }
                            applied = mark("link", attrs).first
                        }
                    } else {
                        applied = mark(markName).first
                    }
                    let inner = slice(chars, tag.end..<(close.end - tag.name.count - 3))
                    let content = parseInline(inner, schema, definitions)
                    if !content.isEmpty {
                        flush()
                        for node in content {
                            appendNode(applied.map { m in node.mark(m.addToSet(node.marks)) } ?? node)
                        }
                        i = close.end; continue
                    }
                }
            }
            // A footnote reference: `[^label]`.
            //
            // GitHub only makes one of these when a matching note exists, and
            // leaves the brackets as text otherwise. Here the node is what
            // matters: a reference whose note has been deleted still has to
            // write itself back as `[^label]` and read back the same, which
            // GitHub's rule would break. Only a schema carrying the node is
            // affected, and `\[^1]` is still literal text.
            if c == UInt8(ascii: "["), i + 1 < chars.count, chars[i + 1] == UInt8(ascii: "^"),
               let type = schema.nodes["footnoteReference"],
               let close = findByte(chars, i + 2, UInt8(ascii: "]")), close > i + 2 {
                let label = slice(chars, (i + 2)..<close)
                if !label.contains(where: { $0.isWhitespace || $0 == "]" }),
                   let reference = try? type.create(["label": .string(label)]) {
                    flush()
                    appendNode(reference)
                    i = close + 1
                    continue
                }
            }
            // Wiki link [[...]]. Only a schema with somewhere to put one reads
            // these brackets as a link — otherwise they are the four characters
            // the author typed, and swallowing them would delete their text.
            // An empty target is not a link either: `[[]]` names no page, which
            // is the same call the `[[…]]` input rule makes.
            if c == UInt8(ascii: "[") && i + 1 < chars.count && chars[i + 1] == UInt8(ascii: "["),
               let type = schema.nodes["wikiLink"] {
                let inner = findPair(chars, i + 2, UInt8(ascii: "]"), UInt8(ascii: "]"), lastBytes(), &pairExhausted)
                    .map { (close: $0, parts: slice(chars, (i + 2)..<$0).split(separator: "|", maxSplits: 1).map(String.init)) }
                // `[[Page|shown]]` reads as "shown".
                if let inner, let target = inner.parts.count > 1 ? inner.parts[1] : inner.parts.first,
                   !target.trimmingCharacters(in: .whitespaces).isEmpty,
                   let wl = try? type.create(["text": .string(target)]) {
                    flush()
                    appendNode(wl)
                    i = inner.close + 2
                    continue
                }
            }
            // Image by reference: ![alt][label], ![alt][] or ![alt]. The inline
            // form takes precedence, and it is checked for below, so this only
            // runs when the brackets aren't followed by a destination.
            if c == UInt8(ascii: "!") && i + 1 < chars.count && chars[i + 1] == UInt8(ascii: "["),
               !definitions.isEmpty, parseLinkLike(chars, i + 1, lastBytes(), bracketMatches()) == nil,
               let (alt, definition, next) = parseReference(chars, i + 1, definitions, bracketMatches()) {
                flush()
                var attrs: Attrs = ["src": .null,
                                    "alt": .string(renderedText(alt, schema, definitions))]
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
                if let (alt, url, title, next) = parseLinkLike(chars, i + 1, lastBytes(), bracketMatches()) {
                    flush()
                    var attrs: Attrs = ["src": .null,
                                        "alt": .string(renderedText(alt, schema, definitions))]
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
                if let (label, url, title, next) = parseLinkLike(chars, i, lastBytes(), bracketMatches()) {
                    flush()
                    // Markdown reaches the editor from the same untrusted places
                    // HTML does, so `[x](javascript:…)` gets the same treatment:
                    // the link is dropped, the text kept.
                    var linkMark: Mark?
                    // An empty destination is a link to here, not a missing one.
                    if let href = url.isEmpty ? "" : sanitizeURL(url, for: .link) {
                        var attrs: Attrs = ["href": .string(href)]
                        if let title { attrs["title"] = .string(title) }
                        linkMark = mark("link", attrs).first
                    }
                    // A destination we won't follow drops the link and keeps the
                    // label, which is still markup.
                    for node in linkContent(label, linkMark, schema, definitions) { appendNode(node) }
                    i = next; continue
                }
            }
            // Link by reference: [text][label], [label][] or [label]. Tried
            // after the inline form, which takes precedence.
            if c == UInt8(ascii: "["), let (label, definition, next) = parseReference(chars, i, definitions, bracketMatches()) {
                flush()
                var linkMark: Mark?
                if let href = definition.destination.isEmpty
                    ? "" : sanitizeURL(definition.destination, for: .link) {
                    var attrs: Attrs = ["href": .string(href)]
                    if let title = definition.title { attrs["title"] = .string(title) }
                    linkMark = mark("link", attrs).first
                }
                for node in linkContent(label, linkMark, schema, definitions) { appendNode(node) }
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
            // Strike ~~ ~~ and highlight == ==. Set aside as delimiter runs, the
            // same as emphasis, so that what they enclose stays inline content:
            // a hard break, a link or nested emphasis inside one is markup, not
            // the literal characters. Reading the span as a flat slice of text
            // instead lost all of that on the way through.
            //
            // Neither means anything singly — a lone "~" or "=" is ordinary
            // prose — so only a run of two or more becomes a delimiter, and
            // pairing spends two characters at a time. The flanking rules are
            // deliberately not applied: unlike "*", these have no in-word use to
            // protect, and matching each closer with the nearest opener keeps
            // "~~a and ~~b~~" closing where it always has.
            if c == UInt8(ascii: "~") || c == UInt8(ascii: "=") {
                let run = runLength(chars, i, c)
                if run >= 2 {
                    flush()
                    delimiters.append(Delimiter(char: c, count: run, original: run,
                                                canOpen: true, canClose: true))
                    pieces.append(.delimiter(delimiters.count - 1))
                    i += run
                    continue
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
                // The whole run is text, not just its first tick: a backtick
                // string is atomic, so "```foo``" has no code span in it.
                buffer += Array(repeating: c, count: run)
                i += run; continue
            }
            buffer.append(c)
            i += 1
        }
        // Trailing whitespace at the very end is not content (two spaces before
        // a newline were already consumed as a hard break above). Tabs count:
        // one left on the end of a heading survived into the document and then
        // couldn't be written back, which was the last round-trip failure.
        while buffer.last == UInt8(ascii: " ") || buffer.last == UInt8(ascii: "\t") {
            buffer.removeLast()
        }
        flush()

        // Pair the delimiters, then hand every piece the marks of the pairs that
        // enclose it. Marks nest by set membership here rather than by wrapping,
        // so `***foo***` is one text node carrying both.
        let positions = pieces.indices.compactMap { index -> Int? in
            if case .delimiter = pieces[index] { return index }
            return nil
        }
        let pairs = processEmphasis(&delimiters, positions)
        // Which kinds of pair cover each piece. Walking the pairs' ranges once
        // beats asking, for every piece, which pairs enclose it. A bitmask
        // rather than a count per kind: marks nest by set membership, so all
        // that matters is whether a kind covers the piece at all — and only the
        // kinds actually paired have their mark built, once rather than per
        // piece.
        var covering = [UInt8](repeating: 0, count: pieces.count)
        var present: UInt8 = 0
        for pair in pairs {
            present |= pair.kind.rawValue
            for index in (positions[pair.open] + 1)..<positions[pair.close] {
                covering[index] |= pair.kind.rawValue
            }
        }
        let kindMarks = EmphasisKind.allCases
            .filter { present & $0.rawValue != 0 }
            .map { (bit: $0.rawValue, marks: mark($0.markName)) }
        var result: [Node] = []
        for (index, piece) in pieces.enumerated() {
            var marks: [Mark] = []
            let cover = covering[index]
            if cover != 0 {
                for (bit, kindMark) in kindMarks where cover & bit != 0 {
                    for m in kindMark { marks = m.addToSet(marks) }
                }
            }
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
    /// A run is accumulated in one buffer and made into a node once, rather than
    /// re-made on every merge. Rebuilding it each time copies the whole run to
    /// add one piece, which is quadratic in the run's length — and a line like
    /// `*a*a*a…`, whose delimiters mostly end up as literal text, is one long
    /// run of tiny pieces. The buffer is only taken when a node actually merges,
    /// so a run of one keeps the node it already had.
    private static func mergeAdjacentText(_ nodes: [Node], _ schema: Schema) -> [Node] {
        var merged: [Node] = []
        var pending: Node?
        var buffer: String?

        func flush() {
            guard let node = pending else { return }
            merged.append(buffer.map { schema.text($0, node.marks) } ?? node)
            pending = nil
            buffer = nil
        }

        for node in nodes {
            if let last = pending, last.isText, node.isText,
               Mark.sameSet(last.marks, node.marks) {
                if buffer == nil { buffer = last.text ?? "" }
                buffer! += node.text ?? ""
                continue
            }
            flush()
            pending = node
        }
        flush()
        return merged
    }

    /// An autolink's contents: a scheme, then anything but spaces or angles.
    /// Bare `<tag>` markup is deliberately not matched; an address with no
    /// scheme is an email autolink, which `emailAutolink` handles.
    private static func isAutolink(_ s: String) -> Bool {
        guard let colon = s.firstIndex(of: ":"), colon != s.startIndex else { return false }
        let scheme = s[s.startIndex..<colon]
        guard scheme.first?.isLetter == true,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" })
        else { return false }
        let rest = s[s.index(after: colon)...]
        return !rest.isEmpty && !rest.contains(where: { $0 == " " || $0 == "<" || $0 == ">" || $0 == "\n" })
    }

    /// `<foo@example.com>` is a link to that address, which the author wrote
    /// without the `mailto:` the href needs. CommonMark specifies its own
    /// grammar for this rather than deferring to RFC 5322 — it is deliberately
    /// narrower, so an address with a quoted local part isn't one.
    ///
    /// Returns the href, or nil if this isn't an address.
    private static func emailAutolink(_ s: String) -> String? {
        func isAlphanumeric(_ c: Character) -> Bool {
            guard let b = c.asciiValue else { return false }
            return (b >= 48 && b <= 57) || ((b | 0x20) >= 97 && (b | 0x20) <= 122)
        }
        // The local part, before the last "@" — an address may contain only one,
        // but the grammar allows "@" in neither side, so the first is the split.
        guard let at = s.firstIndex(of: "@"), at != s.startIndex else { return nil }
        let localPunctuation = Set(".!#$%&'*+/=?^_`{|}~-")
        guard s[s.startIndex..<at].allSatisfy({ isAlphanumeric($0) || localPunctuation.contains($0) })
        else { return nil }

        // Then dot-separated labels: alphanumeric at each end, hyphens inside,
        // at most 63 characters each. A trailing or doubled dot leaves an empty
        // label, which is why the empty subsequences are kept.
        let domain = s[s.index(after: at)...]
        guard !domain.isEmpty else { return nil }
        for label in domain.split(separator: ".", omittingEmptySubsequences: false) {
            guard let first = label.first, let last = label.last,
                  label.count <= 63, isAlphanumeric(first), isAlphanumeric(last),
                  label.allSatisfy({ isAlphanumeric($0) || $0 == "-" })
            else { return nil }
        }
        return "mailto:" + s
    }

    /// A `String` from a range of the byte buffer. Ranges only ever start and end
    /// on ASCII delimiters, so they never split a multi-byte character, and this
    /// is a copy of the bytes rather than a per-character append.
    private static func slice(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    // MARK: - Literal autolinks
    //
    // GFM's "extended autolinks": a URL the author wrote bare, without the
    // angle brackets CommonMark requires. `<https://example.com>` is core
    // CommonMark and handled above; this is the same link written the way
    // people actually write it.
    //
    // Only `http://`, `https://` and `mailto:` are matched. GFM also defines a
    // bare `www.` host and a bare address with no scheme at all, and those are
    // where the false positives live — neither has a scheme to anchor on, so
    // both have to guess from shape alone. They are deliberately left out for
    // now rather than half-done.

    private static func isAsciiAlnum(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A)
    }

    /// Whether `prefix` — which must be lowercase ASCII — is at `i`, ignoring
    /// case. `HTTPS://` is as much a link as `https://`.
    private static func hasPrefix(_ bytes: [UInt8], _ i: Int, _ prefix: [UInt8]) -> Bool {
        guard i + prefix.count <= bytes.count else { return false }
        for k in prefix.indices where (bytes[i + k] | 0x20) != prefix[k] { return false }
        return true
    }

    private static let httpPrefix = Array("http://".utf8)
    private static let httpsPrefix = Array("https://".utf8)
    private static let mailtoPrefix = Array("mailto:".utf8)

    /// Whether a literal autolink may begin at `i`.
    ///
    /// At the start of the text, or after whitespace or one of the characters
    /// GFM lets hug one. Anything else — `x`, `/`, `=` — means the run is part
    /// of something else the author is writing, and linking it would be a
    /// guess. This errs towards not linking, which is the safe direction: a URL
    /// that stays plain is a missing convenience, a wrongly-linked one is a
    /// document that changed under the author.
    private static func literalAutolinkBoundary(_ bytes: [UInt8], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        switch bytes[i - 1] {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"),
             UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "("):
            return true
        default: return false
        }
    }

    /// A bare URL beginning at `start`, and the index just past it.
    static func literalAutolink(_ bytes: [UInt8], _ start: Int) -> (text: String, end: Int)? {
        let mailto = hasPrefix(bytes, start, mailtoPrefix)
        let bodyStart: Int
        if mailto { bodyStart = start + mailtoPrefix.count }
        else if hasPrefix(bytes, start, httpsPrefix) { bodyStart = start + httpsPrefix.count }
        else if hasPrefix(bytes, start, httpPrefix) { bodyStart = start + httpPrefix.count }
        else { return nil }

        // The candidate runs to the next whitespace or `<`. What of its tail is
        // punctuation the author wrote around the link rather than part of it
        // is decided afterwards, because the answer depends on the whole run.
        var end = bodyStart
        while end < bytes.count {
            let b = bytes[end]
            if b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") || b == UInt8(ascii: "\n")
                || b == UInt8(ascii: "<") { break }
            end += 1
        }
        end = trimAutolinkTail(bytes, start, end)
        guard end > bodyStart else { return nil }

        let body = slice(bytes, bodyStart..<end)
        guard mailto ? isAutolinkAddress(body) : hasAutolinkDomain(body) else { return nil }
        return (slice(bytes, start..<end), end)
    }

    /// Trim what the author wrote *around* a bare URL rather than in it.
    ///
    /// Three rules, applied until none of them applies: trailing punctuation is
    /// a sentence's, not the link's; a closing paren is only the link's if the
    /// link opened it, so "(see https://example.com/a)" doesn't keep the last
    /// bracket while ".../Foo_(bar)" does; and a trailing `&…;` is an entity
    /// reference belonging to the surrounding text.
    private static func trimAutolinkTail(_ bytes: [UInt8], _ start: Int, _ initial: Int) -> Int {
        var end = initial
        loop: while end > start {
            switch bytes[end - 1] {
            case UInt8(ascii: "?"), UInt8(ascii: "!"), UInt8(ascii: "."), UInt8(ascii: ","),
                 UInt8(ascii: ":"), UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "~"):
                end -= 1
            case UInt8(ascii: ";"):
                // `&` then letters or digits then this `;` is an entity.
                var j = end - 1
                while j > start, isAsciiAlnum(bytes[j - 1]) { j -= 1 }
                guard j > start, j < end - 1, bytes[j - 1] == UInt8(ascii: "&") else { break loop }
                end = j - 1
            case UInt8(ascii: ")"):
                var opening = 0, closing = 0
                for k in start..<end {
                    if bytes[k] == UInt8(ascii: "(") { opening += 1 }
                    else if bytes[k] == UInt8(ascii: ")") { closing += 1 }
                }
                guard closing > opening else { break loop }
                end -= 1
            default: break loop
            }
        }
        return end
    }

    /// GFM's "valid domain": dot-separated segments of alphanumerics, `-` and
    /// `_`, at least one dot, and no underscore in the last two segments. The
    /// host is what precedes the first `/`, `?` or `#`.
    private static func hasAutolinkDomain(_ body: String) -> Bool {
        let host = body.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !host.isEmpty else { return false }
        let segments = host.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        for segment in segments {
            guard !segment.isEmpty,
                  segment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber
                                                      || $0 == "-" || $0 == "_") })
            else { return false }
        }
        return !segments.suffix(2).contains { $0.contains("_") }
    }

    /// The address after a `mailto:`. Narrower than the angle-bracket form's
    /// grammar, matching GFM: alphanumerics and `.-_+` before the `@`, a
    /// dotted host after it, and no `-` or `_` at the very end.
    private static func isAutolinkAddress(_ body: String) -> Bool {
        guard let at = body.firstIndex(of: "@"), at != body.startIndex else { return false }
        let local = body[body.startIndex..<at]
        guard local.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber
                                                || $0 == "." || $0 == "-" || $0 == "_" || $0 == "+") })
        else { return false }
        let host = body[body.index(after: at)...]
        guard let last = host.last, last != "-", last != "_" else { return false }
        let segments = host.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
        }
    }

    /// Whether `text` is exactly a literal autolink — nothing before it, and
    /// nothing of it trimmed away. This is what lets the serializer write such
    /// a link bare: it holds precisely when reading the bare form back gives
    /// this link again.
    static func isWholeLiteralAutolink(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let (matched, end) = literalAutolink(bytes, 0) else { return false }
        return end == bytes.count && matched == text
    }

    private static func parseLinkLike(_ bytes: [UInt8], _ start: Int,
                                      _ last: LastByte, _ brackets: BracketMatches)
        -> (text: String, url: String, title: String?, next: Int)? {
        guard bytes[start] == UInt8(ascii: "[") else { return nil }
        guard let closeBracket = brackets.close(openingAt: start) else { return nil }
        guard closeBracket + 1 < bytes.count,
              bytes[closeBracket + 1] == UInt8(ascii: "(") else { return nil }
        // An image's label may hold a link; a link's may not.
        if start == 0 || bytes[start - 1] != UInt8(ascii: "!"),
           labelHoldsALink(slice(bytes, (start + 1)..<closeBracket)) { return nil }
        guard let closeParen = findLinkClose(bytes, closeBracket + 2, last) else { return nil }
        let label = slice(bytes, (start + 1)..<closeBracket)
        let inside = slice(bytes, (closeBracket + 2)..<closeParen)
        guard let (url, title) = splitDestinationAndTitle(inside) else { return nil }
        // A destination that isn't in angle brackets may not contain spaces.
        // Without this, `[a](url &quot;tit&quot;)` — whose "title" is spelled
        // with entities, so isn't one — would still parse as a link.
        if title == nil, url.contains(" "),
           !inside.trimmingCharacters(in: .whitespaces).hasPrefix("<") { return nil }
        // A code span binds more tightly than a link, so one that opens inside
        // the label and closes past it takes the brackets with it.
        if codeSpanEscapes(bytes, (start + 1)..<closeBracket) { return nil }
        return (label, url, title, closeParen + 1)
    }

    /// What a matched pair of delimiters marks its contents with.
    enum EmphasisKind: UInt8, CaseIterable {
        case emphasis = 1, strong = 2, strike = 4, highlight = 8

        /// The pair spends two characters of each run rather than one.
        static func doubled(_ char: UInt8) -> Bool {
            char == UInt8(ascii: "~") || char == UInt8(ascii: "=")
        }

        var markName: String {
            switch self {
            case .emphasis: return "italic"
            case .strong: return "bold"
            case .strike: return "strike"
            case .highlight: return "highlight"
            }
        }
    }

    /// One run of `*`, `_`, `~` or `=`, as the emphasis algorithm sees it.
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
        let kind: EmphasisKind
    }

    /// CommonMark's "process emphasis": walk the delimiter runs left to right and
    /// match each closer with the nearest opener that can pair with it.
    ///
    /// Pair matching alone can't express `***foo***` or `*foo **bar** baz*` —
    /// the first needs one run to supply two different pairs, and the second
    /// needs an inner pair to be matched before the outer one can close past it.
    /// Working from the closers, and dropping any delimiters left stranded
    /// between a matched pair, is what gets both right.
    /// The delimiters still available to match are held as a linked list rather
    /// than an array, because the algorithm's whole shape is removal from the
    /// middle: every pair drops both its ends and everything stranded between
    /// them. `Array.remove(at:)` shifts the tail on each of those, which is one
    /// line of code and O(n²) over a line made of delimiters — `*a*a*a…` spent
    /// all its time there. Relinking is O(1), and the traversal order is
    /// identical, so the pairs produced are unchanged.
    static func processEmphasis(_ delimiters: inout [Delimiter],
                                _ positions: [Int]) -> [EmphasisPair] {
        var pairs: [EmphasisPair] = []
        let count = positions.count
        guard count > 0 else { return pairs }
        // `count` is the past-the-end sentinel; -1 is "before the first".
        var next = (0..<count).map { $0 + 1 }
        var prev = (0..<count).map { $0 - 1 }
        func unlink(_ i: Int) {
            let p = prev[i], n = next[i]
            if p >= 0 { next[p] = n }
            if n < count { prev[n] = p }
        }

        var closer = 0
        while closer < count {
            guard delimiters[closer].canClose, delimiters[closer].count > 0 else {
                closer = next[closer]
                continue
            }
            // "~~" and "==" only mean anything in pairs of two, so a run with a
            // single character left over is spent as text rather than matched.
            let doubled = EmphasisKind.doubled(delimiters[closer].char)
            if doubled, delimiters[closer].count < 2 {
                closer = next[closer]
                continue
            }
            // The nearest opener of the same character that may pair with it.
            var opener = -1
            var scan = prev[closer]
            while scan >= 0 {
                if delimiters[scan].char == delimiters[closer].char,
                   delimiters[scan].canOpen, delimiters[scan].count > 0,
                   doubled ? delimiters[scan].count >= 2
                           : canPair(delimiters[scan], delimiters[closer]) {
                    opener = scan
                    break
                }
                scan = prev[scan]
            }
            guard opener >= 0 else {
                // A closer that can't also open is spent; anything else may
                // still serve as an opener for a later closer.
                let after = next[closer]
                if !delimiters[closer].canOpen { unlink(closer) }
                closer = after
                continue
            }
            // Two characters make emphasis strong when both runs can spare them;
            // the doubled delimiters always spend two.
            let strong = delimiters[opener].count >= 2 && delimiters[closer].count >= 2
            let used = strong || doubled ? 2 : 1
            let kind: EmphasisKind = doubled
                ? (delimiters[closer].char == UInt8(ascii: "~") ? .strike : .highlight)
                : (strong ? .strong : .emphasis)
            pairs.append(EmphasisPair(open: opener, close: closer, kind: kind))
            delimiters[opener].count -= used
            delimiters[closer].count -= used
            // Delimiters caught between the pair can never match anything now.
            var stranded = next[opener]
            while stranded != closer {
                let after = next[stranded]
                unlink(stranded)
                stranded = after
            }
            // A closer with characters left over stays where it is and is tried
            // again, which is how one run supplies two pairs in `***foo***`.
            if delimiters[closer].count == 0 {
                let after = next[closer]
                unlink(closer)
                closer = after
            }
            if delimiters[opener].count == 0 { unlink(opener) }
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
                                       _ definitions: [String: LinkDefinition],
                                       _ brackets: BracketMatches)
        -> (text: String, definition: LinkDefinition, next: Int)? {
        guard !definitions.isEmpty, bytes[start] == UInt8(ascii: "[") else { return nil }
        guard let closeBracket = brackets.close(openingAt: start) else { return nil }
        let first = slice(bytes, (start + 1)..<closeBracket)
        // As with an inline link: a label already holding a link keeps its
        // brackets, and a code span reaching past the label wins.
        if start == 0 || bytes[start - 1] != UInt8(ascii: "!"), labelHoldsALink(first) { return nil }
        if codeSpanEscapes(bytes, (start + 1)..<closeBracket) { return nil }
        var label = first
        var next = closeBracket + 1
        // A second bracket pair makes it a full or collapsed reference.
        if closeBracket + 1 < bytes.count, bytes[closeBracket + 1] == UInt8(ascii: "[") {
            guard let closeSecond = brackets.close(openingAt: closeBracket + 1) else { return nil }
            let second = slice(bytes, (closeBracket + 2)..<closeSecond)
            // `[text][]` is collapsed: the text is its own label.
            label = second.trimmingCharacters(in: .whitespaces).isEmpty ? first : second
            next = closeSecond + 1
        }
        guard let definition = definitions[normalizeLabel(label)] else { return nil }
        return (first, definition, next)
    }

    /// Whether a backtick run inside `label` closes only after it — a code span
    /// binds more tightly than a link, so `[not a `link](/foo`)` is a code span
    /// inside literal brackets rather than a link.
    private static func codeSpanEscapes(_ bytes: [UInt8], _ label: Range<Int>) -> Bool {
        var i = label.lowerBound
        while i < label.upperBound {
            if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
            guard bytes[i] == UInt8(ascii: "`") else { i += 1; continue }
            let run = runLength(bytes, i, UInt8(ascii: "`"))
            if let close = findBacktickRun(bytes, i + run, run), close >= label.upperBound {
                return true
            }
            i += run
        }
        return false
    }

    /// The `)` that closes a link, skipping the parts that may contain one:
    /// an angle-bracketed destination, a quoted title, and balanced parentheses
    /// (which is also the `(title)` spelling).
    /// How deep parentheses may nest inside a link destination.
    ///
    /// CommonMark lets a destination hold balanced parentheses but says nothing
    /// about how many, and unbounded is what makes `[a](` repeated quadratic:
    /// every bracket starts a scan whose depth only ever grows, so each one
    /// walks to the end of the line before giving up. A destination that nests
    /// this deep isn't one anybody wrote — every example in the specification
    /// stays inside one pair.
    public static let maxLinkParenDepth = 32

    private static func findLinkClose(_ bytes: [UInt8], _ from: Int, _ last: LastByte) -> Int? {
        // With no `)` left there is nothing to find, so don't go looking.
        guard last.has(UInt8(ascii: ")"), atOrAfter: from) else { return nil }
        var i = from
        var depth = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\\") { i += 2; continue }
            if b == UInt8(ascii: "<"),
               let close = findUnescaped(bytes, i + 1, UInt8(ascii: ">")) { i = close + 1; continue }
            if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'"),
               let close = findUnescaped(bytes, i + 1, b) { i = close + 1; continue }
            if b == UInt8(ascii: "(") {
                depth += 1
                if depth > maxLinkParenDepth { return nil }
                i += 1
                continue
            }
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
    /// Split the inside of a link's parentheses into destination and title.
    /// Nil when it isn't a well-formed pair — an unclosed angle bracket, a
    /// destination broken across lines, or anything left over after the title —
    /// in which case the brackets stay literal text.
    static func splitDestinationAndTitle(_ s: String) -> (String, String?)? {
        let bytes = Array(s.utf8)
        var i = 0
        func isSpace(_ b: UInt8) -> Bool {
            b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") || b == UInt8(ascii: "\n")
                || b == UInt8(ascii: "\r")
        }
        func skipSpace() { while i < bytes.count, isSpace(bytes[i]) { i += 1 } }

        skipSpace()
        var destination = ""
        if i < bytes.count, bytes[i] == UInt8(ascii: "<") {
            guard let close = findUnescaped(bytes, i + 1, UInt8(ascii: ">")) else { return nil }
            destination = slice(bytes, (i + 1)..<close)
            // An angle-bracketed destination is still one line.
            if destination.contains("\n") { return nil }
            i = close + 1
        } else {
            let from = i
            while i < bytes.count, !isSpace(bytes[i]) {
                if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
                i += 1
            }
            destination = slice(bytes, from..<min(i, bytes.count))
        }

        // Whitespace has to separate the destination from a title — without it,
        // `[foo]: <bar>(baz)` would read as one.
        let afterDestination = i
        skipSpace()
        let hadSpace = i > afterDestination
        guard i < bytes.count else { return (resolveEscapes(destination), nil) }
        let opener = bytes[i]
        guard hadSpace || opener == UInt8(ascii: "<"),
              opener == UInt8(ascii: "\"") || opener == UInt8(ascii: "'")
                || opener == UInt8(ascii: "(") else { return nil }
        let closer = opener == UInt8(ascii: "(") ? UInt8(ascii: ")") : opener
        // Escape-aware, so a backslashed quote doesn't end the title early.
        guard let close = findUnescaped(bytes, i + 1, closer) else { return nil }
        let title = slice(bytes, (i + 1)..<close)
        i = close + 1
        skipSpace()
        // Anything left over means this wasn't a destination and title at all.
        guard i >= bytes.count else { return nil }
        return (resolveEscapes(destination), resolveEscapes(title))
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
            // The four ASCII punctuation ranges, which is exactly
            // `!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~` — previously written out as
            // that string and scanned linearly, once per scalar of every run
            // of emphasis in the document.
            switch scalar.value {
            case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
            default: return false
            }
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
    /// The `]` closing the label that opens at `start`, counting nested pairs so
    /// that `[link [foo [bar]]]` closes at the last bracket rather than the
    /// first — and so an image inside a link, `[![alt](img)](url)`, holds
    /// together.
    /// Every bracket's match, worked out in one pass with a stack.
    ///
    /// Walking forward from a bracket counting depth answers one question in
    /// time proportional to the rest of the line, and the inline scanner asks it
    /// at every `[` — so `[[[[…`, or a line of openers with a single `]` at the
    /// end, costs a walk of the whole line per character. A stack pass answers
    /// it for every bracket at once, for the cost of a single walk, and gives
    /// exactly the same matches: the depth count and the stack agree on which
    /// `]` closes which `[`, including which brackets go unmatched.
    struct BracketMatches {
        private let closes: [Int]

        /// For a line with no bracket in it. `close(openingAt:)` reads an
        /// empty table as "nothing matches", which is the right answer there,
        /// and it costs neither a pass nor an allocation.
        static let none = BracketMatches()

        private init() { closes = [] }

        init(_ bytes: [UInt8]) {
            var closes = [Int](repeating: -1, count: bytes.count)
            var open: [Int] = []
            var i = 0
            while i < bytes.count {
                // An escaped bracket is text, exactly as the walk treated it.
                if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
                if bytes[i] == UInt8(ascii: "[") {
                    open.append(i)
                } else if bytes[i] == UInt8(ascii: "]"), let opener = open.popLast() {
                    closes[opener] = i
                }
                i += 1
            }
            self.closes = closes
        }

        /// The `]` closing the bracket that opens at `opener`, if it has one.
        func close(openingAt opener: Int) -> Int? {
            guard opener >= 0, opener < closes.count, closes[opener] >= 0 else { return nil }
            return closes[opener]
        }
    }

    /// Whether a label already holds a link, which means it can't become one:
    /// links don't nest, so in `[foo [bar](/uri)](/uri)` the inner link wins and
    /// the outer brackets stay literal. An image may nest, so `!` disqualifies.
    private static func labelHoldsALink(_ label: String) -> Bool {
        let bytes = Array(label.utf8)
        // Built once for the whole label rather than per bracket: this walks
        // every `[` in it, and each of those would otherwise scan to the end.
        let brackets = BracketMatches(bytes)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
            if bytes[i] == UInt8(ascii: "["), i == 0 || bytes[i - 1] != UInt8(ascii: "!"),
               let close = brackets.close(openingAt: i), close + 1 < bytes.count,
               bytes[close + 1] == UInt8(ascii: "(") || bytes[close + 1] == UInt8(ascii: "[") {
                return true
            }
            i += 1
        }
        return false
    }

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

    /// Where each byte last appears in the line being scanned.
    ///
    /// The inline scanner looks for a closing delimiter from every position that
    /// could open one, and when the closer isn't in the line at all each of
    /// those looks walks to the end of the buffer — so `[[[[…`, which closes
    /// nothing, costs a scan of the whole line per character. One pass recording
    /// where each byte last occurs answers "is there a closer left?" outright,
    /// which is what keeps a line of unmatched openers linear.
    ///
    /// Five stored positions rather than a table indexed by byte: this is built
    /// for every line parsed, including the short ones inside a quote or a list
    /// item, and a table means a heap allocation each time — which cost more on
    /// ordinary documents than the scans it saves on hostile ones.
    struct LastByte {
        private let bracket: Int
        private let paren: Int
        private let angle: Int
        private let tilde: Int
        private let equals: Int
        /// Whether the line opens a bracket anywhere — the one thing worth
        /// knowing before deciding to match brackets at all.
        let opensBracket: Bool

        init(_ bytes: [UInt8]) {
            var bracket = -1, paren = -1, angle = -1, tilde = -1, equals = -1
            var opensBracket = false
            for i in bytes.indices {
                switch bytes[i] {
                case UInt8(ascii: "["): opensBracket = true
                case UInt8(ascii: "]"): bracket = i
                case UInt8(ascii: ")"): paren = i
                case UInt8(ascii: ">"): angle = i
                case UInt8(ascii: "~"): tilde = i
                case UInt8(ascii: "="): equals = i
                default: break
                }
            }
            self.bracket = bracket
            self.paren = paren
            self.angle = angle
            self.tilde = tilde
            self.equals = equals
            self.opensBracket = opensBracket
        }

        func has(_ byte: UInt8, atOrAfter from: Int) -> Bool {
            let last: Int
            switch byte {
            case UInt8(ascii: "]"): last = bracket
            case UInt8(ascii: ")"): last = paren
            case UInt8(ascii: ">"): last = angle
            case UInt8(ascii: "~"): last = tilde
            case UInt8(ascii: "="): last = equals
            // Only the closers the scanners ask about are tracked. Anything
            // else has to be assumed present, or the caller would skip a search
            // that might have found something.
            default: return true
            }
            return last >= from
        }
    }

    /// The next `ab` pair at or after `from`.
    ///
    /// The inline delimiters that come in twos — `]]`, `~~`, `==` — are looked
    /// for at every position that could open one. Taking the two bytes rather
    /// than a sequence keeps the caller from building an array per position, and
    /// the `last` check answers the case that costs the most: a line that opens
    /// the delimiter over and over and never closes it.
    /// `exhausted` records, per pair, a position from which the search already
    /// came up empty. A forward search that finds nothing from one position
    /// finds nothing from any later one, so that first failure is the only one
    /// worth paying for — which is what a line like `[[[[…]` needs: it holds a
    /// `]`, so the "any closer left" test passes, but never a `]]`, and without
    /// the memo every `[[` scans the rest of the line to discover that again.
    private static func findPair(_ bytes: [UInt8], _ from: Int,
                                 _ a: UInt8, _ b: UInt8, _ last: LastByte,
                                 _ exhausted: inout [Int: Int]) -> Int? {
        guard from >= 0, last.has(b, atOrAfter: from + 1) else { return nil }
        let key = Int(a) << 8 | Int(b)
        if let empty = exhausted[key], from >= empty { return nil }
        var i = from
        while i + 1 < bytes.count {
            if bytes[i] == a && bytes[i + 1] == b { return i }
            i += 1
        }
        exhausted[key] = from
        return nil
    }

    /// Compared in place. Slicing the candidate into a fresh `Array` to compare
    /// it allocated once per position scanned, which on a line that never
    /// contains the sequence is an allocation per character.
    private static func findSeq(_ bytes: [UInt8], _ from: Int, _ seq: [UInt8]) -> Int? {
        guard !seq.isEmpty, from >= 0 else { return nil }
        let first = seq[0]
        var i = from
        let last = bytes.count - seq.count
        outer: while i <= last {
            if bytes[i] == first {
                var k = 1
                while k < seq.count {
                    if bytes[i + k] != seq[k] { i += 1; continue outer }
                    k += 1
                }
                return i
            }
            i += 1
        }
        return nil
    }
}
