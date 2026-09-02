import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorKeymap
import EditorSerialization
import SchemaKit
import TestHarness

// Extension entry points nothing else in the suite called: the per-type image
// commands, mentions inserted through the API, arrow-key cell navigation, the
// cell selection's JSON, the public table geometry helpers, the extension
// manager's merged keymap, and a handful of Editor conveniences. Each is a
// promise to a host; the ones with a real edge (leaving the table from its
// last row, the keymap's priority order, a mention's fallback text) had no
// test to say what happens there.

/// The positions of every cell in document order.
private func cellPositions(_ doc: Node) -> [Int] {
    var out: [Int] = []
    doc.descendants { node, pos, _, _ in
        if node.type.name == "tableCell" || node.type.name == "tableHeader" { out.append(pos) }
        return true
    }
    return out
}

/// The position of the cell the selection head sits in.
private func cellOfSelection(_ editor: Editor) -> Int? {
    let head = editor.state.selection.resolvedHead
    for d in stride(from: head.depth, through: 0, by: -1)
    where head.node(d).type.name == "tableCell" || head.node(d).type.name == "tableHeader" {
        return head.before(d)
    }
    return nil
}

private func caret(_ editor: Editor, _ pos: Int) {
    editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, pos)))
}

/// An editor holding a 2x2 table of empty cells between two paragraphs, caret
/// in the first cell.
private func tableEditor() throws -> Editor {
    let editor = try Editor(extensions: fullKit())
    try expect(editor.insertTable(rows: 2, cols: 2, withHeaderRow: false))
    let paragraph = editor.schema.nodes["paragraph"]!
    let tr = editor.state.tr
    if editor.doc.lastChild?.type.name == "table" { try tr.insert(tr.doc.content.size, paragraph.createAndFill()!) }
    if editor.doc.firstChild?.type.name == "table" { try tr.insert(0, paragraph.createAndFill()!) }
    if tr.docChanged { editor.dispatch(tr) }
    cursorInFirstCell(editor)
    return editor
}

/// A keymap-only extension, to test how shortcuts merge.
private final class KeyExtension: Extension {
    let name: String
    let priority: Int
    let key: String
    let fired: Fired
    final class Fired: @unchecked Sendable { var by: [String] = [] }
    init(name: String, priority: Int, key: String, fired: Fired) {
        self.name = name; self.priority = priority; self.key = key; self.fired = fired
    }
    func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        let fired = self.fired, name = self.name
        return [key: { _, _, _ in fired.by.append(name); return true }]
    }
}

/// A mark extension that says nothing about HTML.
private final class PlainMark: MarkExtension {
    let name = "plain"
    var markSpec: MarkSpec { MarkSpec() }
}

func registerEdgeCommandTests() {
    // MARK: Image commands addressed by node type

    test("setImageSize(type): resizes the image of that type the selection addresses") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("before")])),
            try s.node("image", ["src": .string("/a.png")]),
        ])))
        let imageType = s.nodes["image"]!
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 8)))
        try expect(editor.run(setImageSize(imageType, width: 320, height: nil)))
        try expectEqual(editor.doc.nodeAt(8)?.attrs["width"], .int(320))
        try expectEqual(editor.doc.nodeAt(8)?.attrs["height"], .null)
        // Asking for the other image type finds nothing at the position.
        try expect(!editor.run(setImageSize(s.nodes["imageBlock"]!, width: 1, height: 1, pos: 8)))
        try expect(!editor.can(setImageSize(imageType, width: 1, height: 1, pos: 0)), "a paragraph isn't an image")
    }

    test("setImageModel(type): records and clears the image's model") {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("before")])),
            try s.node("image", ["src": .string("/a.png")]),
        ])))
        let imageType = s.nodes["image"]!
        try expect(editor.run(setImageModel(imageType, ImageModel(path: "/orig.png", width: 640, height: 480), pos: 8)))
        try expectEqual(editor.doc.nodeAt(8)?.imageModel?.path, "/orig.png")
        try expectEqual(editor.doc.nodeAt(8)?.imageModel?.width, 640)
        try expect(editor.run(setImageModel(imageType, nil, pos: 8)))
        try expectNil(editor.doc.nodeAt(8)?.imageModel)
        try expect(!editor.run(setImageModel(imageType, nil)), "nothing addressed without a selection on it")
    }

    // MARK: Mentions through the API

    test("insertMention: places a mention at the selection, reading as @label or @id") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "hi ")
        caret(editor, 4)
        try expect(editor.insertMention(id: "u1", label: "Ann"))
        try expectEqual(editor.doc.textContent, "hi @Ann")
        try expect(editor.insertMention(id: "u2"))
        try expectEqual(editor.doc.textContent, "hi @Ann@u2", "without a label the id is the text")
        var mentions: [Attrs] = []
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "mention" { mentions.append(node.attrs) }
            return true
        }
        try expectEqual(mentions.count, 2)
        try expectEqual(mentions[0]["label"], .string("Ann"))
        try expectEqual(mentions[1]["label"], .null)
    }
    test("insertMention: an editor without the mention node declines") {
        let editor = try Editor(extensions: starterKit())
        try expect(!editor.insertMention(id: "u1"))
    }

    // MARK: Arrow keys between cells

    test("tableArrow: down and up move between rows, and out of the table at its edges") {
        let editor = try tableEditor()
        let cells = cellPositions(editor.doc)
        try expectEqual(cells.count, 4)
        try expectEqual(cellOfSelection(editor), cells[0])
        try expect(editor.run(tableArrow(.vert, 1)))
        try expectEqual(cellOfSelection(editor), cells[2], "down from (0,0) lands in (1,0)")
        try expect(editor.run(tableArrow(.vert, 1)))
        try expectNil(cellOfSelection(editor)) // down from the last row leaves the table
        try expect(editor.state.selection.head > cells[3])
        cursorInFirstCell(editor)
        try expect(editor.run(tableArrow(.vert, -1)))
        try expectNil(cellOfSelection(editor)) // up from the first row leaves the table
        try expect(editor.state.selection.head < cells[0])
    }

    test("tableArrow: left and right step to the neighbouring cell only from the cell's edge") {
        let editor = try tableEditor()
        let cells = cellPositions(editor.doc)
        try expect(editor.run(tableArrow(.horiz, 1)))
        try expectEqual(cellOfSelection(editor), cells[1])
        try expect(editor.run(tableArrow(.horiz, -1)))
        try expectEqual(cellOfSelection(editor), cells[0])
        // Mid-cell, the arrow is left to ordinary caret movement.
        editor.dispatch(try editor.state.tr.insertText("ab"))
        caret(editor, editor.state.selection.head - 1)
        try expect(!editor.run(tableArrow(.horiz, 1)))
        try expect(!editor.run(tableArrow(.vert, 1)), "vertical needs the caret at the cell's edge too")
    }

    test("tableArrow: a cell selection collapses to a caret in its head cell") {
        let editor = try tableEditor()
        let cells = cellPositions(editor.doc)
        editor.dispatch(editor.state.tr.setSelection(CellSelection.create(editor.doc, cells[0], cells[3])))
        try expect(editor.state.selection is CellSelection)
        try expect(editor.run(tableArrow(.horiz, 1)))
        try expect(editor.state.selection is TextSelection)
        try expectEqual(cellOfSelection(editor), cells[3])
    }

    test("tableShiftArrow: grows a cell selection one cell at a time and stops at the edge") {
        let editor = try tableEditor()
        let cells = cellPositions(editor.doc)
        try expect(editor.run(tableShiftArrow(.horiz, 1)))
        let first = editor.state.selection as? CellSelection
        try expectNotNil(first)
        try expectEqual(first?.anchorCell.pos, cells[0])
        try expectEqual(first?.headCell.pos, cells[1])
        try expect(editor.run(tableShiftArrow(.vert, 1)))
        try expectEqual((editor.state.selection as? CellSelection)?.headCell.pos, cells[3])
        try expect(!editor.run(tableShiftArrow(.horiz, 1)), "no cell to the right of the last column")
        try expect(!editor.run(tableShiftArrow(.vert, 1)), "no row below the last")
        // A vertical arrow with a non-empty text selection is not a cell move.
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, cells[0] + 2, cells[0] + 2)))
        editor.dispatch(try editor.state.tr.insertText("xy"))
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, cells[0] + 2, cells[0] + 4)))
        try expect(!editor.run(tableArrow(.vert, 1)))
    }

    // MARK: Cell selection JSON

    test("CellSelection JSON: round-trips, and out-of-range positions are clamped rather than trapped") {
        let editor = try tableEditor()
        let cells = cellPositions(editor.doc)
        let sel = CellSelection.create(editor.doc, cells[1], cells[2])
        let json = sel.toJSON()
        try expectEqual(json["type"], .string("cell"))
        try expectEqual(json["anchor"], .int(cells[1]))
        try expectEqual(json["head"], .int(cells[2]))
        try expect(CellSelection.fromCellJSON(editor.doc, json).eq(sel))
        let clamped = CellSelection.fromCellJSON(editor.doc, ["type": .string("cell"), "anchor": .int(-5), "head": .int(999_999)])
        try expect(clamped.from >= 0 && clamped.to <= editor.doc.content.size)
        try expect(!(clamped is CellSelection), "the document's ends aren't cells")
    }

    // MARK: Table geometry helpers

    test("findCell / colCount / nextCell / inSameTable: read a cell's place in its table") {
        let editor = try tableEditor()
        let doc = editor.doc
        let cells = cellPositions(doc)
        try expectEqual(findCell(doc.resolve(cells[0])), TableRect(left: 0, top: 0, right: 1, bottom: 1))
        try expectEqual(findCell(doc.resolve(cells[3])), TableRect(left: 1, top: 1, right: 2, bottom: 2))
        try expectEqual(colCount(doc.resolve(cells[1])), 1)
        try expectEqual(nextCell(doc.resolve(cells[0]), .horiz, 1)?.pos, cells[1])
        try expectEqual(nextCell(doc.resolve(cells[0]), .vert, 1)?.pos, cells[2])
        try expectNil(nextCell(doc.resolve(cells[1]), .horiz, 1))
        try expectNil(nextCell(doc.resolve(cells[0]), .vert, -1))
        try expect(inSameTable(doc.resolve(cells[0]), doc.resolve(cells[3])))
        // A second table: its cells are not in the first.
        caret(editor, editor.doc.content.size)
        try expect(editor.insertTable(rows: 1, cols: 1, withHeaderRow: false))
        let all = cellPositions(editor.doc)
        try expectEqual(all.count, 5)
        try expect(!inSameTable(editor.doc.resolve(all[0]), editor.doc.resolve(all[4])))
    }

    test("table commands: a node selection on the whole table still finds a cell to work from") {
        let editor = try tableEditor()
        var tablePos: Int?
        editor.doc.descendants { node, pos, _, _ in
            if tablePos == nil, node.type.name == "table" { tablePos = pos }
            return tablePos == nil
        }
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, tablePos!)))
        try expect(editor.run(addColumnAfter))
        try expectEqual(cellPositions(editor.doc).count, 6)
    }

    // MARK: The extension manager

    test("ExtensionManager: refuses a set of extensions with no document node") {
        try expectThrows { _ = try ExtensionManager([ParagraphExtension(), TextExtension()]) }
    }

    test("ExtensionManager.keyboardShortcuts: merges every extension's keymap, higher priority first") {
        let fired = KeyExtension.Fired()
        let low = KeyExtension(name: "low", priority: 50, key: "Mod-k", fired: fired)
        let high = KeyExtension(name: "high", priority: 200, key: "Mod-k", fired: fired)
        let other = KeyExtension(name: "other", priority: 100, key: "Shift-Mod-x", fired: fired) // modifiers out of order
        let manager = try ExtensionManager(starterKit() + [low, other, high])
        let shortcuts = manager.keyboardShortcuts(editor: nil)
        try expectNotNil(shortcuts[normalizeKeyName("Mod-b")]) // the starter kit's own bindings are there
        let state = EditorState.create(EditorStateConfig(schema: manager.schema))
        try expect(shortcuts[normalizeKeyName("Mod-k")]!(state, nil, nil))
        try expectEqual(fired.by, ["high"], "the higher-priority extension's binding wins")
        try expectNotNil(shortcuts[normalizeKeyName("Mod-Shift-x")]) // the key is stored under its normalized name
    }

    test("ExtensionManager.html(for:): a type's HTML spec, or nil for a name it doesn't know") {
        let manager = try ExtensionManager(starterKit() + [PlainMark()])
        try expectEqual(manager.html(for: "paragraph")?.tag, "p")
        try expectNil(manager.html(for: "marquee"))
        try expectNotNil(manager.html(for: "plain")) // a mark without HTML hints still has a (blank) spec
        try expectNil(manager.html(for: "plain")?.tag)
    }

    // MARK: Suggestion mode

    test("toggleSuggestionMode: flips the mode, and declines without the plugin") {
        let editor = try Editor(extensions: fullKit())
        try expectEqual(suggestionModeKey.getState(editor.state)?.enabled, false)
        try expect(editor.run(toggleSuggestionMode))
        try expectEqual(suggestionModeKey.getState(editor.state)?.enabled, true)
        try expect(editor.run(toggleSuggestionMode))
        try expectEqual(suggestionModeKey.getState(editor.state)?.enabled, false)
        let plain = try Editor(extensions: starterKit())
        try expect(!plain.run(toggleSuggestionMode))
    }

    // MARK: Leaving a block with Shift-Enter, indenting code

    test("Shift-Enter in a blockquote exits to a new paragraph after it") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "quote")
        try expect(editor.run("toggleBlockquote"))
        try expect(key(editor, "Shift-Enter"))
        try expectEqual(editor.doc.childCount, 2)
        try expectEqual(editor.doc.child(0).type.name, "blockquote")
        try expectEqual(editor.doc.child(1).type.name, "paragraph")
        try expect(editor.isActive(node: "paragraph") && !editor.isActive(node: "blockquote"), "the caret moved out")
        // Outside a blockquote the same key is a hard break.
        try expect(key(editor, "Shift-Enter"))
        try expectEqual(count(editor.doc, "hardBreak"), 1)
    }

    test("Tab and Shift-Tab in a code block indent and outdent the current line") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "code")
        try expect(editor.run("toggleCodeBlock"))
        caret(editor, 1)
        try expect(key(editor, "Tab"))
        try expectEqual(editor.doc.textContent, "  code")
        try expect(key(editor, "Shift-Tab"))
        try expectEqual(editor.doc.textContent, "code")
        try expect(!key(editor, "Shift-Tab"), "nothing left to remove")
        // A tab character counts as one level.
        editor.dispatch(try editor.state.tr.insertText("\t", 1))
        caret(editor, 3)
        try expect(key(editor, "Shift-Tab"))
        try expectEqual(editor.doc.textContent, "code")
        // Only the caret's own line is touched.
        editor.dispatch(try editor.state.tr.insertText("\n  second", editor.doc.content.size - 1))
        caret(editor, editor.doc.content.size - 1)
        try expect(key(editor, "Shift-Tab"))
        try expectEqual(editor.doc.textContent, "code\nsecond")
    }

    // MARK: Details, footnotes, wiki links, tasks

    test("setDetailsOpen: closing a section whose body holds the caret moves the caret to the summary") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "body")
        try expect(editor.run("setDetails"))
        var detailsPos: Int?, bodyParagraph: Int?
        editor.doc.descendants { node, pos, parent, _ in
            if detailsPos == nil, node.type.name == "details" { detailsPos = pos }
            if bodyParagraph == nil, node.type.name == "paragraph", parent?.type.name == "detailsContent" { bodyParagraph = pos + 1 }
            return true
        }
        caret(editor, bodyParagraph! + 2)
        let summaryEnd = detailsPos! + editor.doc.nodeAt(detailsPos!)!.child(0).nodeSize
        try expect(editor.state.selection.from > summaryEnd)
        editor.dispatch(setDetailsOpen(editor.state, pos: detailsPos!, open: false)!)
        try expect(editor.state.selection.from <= summaryEnd, "the caret is no longer in hidden content")
        try expect(editor.state.selection.from > detailsPos!)
    }

    test("footnoteLabelAtSelection: a selected reference answers with its label") {
        let editor = try Editor(extensions: fullKit() + footnoteExtensions())
        try type(editor, "text")
        try expect(editor.run("insertFootnote"))
        var refPos: Int?
        editor.doc.descendants { node, pos, _, _ in
            if refPos == nil, node.type.name == "footnoteReference" { refPos = pos }
            return refPos == nil
        }
        let label = editor.doc.nodeAt(refPos!)!.attrs["label"]?.stringValue
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, refPos!)))
        try expectEqual(footnoteLabelAtSelection(editor.state), label)
        caret(editor, 1)
        try expectNil(footnoteLabelAtSelection(editor.state))
    }

    test("unsetWikiLink: removes a selected wiki link and nothing else") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "see ")
        caret(editor, 5)
        try expect(editor.insertWikiLink(text: "Index"))
        var linkPos: Int?
        editor.doc.descendants { node, pos, _, _ in
            if linkPos == nil, node.type.name == "wikiLink" { linkPos = pos }
            return linkPos == nil
        }
        caret(editor, 1)
        try expect(!editor.run("unsetWikiLink"), "a text selection isn't a link")
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, linkPos!)))
        try expect(editor.run("unsetWikiLink"))
        try expectEqual(count(editor.doc, "wikiLink"), 0)
        try expectEqual(editor.doc.textContent, "see ")
    }

    test("toggleTaskChecked: declines outside a task item") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "plain")
        try expect(!editor.run("toggleTaskChecked"))
    }

    // MARK: Editor conveniences

    test("Editor.can: a dry run that dispatches nothing") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "abc")
        try expect(!editor.can(deleteSelection), "nothing selected")
        select(editor, 1, 3)
        try expect(editor.can(deleteSelection))
        try expectEqual(editor.doc.textContent, "abc", "can() must not change anything")
    }

    test("Editor.json: the document's JSON") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "abc")
        try expectEqual(editor.json()["type"], .string("doc"))
        try expectEqual(try Node.fromJSON(editor.schema, editor.json()), editor.doc)
    }

    test("Editor.isActive(node:): a selected leaf answers for its own type and attributes") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "x")
        caret(editor, 2)
        try expect(editor.insertImage(src: "/a.png", alt: "cat"))
        var imagePos: Int?
        editor.doc.descendants { node, pos, _, _ in
            if imagePos == nil, node.type.name == "image" { imagePos = pos }
            return imagePos == nil
        }
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, imagePos!)))
        try expect(editor.isActive(node: "image"))
        try expect(editor.isActive(node: "image", attrs: ["alt": .string("cat")]))
        try expect(!editor.isActive(node: "image", attrs: ["alt": .string("dog")]))
    }

    test("Editor.isActive(mark:) and attributes(ofMark:): an empty selection reads the stored marks, then the caret's") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "abc")
        caret(editor, 2)
        try expect(!editor.isActive(mark: "bold"))
        editor.dispatch(editor.state.tr.addStoredMark(editor.schema.mark("bold")))
        try expect(editor.isActive(mark: "bold"), "a stored mark counts as active")
        // A link over the text: the caret inside it reports the link's attributes.
        select(editor, 1, 4)
        try expect(editor.run(toggleMark(editor.schema.marks["link"]!, ["href": .string("/x")])))
        caret(editor, 2)
        try expectEqual(editor.attributes(ofMark: "link")?["href"], .string("/x"))
        try expectNil(editor.attributes(ofMark: "bold"))
        try expectNil(editor.attributes(ofNode: "blockquote")) // not inside one
    }

    test("Editor.insertContent(node): with no position, replaces the selection") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "abc")
        select(editor, 2, 3)
        try expect(editor.insertContent(editor.schema.text("XY")))
        try expectEqual(editor.doc.textContent, "aXYc")
    }

    test("Editor.searchQuery: the active query, or nil before a search") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "find me")
        try expect(editor.searchQuery == nil || editor.searchQuery?.search == "")
        editor.setSearch("me")
        try expectEqual(editor.searchQuery?.search, "me")
        try expectEqual(editor.searchMatches.count, 1)
    }

    test("CollabCursor.isCollapsed: a caret has no extent") {
        try expect(CollabCursor(id: "a", anchor: 3, head: 3, color: "#ff0000", label: "A").isCollapsed)
        try expect(!CollabCursor(id: "a", anchor: 3, head: 5, color: "#ff0000", label: "A").isCollapsed)
    }
}

// MARK: - MathML shapes the paste tests don't cover

/// The first math node's LaTeX in a pasted document.
private func mathML(_ inner: String, display: Bool = false) throws -> String? {
    let editor = try Editor(extensions: fullKit())
    let html = "<p><math\(display ? " display=\"block\"" : "")>\(inner)</math></p>"
    let doc = try HTMLParser.parse(html, schema: editor.schema)
    var found: String?
    doc.descendants { node, _, _, _ in
        if found == nil, node.type.name == "inlineMath" || node.type.name == "blockMath" {
            found = node.attrs["latex"]?.stringValue
        }
        return found == nil
    }
    return found
}

func registerMathMLShapeTests() {
    test("mathml: scripts below, above, and both become LaTeX scripts") {
        try expectEqual(try mathML("<msub><mi>x</mi><mn>1</mn></msub>"), "x_{1}")
        try expectEqual(try mathML("<msubsup><mi>x</mi><mn>1</mn><mn>2</mn></msubsup>"), "x_{1}^{2}")
        try expectEqual(try mathML("<munder><mo>∑</mo><mi>n</mi></munder>"), "\\sum_{n}")
        try expectEqual(try mathML("<munderover><mo>∑</mo><mn>0</mn><mi>n</mi></munderover>"), "\\sum_{0}^{n}")
        try expectEqual(try mathML("<mroot><mi>x</mi><mn>3</mn></mroot>"), "\\sqrt[3]{x}")
    }
    test("mathml: a fraction with no line is a binomial") {
        try expectEqual(try mathML("<mfrac linethickness=\"0\"><mi>n</mi><mi>k</mi></mfrac>"), "\\binom{n}{k}")
        try expectEqual(try mathML("<mfrac><mi>n</mi><mi>k</mi></mfrac>"), "\\frac{n}{k}")
    }
    test("mathml: a base that is already a group isn't braced twice") {
        try expectEqual(try mathML("<msup><mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow><mn>2</mn></msup>"), "{a+b}^{2}")
    }
    test("mathml: spaces, phantoms, unknown elements, and stray text") {
        try expectEqual(try mathML("<mi>a</mi><mspace width=\"1em\"/><mi>b</mi>"), "a\\;b")
        try expectEqual(try mathML("<mi>a</mi><mspace width=\"1em\"></mspace><mi>b</mi>"), "a\\;b")
        try expectEqual(try mathML("<mi>a</mi><mphantom><mi>b</mi></mphantom>"), "a")
        try expectEqual(try mathML("<mfancy><mi>a</mi></mfancy>"), "a", "an unknown wrapper keeps its content")
        try expectEqual(try mathML("<mrow>1 <mo>+</mo> 2</mrow>"), "1+2", "text straight in a row is kept")
    }
    test("mathml: an annotation in another encoding is skipped, not read as TeX") {
        let latex = try mathML("<semantics><mi>x</mi><annotation encoding=\"application/x-mathml\">ignored</annotation></semantics>")
        try expectEqual(latex, "x")
    }
}
