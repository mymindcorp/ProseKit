import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestHarness

// The footnote extension: inserting, removing, numbering, and the fact that
// nothing gets them unless it asks.

private func footnoteEditor() throws -> Editor {
    try Editor(extensions: starterKit() + footnoteExtensions())
}

/// The document as a list of top-level node names.
private func shape(_ editor: Editor) -> [String] {
    (0..<editor.doc.childCount).map { editor.doc.child($0).type.name }
}

func registerFootnoteTests() {
    for selectedType in ["mention", "inlineMath", "wikiLink"] {
        for insideDefinition in [false, true] {
            test("footnotes: selected \(selectedType) beside a reference, inside definition \(insideDefinition)") {
                let editor = try Editor(extensions: fullKit() + footnoteExtensions())
                let schema = editor.schema
                let reference = try schema.node("footnoteReference", ["label": .string("a")])
                let selected = try schema.node(selectedType, selectedType == "mention" ? ["id": .string("user")] : [:])
                let paragraph = try schema.node("paragraph", content: .from([reference, selected]))
                let definitionA = try schema.node("footnoteDefinition", ["label": .string("a")],
                    content: .from(schema.node("paragraph", content: .from(schema.text("keep note")))))
                let body = try insideDefinition
                    ? schema.node("footnoteDefinition", ["label": .string("b")], content: .from(paragraph)) : paragraph
                editor.setContent(try schema.node("doc", content: .from([body, definitionA])))
                let pos = insideDefinition ? 3 : 2
                editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, pos)))
                let original = editor.state
                try expectEqual(footnoteLabelAtSelection(editor.state), insideDefinition ? "b" : nil)
                try expectEqual(editor.can(removeFootnote), insideDefinition)
                try expectEqual(editor.run("removeFootnote"), insideDefinition)
                if insideDefinition {
                    try expectEqual(footnoteDefinitions(editor.doc).map(\.label), ["a"])
                    try expectEqual(editor.doc.lastChild, definitionA)
                } else {
                    try expect(editor.state === original, "Selecting another atom must not delete a neighboring footnote")
                }
            }
        }
    }
    test("footnotes: insertion is atomic when the schema rejects either half") {
        for allowReference in [false, true] {
            let schema = try Schema(nodes: [
                ("doc", NodeSpec(content: allowReference ? "paragraph+" : "paragraph footnoteDefinition*")),
                ("paragraph", NodeSpec(content: allowReference ? "inline*" : "text*")),
                ("text", NodeSpec(group: "inline")),
                ("footnoteReference", FootnoteReferenceExtension().nodeSpec),
                ("footnoteDefinition", NodeSpec(content: "paragraph+", attrs: ["label": AttributeSpec(default: .string(""))]))
            ])
            let paragraph = try schema.node("paragraph", content: Fragment.from(schema.text("keep")))
            let doc = try schema.node("doc", content: Fragment.from(paragraph))
            let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: TextSelection.create(doc, 1, 5)))
            try expect(!insertFootnote(state, nil, nil))
            var dispatched = false
            try expect(!insertFootnote(state, { _ in dispatched = true }, nil))
            try expect(!dispatched)
            try expectEqual(state.doc, doc)
        }
    }

    for requiredReference in [false, true] {
        for fromDefinition in [false, true] {
            test("footnotes: removal is atomic with required reference \(requiredReference), from definition \(fromDefinition)") {
                let schema = try Schema(nodes: [
                    ("doc", NodeSpec(content: "paragraph footnoteDefinition*")),
                    ("paragraph", NodeSpec(content: requiredReference ? "text* footnoteReference text*" : "inline*")),
                    ("text", NodeSpec(group: "inline")),
                    ("footnoteReference", FootnoteReferenceExtension().nodeSpec),
                    ("footnoteDefinition", NodeSpec(content: "note", attrs: ["label": AttributeSpec(default: .string(""))])),
                    ("note", NodeSpec(content: "text*"))
                ])
                let reference = try schema.node("footnoteReference", ["label": .string("a")])
                let paragraph = try schema.node("paragraph", content: Fragment.from([schema.text("keep"), reference]))
                let definition = try schema.node("footnoteDefinition", ["label": .string("a")],
                    content: Fragment.from(schema.node("note", content: Fragment.from(schema.text("note")))))
                let doc = try schema.node("doc", content: Fragment.from([paragraph, definition]))
                let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc,
                    selection: TextSelection.create(doc, fromDefinition ? paragraph.nodeSize + 2 : 5)))
                var result: Node?
                try expectEqual(removeFootnote(state, { result = $0.doc }, nil), !requiredReference)
                if requiredReference {
                    try expect(result == nil, "Cannot remove one half of a footnote")
                } else {
                    try expectEqual(result?.textContent, "keep")
                    try expectEqual(result?.childCount, 1)
                    try result?.check()
                }
                try expectEqual(removeFootnote(state, nil, nil), !requiredReference)
                try expectEqual(state.doc, doc)
            }
        }
    }

    for requiredDefinition in [false, true] {
        for fromDefinition in [false, true] {
            test("footnotes: required definition removal \(requiredDefinition), from definition \(fromDefinition)") {
                let schema = try Schema(nodes: [
                    ("doc", NodeSpec(content: requiredDefinition ? "paragraph footnoteDefinition" : "paragraph footnoteDefinition*")),
                    ("paragraph", NodeSpec(content: "inline*")),
                    ("text", NodeSpec(group: "inline")),
                    ("footnoteReference", FootnoteReferenceExtension().nodeSpec),
                    ("footnoteDefinition", NodeSpec(content: "paragraph+", attrs: ["label": AttributeSpec(default: .string(""))]))
                ])
                let reference = try schema.node("footnoteReference", ["label": .string("a")])
                let paragraph = try schema.node("paragraph", content: Fragment.from([schema.text("keep"), reference]))
                let definition = try schema.node("footnoteDefinition", ["label": .string("a")],
                    content: Fragment.from(schema.node("paragraph", content: Fragment.from(schema.text("note")))))
                let doc = try schema.node("doc", content: Fragment.from([paragraph, definition]))
                let state = EditorState.create(EditorStateConfig(schema: schema, doc: doc,
                    selection: TextSelection.create(doc, fromDefinition ? paragraph.nodeSize + 2 : 5)))
                var result: Node?
                let handled = removeFootnote(state, { result = $0.doc }, nil)
                if requiredDefinition {
                    try expect(result == nil, "Do not erase the note and leave an anonymous replacement definition")
                } else {
                    try expectEqual(result?.textContent, "keep")
                    try expectEqual(result?.childCount, 1)
                    try result?.check()
                }
                try expectEqual(handled, !requiredDefinition)
                try expectEqual(removeFootnote(state, nil, nil), !requiredDefinition)
            }
        }
    }

    test("footnotes: removing the sole definition leaves a valid empty paragraph") {
        let editor = try footnoteEditor()
        let schema = editor.schema
        let definition = try schema.node("footnoteDefinition", ["label": .string("a")],
            content: Fragment.from(schema.node("paragraph", content: Fragment.from(schema.text("note")))))
        editor.setContent(try schema.node("doc", content: Fragment.from(definition)))
        select(editor, 2, 2)
        try expect(editor.run("removeFootnote"))
        try expectEqual(editor.doc, try schema.node("doc", content: Fragment.from(schema.node("paragraph"))))
        try editor.doc.check()
    }

    test("footnotes: a selected definition can be removed") {
        let editor = try footnoteEditor()
        try expect(editor.run("insertFootnote"))
        let pos = footnoteDefinitions(editor.doc)[0].pos
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, pos)))
        try expectEqual(footnoteLabelAtSelection(editor.state), "1")
        try expect(editor.run("removeFootnote"))
        try expectEqual(footnoteDefinitions(editor.doc).count, 0)
        try expectEqual(footnoteReferences(editor.doc).count, 0)
        try editor.doc.check()
    }

    test("footnotes: a selected reference targets its own label inside another definition") {
        let editor = try footnoteEditor()
        let s = editor.schema
        let reference = try s.node("footnoteReference", ["label": .string("a")])
        editor.setContent(try s.node("doc", content: Fragment.from([
            try s.node("footnoteDefinition", ["label": .string("a")],
                       content: Fragment.from(try s.node("paragraph", content: Fragment.from(s.text("A"))))),
            try s.node("footnoteDefinition", ["label": .string("b")],
                       content: Fragment.from(try s.node("paragraph", content: Fragment.from([s.text("See "), reference]))))
        ])))
        let pos = footnoteReferences(editor.doc)[0].pos
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, pos)))
        try expectEqual(footnoteLabelAtSelection(editor.state), "a")
        try expect(editor.run("removeFootnote"))
        try expectEqual(footnoteDefinitions(editor.doc).map(\.label), ["b"])
        try expectEqual(editor.doc.lastChild?.textContent, "See ")
        try editor.doc.check()
    }

    test("footnotes: removal also clears references inside other definitions") {
        let editor = try footnoteEditor()
        let s = editor.schema
        let reference = try s.node("footnoteReference", ["label": .string("a")])
        editor.setContent(try s.node("doc", content: Fragment.from([
            try s.node("paragraph", content: Fragment.from(reference)),
            try s.node("footnoteDefinition", ["label": .string("a")],
                       content: Fragment.from(try s.node("paragraph", content: Fragment.from(s.text("A"))))),
            try s.node("footnoteDefinition", ["label": .string("b")],
                       content: Fragment.from(try s.node("paragraph", content: Fragment.from([s.text("See "), reference]))))
        ])))
        select(editor, 1, 1)
        try expect(editor.run("removeFootnote"))
        try expectEqual(footnoteReferences(editor.doc).map(\.label), [])
        try expectEqual(footnoteDefinitions(editor.doc).map(\.label), ["b"])
        try expectEqual(editor.doc.lastChild?.textContent, "See ")
        try editor.doc.check()
    }

    test("footnotes: not registered by default") {
        let plain = try Editor(extensions: fullKit())
        try expect(plain.schema.nodes["footnoteReference"] == nil,
                   "fullKit shouldn't carry the footnote nodes")
        try expect(plain.schema.nodes["footnoteDefinition"] == nil,
                   "fullKit shouldn't carry the footnote nodes")
        let opted = try footnoteEditor()
        try expect(opted.schema.nodes["footnoteReference"] != nil, "the extension should add them")
        try expect(opted.schema.nodes["footnoteDefinition"] != nil, "the extension should add them")
    }

    test("footnotes: insert puts a reference in the text and its note at the end") {
        let editor = try footnoteEditor()
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from([
            try editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text("hello")])),
        ])))
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 6)))
        try expect(editor.run("insertFootnote"), "insertFootnote should run")
        try expectEqual(shape(editor), ["paragraph", "footnoteDefinition"])
        try expectEqual(editor.doc.child(0).child(1).type.name, "footnoteReference")
        try expectEqual(editor.doc.child(0).child(1).attrs["label"], .string("1"))
        try expectEqual(editor.doc.child(1).attrs["label"], .string("1"))
        // The caret waits in the note, which is what you type next.
        let resolved = editor.doc.resolve(editor.state.selection.from)
        try expectEqual(resolved.node(1).type.name, "footnoteDefinition")
    }

    test("footnotes: each insert takes the next free label") {
        let editor = try footnoteEditor()
        for _ in 0..<3 {
            editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 1)))
            try expect(editor.run("insertFootnote"), "insertFootnote should run")
        }
        let labels = footnoteDefinitions(editor.doc).map(\.label).sorted()
        try expectEqual(labels, ["1", "2", "3"])
    }

    test("footnotes: a label already in use is skipped") {
        let editor = try footnoteEditor()
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("a"), try s.node("footnoteReference", ["label": .string("1")]),
            ])),
            try s.node("footnoteDefinition", ["label": .string("1")],
                       content: Fragment.from([try s.node("paragraph")])),
        ])))
        try expectEqual(nextFootnoteLabel(editor.doc), "2")
    }

    test("footnotes: numbering follows the reading order, not the labels") {
        let editor = try footnoteEditor()
        let s = editor.schema
        func reference(_ label: String) throws -> Node {
            try s.node("footnoteReference", ["label": .string(label)])
        }
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("a"), try reference("zebra"), s.text("b"), try reference("alpha"),
                s.text("c"), try reference("zebra"),
            ])),
            // A note nothing refers to still gets a number, after the rest.
            try s.node("footnoteDefinition", ["label": .string("orphan")],
                       content: Fragment.from([try s.node("paragraph")])),
        ])))
        let numbers = footnoteNumbers(editor.doc)
        try expectEqual(numbers["zebra"], 1)   // read first
        try expectEqual(numbers["alpha"], 2)
        try expectEqual(numbers["orphan"], 3)  // referred to by nothing
    }

    test("footnotes: remove takes the reference and the note together") {
        let editor = try footnoteEditor()
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 1)))
        try expect(editor.run("insertFootnote"), "insertFootnote should run")
        try expectEqual(shape(editor), ["paragraph", "footnoteDefinition"])
        // The caret is in the note, which is one of the two places you'd do this.
        try expect(editor.run("removeFootnote"), "removeFootnote should run")
        try expectEqual(shape(editor), ["paragraph"])
        try expectEqual(footnoteReferences(editor.doc).count, 0)
    }

    test("footnotes: remove works from beside the reference too") {
        let editor = try footnoteEditor()
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 1)))
        try expect(editor.run("insertFootnote"), "insertFootnote should run")
        // Put the caret just after the reference in the text.
        let referencePos = footnoteReferences(editor.doc)[0].pos
        editor.dispatch(editor.state.tr.setSelection(
            TextSelection.create(editor.doc, referencePos + 1)))
        try expect(editor.run("removeFootnote"), "removeFootnote should run")
        try expectEqual(footnoteReferences(editor.doc).count, 0)
        try expectEqual(footnoteDefinitions(editor.doc).count, 0)
    }

    test("footnotes: remove does nothing away from one") {
        let editor = try footnoteEditor()
        try expect(editor.run("removeFootnote") == false, "nothing to remove")
    }

    test("footnotes: no reference inside a code block") {
        let editor = try footnoteEditor()
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("codeBlock", [:], content: Fragment.from([s.text("let x = 1")])),
        ])))
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 2)))
        try expect(editor.run("insertFootnote") == false, "a code block holds no footnote")
    }

    test("footnotes: the document stays valid after inserting and removing") {
        let editor = try footnoteEditor()
        for _ in 0..<4 {
            editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 1)))
            _ = editor.run("insertFootnote")
            try editor.doc.check()
        }
        while editor.run("removeFootnote") { try editor.doc.check() }
        try editor.doc.check()
    }
}
