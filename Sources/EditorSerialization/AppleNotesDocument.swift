public import Foundation
public import DocumentModel

// Full-document conversion of Apple Notes' private pasteboard proto: note_text
// plus styled attribute runs → a ProseMirror doc (headings, paragraphs, bullet/
// ordered/task lists with indent nesting, code blocks, bold/italic/underline/
// strike/link marks). Like the checklist reader, everything is best-effort and
// schema-aware: node/mark types the schema lacks degrade gracefully (heading →
// paragraph, unknown mark → plain text), and structural surprises return nil so
// the caller can fall back to the RTF bridge.

extension AppleNotesPasteboard {
    /// Convert the `com.apple.notes.richtext` archive to a document Node.
    /// When `matchingText` is given (the pasted attributed string's text), the
    /// note text must match it — this keeps a whole-note proto from replacing a
    /// partial-selection paste. Returns nil if no blob parses or text mismatches.
    public static func document(fromArchive data: Data, schema: Schema, matchingText: String? = nil) -> Node? {
        for blob in noteBlobs(fromArchive: data) {
            if let doc = parseNoteDocument(blob, schema: schema, matchingText: matchingText) { return doc }
        }
        return nil
    }

    /// Convert a raw Note proto to a document Node.
    public static func parseNoteDocument(_ data: Data, schema: Schema, matchingText: String? = nil) -> Node? {
        guard let (text, runs) = parseNote([UInt8](data)), !runs.isEmpty else { return nil }
        if let expected = matchingText, normalizedForMatch(text) != normalizedForMatch(expected) { return nil }
        return buildDocument(text: text, runs: runs, schema: schema)
    }

    // MARK: - Document assembly

    private struct Line {
        var styleType = -1
        var indent = 0
        var checked = false
        var content: [Node] = []
        var text = ""
    }

    private static func buildDocument(text: String, runs: [NoteRun], schema: Schema) -> Node? {
        guard let paragraphType = schema.nodes["paragraph"] else { return nil }
        let units = Array(text.utf16)
        guard !units.isEmpty else { return nil }

        // Map each UTF-16 unit to its run (clamped: lengths are untrusted).
        var runAt = [Int](repeating: runs.count - 1, count: units.count)
        var pos = 0
        for (ri, run) in runs.enumerated() {
            let end = pos + min(max(0, run.length), units.count - pos)
            for k in pos..<end { runAt[k] = ri }
            pos = end
            if pos >= units.count { break }
        }

        func sameInline(_ a: NoteRun, _ b: NoteRun) -> Bool {
            a.bold == b.bold && a.italic == b.italic && a.underline == b.underline
                && a.strike == b.strike && a.link == b.link
        }

        // Split into lines, each with its block style and inline content.
        var lines: [Line] = []
        var start = 0
        for k in 0...units.count where k == units.count || units[k] == 0x0A {
            if k == units.count, k == start { break } // text ended with the last "\n"
            var line = Line()
            // Block style: the first unit (including the line's newline, so empty
            // lines still carry style) whose run declares one.
            let probe = start..<min(k + 1, units.count)
            for u in probe where runs[runAt[u]].styleType >= 0 {
                line.styleType = runs[runAt[u]].styleType
                line.indent = runs[runAt[u]].indent
                break
            }
            line.checked = probe.contains { runs[runAt[$0]].styleType == 103 && runs[runAt[$0]].done }
            if k > start {
                var segStart = start
                func flush(_ upTo: Int) {
                    guard upTo > segStart else { return }
                    let s = String(decoding: units[segStart..<upTo], as: UTF16.self)
                        .replacingOccurrences(of: "\u{FFFC}", with: "")
                    let run = runs[runAt[segStart]]
                    segStart = upTo
                    guard !s.isEmpty else { return }
                    line.content.append(schema.text(s, inlineMarks(run, schema)))
                    line.text += s
                }
                for u in (start + 1)..<k where !sameInline(runs[runAt[u]], runs[runAt[u - 1]]) { flush(u) }
                flush(k)
            }
            lines.append(line)
            start = k + 1
        }

        func paragraph(_ line: Line) -> Node? {
            paragraphType.createAndFill([:], content: Fragment.from(line.content))
        }

        var blocks: [Node] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            switch line.styleType {
            case 0, 1, 2: // title / heading / subheading
                if let ht = schema.nodes["heading"],
                   let h = ht.createAndFill(["level": .int(line.styleType + 1)], content: Fragment.from(line.content)) {
                    blocks.append(h)
                } else if let p = paragraph(line) {
                    blocks.append(p)
                }
                i += 1
            case 4: // monospaced: consecutive lines merge into one code block
                var texts: [String] = []
                while i < lines.count, lines[i].styleType == 4 { texts.append(lines[i].text); i += 1 }
                let joined = texts.joined(separator: "\n")
                if let ct = schema.nodes["codeBlock"],
                   let cb = ct.createAndFill([:], content: Fragment.from(joined.isEmpty ? [] : [schema.text(joined)])) {
                    blocks.append(cb)
                } else {
                    for t in texts {
                        if let p = paragraphType.createAndFill([:], content: Fragment.from(t.isEmpty ? [] : [schema.text(t)])) {
                            blocks.append(p)
                        }
                    }
                }
            case 100, 101, 102, 103:
                i = appendLists(lines, from: i, into: &blocks, paragraph: paragraph, schema: schema)
            default:
                if let p = paragraph(line) { blocks.append(p) }
                i += 1
            }
        }
        // Notes' text often has empty boundary lines (e.g. a leading "\n");
        // they're noise in a paste, so trim empty plain paragraphs at the edges.
        func isEmptyParagraph(_ n: Node) -> Bool { n.type.name == "paragraph" && n.childCount == 0 }
        while let f = blocks.first, isEmptyParagraph(f) { blocks.removeFirst() }
        while let l = blocks.last, isEmptyParagraph(l) { blocks.removeLast() }
        guard !blocks.isEmpty else { return nil }
        return schema.topNodeType.createAndFill([:], content: Fragment.from(blocks))
    }

    /// Consume the run of consecutive list lines starting at `startIdx`, building
    /// (possibly nested, possibly type-switching) list nodes onto `blocks`.
    /// Returns the index of the first non-list line.
    private static func appendLists(_ lines: [Line], from startIdx: Int, into blocks: inout [Node],
                                    paragraph: (Line) -> Node?, schema: Schema) -> Int {
        struct Level {
            var style: Int
            var indent: Int
            var items: [Node]
        }
        var stack: [Level] = []

        func listNodeName(_ style: Int) -> String {
            switch style {
            case 102: return "orderedList"
            case 103: return "taskList"
            default: return "bulletList" // 100 dotted, 101 dashed
            }
        }

        // Close the top level: it becomes a child of the previous level's last
        // item, or a top-level block.
        func pop() {
            guard let lvl = stack.popLast(),
                  let list = schema.nodes[listNodeName(lvl.style)]?
                      .createAndFill([:], content: Fragment.from(lvl.items))
            else { return }
            if let parent = stack.last, let lastItem = parent.items.last {
                let kids = (0..<lastItem.childCount).map { lastItem.child($0) } + [list]
                stack[stack.count - 1].items[parent.items.count - 1] = lastItem.copy(content: Fragment.from(kids))
            } else {
                blocks.append(list)
            }
        }

        var i = startIdx
        while i < lines.count, (100...103).contains(lines[i].styleType) {
            let line = lines[i]
            i += 1
            guard let p = paragraph(line),
                  let item = schema.nodes[line.styleType == 103 ? "taskItem" : "listItem"]?.createAndFill(
                      line.styleType == 103 ? ["checked": .bool(line.checked)] : [:],
                      content: Fragment.from([p]))
            else {
                // Schema can't express this list — flush and degrade to a paragraph.
                while !stack.isEmpty { pop() }
                if let p = paragraph(line) { blocks.append(p) }
                continue
            }
            while let top = stack.last, top.indent > line.indent { pop() }
            // A different list type at the same indent closes the current level;
            // the item then starts a fresh level (never lands in an outer list,
            // which would lose its type/indent — or, for a taskItem appended into
            // a bulletList, fail validation and drop the whole list).
            if let top = stack.last, top.indent == line.indent, top.style != line.styleType { pop() }
            if let top = stack.last, top.indent == line.indent, top.style == line.styleType {
                stack[stack.count - 1].items.append(item)
            } else {
                stack.append(Level(style: line.styleType, indent: line.indent, items: [item]))
            }
        }
        while !stack.isEmpty { pop() }
        return i
    }

    private static func inlineMarks(_ r: NoteRun, _ schema: Schema) -> [Mark] {
        var marks: [Mark] = []
        if r.bold, schema.marks["bold"] != nil { marks.append(schema.mark("bold")) }
        if r.italic, schema.marks["italic"] != nil { marks.append(schema.mark("italic")) }
        if r.underline, schema.marks["underline"] != nil { marks.append(schema.mark("underline")) }
        if r.strike, schema.marks["strike"] != nil { marks.append(schema.mark("strike")) }
        if let link = r.link, !link.isEmpty, schema.marks["link"] != nil {
            marks.append(schema.mark("link", ["href": .string(link)]))
        }
        return marks
    }
}
