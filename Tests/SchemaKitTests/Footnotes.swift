import Foundation
import DocumentModel
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
