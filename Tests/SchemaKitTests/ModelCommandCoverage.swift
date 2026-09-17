import DocumentModel
import DocumentTransform
import EditorCommands
import EditorHistory
import EditorStateKit
import SchemaKit
import TestHarness

private final class ModelCommandCounter: @unchecked Sendable {
    var calls = 0
    func next() -> String { calls += 1; return "generated-\(calls)" }
}

private func modelCommandHistory(_ editor: Editor, original: EditorState) throws {
    let edited = editor.doc
    try edited.check()
    try expectEqual(EditorHistory.undoDepth(editor.state), 1)
    try expect(EditorHistory.undo(editor.state, { editor.dispatch($0) }))
    try expectEqual(editor.doc, original.doc)
    try expect(editor.state.selection.eq(original.selection))
    try expect(EditorHistory.redo(editor.state, { editor.dispatch($0) }))
    try expectEqual(editor.doc, edited)
}

private func mathCommand(_ operation: String, _ type: NodeType, pos: Int? = nil) -> Command {
    switch operation {
    case "insert": return insertMath(type, latex: "new", pos: pos)
    case "update": return updateMath(type, latex: "new", pos: pos)
    default: return deleteMath(type, pos: pos)
    }
}

func registerModelCommandCoverageTests() {
    test("model command coverage: a matching formula elsewhere cannot validate a refused insertion") {
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "paragraph allowedParagraph")),
            ("paragraph", NodeSpec(content: "text*")),
            ("allowedParagraph", NodeSpec(content: "inline*")),
            ("text", NodeSpec(group: "inline")),
            ("inlineMath", InlineMathExtension().nodeSpec)
        ])
        let doc = try schema.node("doc", content: .from([
            try schema.node("paragraph", content: .from(schema.text("keep"))),
            try schema.node("allowedParagraph", content: .from(try schema.node("inlineMath", ["latex": .string("new")])) )
        ]))
        let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: TextSelection.create(doc, 1, 5)))
        let command = insertMath(schema.nodes["inlineMath"]!, latex: "new")
        try expect(!command(state, nil, nil))
        var dispatched = false
        try expect(!command(state, { _ in dispatched = true }, nil))
        try expect(!dispatched)
        try expectEqual(state.doc, doc)
    }

    for name in ["inlineMath", "blockMath"] {
        test("model command coverage: explicit \(name) insertion preserves text and a distant caret through history") {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<p>ab</p><p>keep</p>")
            select(editor, editor.doc.content.size - 1, editor.doc.content.size - 1)
            let original = editor.state
            let command = insertMath(editor.schema.nodes[name]!, latex: "new", pos: 2)
            try expect(command(editor.state, nil, nil))
            try expect(editor.run(command))
            try expectEqual(count(editor.doc, name), 1)
            var plain = ""
            editor.doc.descendants { node, _, _, _ in
                if let text = node.text { plain += text }
                return true
            }
            try expectEqual(plain, "abkeep")
            try expectEqual(editor.state.selection.resolvedHead.parent.textContent, "keep")
            try expectEqual(editor.state.selection.resolvedHead.parentOffset, 4)
            try modelCommandHistory(editor, original: original)
        }
        test("model command coverage: replacing selected \(name) with the same source still succeeds") {
            let editor = try Editor(extensions: fullKit())
            let s = editor.schema
            let node = try s.node(name, ["latex": .string("same")])
            let doc = try s.node("doc", content: .from(name == "inlineMath"
                ? try s.node("paragraph", content: .from(node)) : node))
            editor.setContent(doc)
            let pos = name == "inlineMath" ? 1 : 0
            editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, pos)))
            let command = insertMath(s.nodes[name]!, latex: "same")
            try expect(command(editor.state, nil, nil))
            try expect(editor.run(command))
            try expectEqual(editor.doc, doc)
        }
        for operation in ["insert", "update", "delete"] {
            test("model command coverage: \(name) \(operation) preserves surrounding content and history") {
                let editor = try Editor(extensions: fullKit())
                let s = editor.schema, type = s.nodes[name]!
                let atom = try s.node(name, ["latex": .string("old")])
                let paragraph = try s.node("paragraph", content: .from(s.text("keep")))
                let doc: Node
                let pos: Int
                if name == "inlineMath" {
                    doc = try s.node("doc", content: .from(try s.node("paragraph", content: .from([
                        s.text("a"), atom, s.text("z")
                    ]))))
                    pos = 2
                } else {
                    doc = try s.node("doc", content: .from([paragraph, atom, paragraph]))
                    pos = paragraph.nodeSize
                }
                editor.setContent(doc)
                editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, pos)))
                let original = editor.state
                let command = mathCommand(operation, type)
                try expect(command(original, nil, nil))
                try expect(editor.run(command))
                try expectEqual(count(editor.doc, name), operation == "delete" ? 0 : 1)
                if operation != "delete" {
                    var latex: String?
                    editor.doc.descendants { node, _, _, _ in
                        if node.type === type { latex = node.attrs["latex"]?.stringValue }
                        return true
                    }
                    try expectEqual(latex, "new")
                }
                if name == "inlineMath" {
                    try expectEqual(editor.doc.firstChild?.firstChild?.text, operation == "delete" ? "az" : "a")
                    try expectEqual(editor.doc.firstChild?.lastChild?.text, operation == "delete" ? "az" : "z")
                } else {
                    try expectEqual(editor.doc.firstChild, paragraph)
                    try expectEqual(editor.doc.lastChild, paragraph)
                }
                try modelCommandHistory(editor, original: original)
            }
            test("model command coverage: \(name) \(operation) rejects invalid explicit positions without side effects") {
                let editor = try Editor(extensions: fullKit())
                try editor.setContent(html: "<p>keep</p>")
                let original = editor.state, revision = editor.docRevision
                let counter = ModelCommandCounter()
                editor.onTransaction = { _ in counter.calls += 1 }
                for pos in [-1, editor.doc.content.size + 1, Int.max] {
                    let command = mathCommand(operation, editor.schema.nodes[name]!, pos: pos)
                    try expect(!command(editor.state, nil, nil))
                    try expect(!editor.run(command))
                    try expect(editor.state === original)
                }
                try expectEqual(editor.docRevision, revision)
                try expectEqual(counter.calls, 0)
                try expectEqual(EditorHistory.undoDepth(editor.state), 0)
            }
        }
        for explicit in [false, true] {
            test("model command coverage: \(name) insertion refuses forbidden content with \(explicit ? "explicit position" : "selection")") {
                let schema = try Schema(nodes: [
                    ("doc", NodeSpec(content: "paragraph+")),
                    ("paragraph", NodeSpec(content: "text*")),
                    ("text", NodeSpec(group: "inline")),
                    ("inlineMath", InlineMathExtension().nodeSpec),
                    ("blockMath", BlockMathExtension().nodeSpec)
                ])
                let doc = try schema.node("doc", content: .from(try schema.node("paragraph", content: .from(schema.text("keep")))))
                let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc,
                    selection: TextSelection.create(doc, 1, 5)))
                let command = insertMath(schema.nodes[name]!, latex: "new", pos: explicit ? 3 : nil)
                let available = command(state, nil, nil)
                var transaction: Transaction?
                let performed = command(state, { transaction = $0 }, nil)
                try expectEqual(transaction?.doc ?? doc, doc, "a refused formula must not erase selected text")
                try expect(!available)
                try expect(!performed)
                try expect(transaction == nil)
                try expectEqual(state.doc, doc)
            }
        }
    }

    for mode in ["caret", "text selection", "reference selection"] {
        test("model command coverage: footnote insertion from \(mode) undoes both halves") {
            let editor = try Editor(extensions: starterKit() + footnoteExtensions())
            let s = editor.schema
            let contents: [Node] = mode == "reference selection"
                ? [s.text("a"), try s.node("footnoteReference", ["label": .string("old")]), s.text("z")]
                : [s.text("abcd")]
            editor.setContent(try s.node("doc", content: .from(try s.node("paragraph", content: .from(contents)))))
            if mode == "reference selection" {
                editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 2)))
            } else {
                select(editor, 2, mode == "caret" ? 2 : 4)
            }
            let original = editor.state
            try expect(editor.run(insertFootnote))
            try expectEqual(footnoteDefinitions(editor.doc).map(\.label), ["1"])
            try expectEqual(footnoteReferences(editor.doc).map(\.label), ["1"])
            try expectEqual(editor.state.selection.resolvedFrom.node(-1).type.name, "footnoteDefinition")
            try modelCommandHistory(editor, original: original)
        }
    }
    for fromDefinition in [false, true] {
        test("model command coverage: footnote removal from \(fromDefinition ? "definition" : "reference") restores repeated references on undo") {
            let editor = try Editor(extensions: starterKit() + footnoteExtensions())
            let s = editor.schema
            let ref = try s.node("footnoteReference", ["label": .string("note")])
            let definition = try s.node("footnoteDefinition", ["label": .string("note")], content: .from(
                try s.node("paragraph", content: .from(s.text("body")))))
            editor.setContent(try s.node("doc", content: .from([
                try s.node("paragraph", content: .from([s.text("a"), ref, s.text("b"), ref])), definition
            ])))
            let pos = fromDefinition ? footnoteDefinitions(editor.doc)[0].pos : footnoteReferences(editor.doc)[0].pos
            editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, pos)))
            let original = editor.state
            try expect(editor.run(removeFootnote))
            try expectEqual(footnoteDefinitions(editor.doc).count, 0)
            try expectEqual(footnoteReferences(editor.doc).count, 0)
            try expectEqual(editor.doc.textContent, "ab")
            try modelCommandHistory(editor, original: original)
        }
    }
    test("model command coverage: removing an absent footnote leaves selection revision and history unchanged") {
        let editor = try Editor(extensions: starterKit() + footnoteExtensions())
        try editor.setContent(html: "<p>no footnote</p>")
        select(editor, 3, 5)
        let original = editor.state, revision = editor.docRevision
        try expect(!removeFootnote(editor.state, nil, nil))
        try expect(!editor.run(removeFootnote))
        try expect(editor.state === original)
        try expectEqual(editor.docRevision, revision)
        try expectEqual(EditorHistory.undoDepth(editor.state), 0)
    }
    for orphanDefinition in [false, true] {
        test("model command coverage: inserted footnote avoids labels reserved by an orphan \(orphanDefinition ? "definition" : "reference")") {
            let editor = try Editor(extensions: starterKit() + footnoteExtensions())
            let s = editor.schema
            let paragraph = try s.node("paragraph", content: .from(s.text("keep")))
            let orphan = orphanDefinition
                ? try s.node("footnoteDefinition", ["label": .string("1")], content: .from(paragraph))
                : try s.node("paragraph", content: .from(try s.node("footnoteReference", ["label": .string("1")])))
            editor.setContent(try s.node("doc", content: .from([paragraph, orphan])))
            select(editor, 2, 2)
            let original = editor.state
            try expect(editor.run(insertFootnote))
            try expect(footnoteReferences(editor.doc).contains { $0.label == "2" })
            try expect(footnoteDefinitions(editor.doc).contains { $0.label == "2" })
            try expectEqual(editor.doc.child(1), orphan)
            try modelCommandHistory(editor, original: original)
        }
    }

    test("model command coverage: unique IDs survive splitting undo and redo unchanged") {
        let counter = ModelCommandCounter()
        let editor = try Editor(extensions: starterKit() + [UniqueIDExtension(types: ["paragraph"], generateID: { counter.next() })])
        try editor.setContent(html: "<p>abcd</p>")
        select(editor, 3, 3)
        let original = editor.state
        try expect(editor.run(splitBlock))
        let edited = editor.doc
        let first = edited.child(0).attrs["id"], second = edited.child(1).attrs["id"]
        try expectEqual(first, original.doc.child(0).attrs["id"])
        try expect(first != second)
        try modelCommandHistory(editor, original: original)
        try expectEqual(editor.doc.child(0).attrs["id"], first)
        try expectEqual(editor.doc.child(1).attrs["id"], second)
    }
    test("model command coverage: pasted nested duplicate IDs preserve the existing block's identity") {
        let counter = ModelCommandCounter()
        let editor = try Editor(extensions: starterKit() + [UniqueIDExtension(types: ["paragraph"], generateID: { counter.next() })])
        try editor.setContent(html: "<p>keep</p>")
        let original = editor.state, s = editor.schema
        let copied = original.doc.child(0)
        let nested = try s.node("blockquote", content: .from([copied, copied]))
        let tr = try editor.state.tr.insert(editor.doc.content.size, nested)
        editor.dispatch(tr)
        var ids: [String] = []
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "paragraph", let id = node.attrs["id"]?.stringValue { ids.append(id) }
            return true
        }
        try expectEqual(ids.count, 3)
        try expectEqual(Set(ids).count, 3)
        try expectEqual(editor.doc.child(0), copied)
        try modelCommandHistory(editor, original: original)
    }
    test("model command coverage: selection and metadata changes do not regenerate IDs") {
        let counter = ModelCommandCounter()
        let editor = try Editor(extensions: starterKit() + [UniqueIDExtension(types: ["paragraph"], generateID: { counter.next() })])
        try editor.setContent(html: "<p>keep</p>")
        let original = editor.doc, calls = counter.calls, revision = editor.docRevision
        select(editor, 2, 4)
        editor.dispatch(editor.state.tr.setMeta("unrelated", true))
        try expectEqual(counter.calls, calls)
        try expectEqual(editor.doc, original)
        try expectEqual(editor.docRevision, revision)
        try expectEqual(EditorHistory.undoDepth(editor.state), 0)
    }
    test("model command coverage: filtered ID assignment resumes on the next eligible document edit") {
        let counter = ModelCommandCounter()
        let editor = try Editor(extensions: starterKit() + [UniqueIDExtension(types: ["paragraph"],
            generateID: { counter.next() }, filterTransaction: { ($0.getMeta("remote") as? Bool) != true })])
        try editor.setContent(html: "<p>keep</p>")
        let originalID = editor.doc.child(0).attrs["id"]
        let duplicate = editor.doc.child(0)
        let remote = try editor.state.tr.insert(editor.doc.content.size, duplicate)
        remote.setMeta("remote", true)
        let calls = counter.calls
        editor.dispatch(remote)
        try expectEqual(counter.calls, calls)
        try expectEqual(editor.doc.child(1).attrs["id"], originalID)
        editor.dispatch(try editor.state.tr.insertText("x", 1))
        try expectEqual(editor.doc.child(0).attrs["id"], originalID)
        try expect(editor.doc.child(1).attrs["id"] != originalID)
        try editor.doc.check()
    }
}
