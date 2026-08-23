import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

// Tests for every Markdown-style input-rule shortcut, driven through the editor
// the way the renderer does: type the prefix, then fire the triggering
// character through the plugins' handleTextInput.

/// Type `prefix` into a fresh editor, then trigger the input rule by sending
/// `trigger` as text input at the end. Returns the editor.
@Sendable private func shortcut(_ prefix: String, _ trigger: String) throws -> Editor {
    let editor = try Editor(extensions: starterKit())
    if !prefix.isEmpty { try type(editor, prefix) }
    let pos = max(1, editor.doc.content.size - 1)
    _ = textInput(editor, at: pos, trigger)
    return editor
}

private func hasMark(_ editor: Editor, _ name: String) -> Bool {
    guard let type = editor.schema.marks[name] else { return false }
    return editor.doc.rangeHasMark(0, editor.doc.content.size, type)
}

private func topBlock(_ editor: Editor) -> Node? { editor.doc.firstChild }

func registerMarkdownShortcutTests() {
    // MARK: Block shortcuts

    test("md shortcut: '# ' → heading level 1") {
        let editor = try shortcut("#", " ")
        try expect(editor.isActive(node: "heading", attrs: ["level": .int(1)]))
    }

    test("md shortcut: '### ' → heading level 3") {
        let editor = try shortcut("###", " ")
        try expect(editor.isActive(node: "heading", attrs: ["level": .int(3)]))
    }

    test("md shortcut: '> ' → blockquote") {
        let editor = try shortcut(">", " ")
        try expect(editor.isActive(node: "blockquote"))
    }

    test("md shortcut: '- ' → bullet list") {
        let editor = try shortcut("-", " ")
        try expect(editor.isActive(node: "bulletList"))
    }

    test("md shortcut: '* ' → bullet list") {
        let editor = try shortcut("*", " ")
        try expect(editor.isActive(node: "bulletList"))
    }

    test("md shortcut: '1. ' → ordered list") {
        let editor = try shortcut("1.", " ")
        try expect(editor.isActive(node: "orderedList"))
    }

    // MARK: Inline mark shortcuts (text stripped of markers, mark applied)

    test("md shortcut: **bold** strips markers and bolds the text") {
        let editor = try shortcut("**bold*", "*")
        try expectEqual(editor.doc.textContent, "bold")
        try expect(hasMark(editor, "bold"))
    }

    test("md shortcut: __bold__ also bolds") {
        let editor = try shortcut("__bold_", "_")
        try expectEqual(editor.doc.textContent, "bold")
        try expect(hasMark(editor, "bold"))
    }

    test("md shortcut: *italic* strips markers and italicizes") {
        let editor = try shortcut("*it", "*")
        try expectEqual(editor.doc.textContent, "it")
        try expect(hasMark(editor, "italic"))
        try expect(!hasMark(editor, "bold"))
    }

    test("md shortcut: ~~strike~~ strips markers and strikes") {
        let editor = try shortcut("~~no~", "~")
        try expectEqual(editor.doc.textContent, "no")
        try expect(hasMark(editor, "strike"))
    }

    test("md shortcut: `code` strips backticks and marks code") {
        let editor = try shortcut("`x", "`")
        try expectEqual(editor.doc.textContent, "x")
        try expect(hasMark(editor, "code"))
    }

    test("md shortcut: *italic* does not fire while typing the first * of **bold**") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "**bold")
        _ = textInput(editor, at: editor.doc.content.size - 1, "*") // now "**bold*"
        try expect(!hasMark(editor, "italic"))
        try expect(!hasMark(editor, "bold")) // not closed yet
    }

    test("md shortcut: ``` → code block") {
        let editor = try shortcut("``", "`")
        try expect(editor.isActive(node: "codeBlock"))
    }

    test("md shortcut: '[ ] ' → task list") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "[ ]")
        _ = textInput(editor, at: editor.doc.content.size - 1, " ")
        try expect(editor.isActive(node: "taskList"))
        try expect(editor.isActive(node: "taskItem"))
    }

    // MARK: Wiki link

    test("md shortcut: [[Page]] becomes a wiki-link node") {
        // wiki links are in the full kit, not the starter kit.
        let editor = try Editor(extensions: fullKit())
        try type(editor, "[[Page]")
        _ = textInput(editor, at: editor.doc.content.size - 1, "]")
        var count = 0
        var target: String?
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "wikiLink" { count += 1; target = node.attrs["text"]?.stringValue }
            return true
        }
        try expectEqual(count, 1)
        try expectEqual(target, "Page")
    }

    test("md shortcut: [[Target|Label]] reads as the label") {
        let editor = try Editor(extensions: fullKit())
        try type(editor, "[[Home|Start]")
        _ = textInput(editor, at: editor.doc.content.size - 1, "]")
        var node: Node?
        editor.doc.descendants { n, _, _, _ in if n.type.name == "wikiLink" { node = n }; return true }
        try expectEqual(node?.attrs["text"]?.stringValue, "Start")
    }

    // MARK: Smart typography

    test("md shortcut: -- becomes an em dash") {
        let editor = try shortcut("a-", "-")
        try expectEqual(editor.doc.textContent, "a\u{2014}")
    }

    test("md shortcut: ... becomes an ellipsis") {
        let editor = try shortcut("x..", ".")
        try expectEqual(editor.doc.textContent, "x\u{2026}")
    }

    test("md shortcut: opening and closing curly double quotes") {
        let opening = try shortcut("", "\"")
        try expectEqual(opening.doc.textContent, "\u{201C}")
        let closing = try shortcut("hi", "\"")
        try expectEqual(closing.doc.textContent, "hi\u{201D}")
    }

    test("md shortcut: apostrophe becomes a closing single curly quote") {
        let editor = try shortcut("don", "'")
        try expectEqual(editor.doc.textContent, "don\u{2019}")
    }
}
