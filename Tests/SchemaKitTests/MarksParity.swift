import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestHarness

// Subscript / superscript (mutually exclusive) and text / background color
// marks, plus color, highlight and link marks applied and cleared across a
// cell selection.

private func colorAttr(_ editor: Editor, _ markName: String) -> String? {
    guard let type = editor.schema.marks[markName] else { return nil }
    var found: String?
    editor.doc.descendants { node, _, _, _ in
        if let m = node.marks.first(where: { $0.type === type }) { found = m.attrs["color"]?.stringValue }
        return true
    }
    return found
}

func registerMarksParityTests() {
    test("marks: color highlight and link apply to every selected table cell") {
        for name in ["textColor", "backgroundColor", "highlight", "link"] {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>")
            var cells: [Int] = []
            editor.doc.descendants { node, pos, _, _ in
                if node.type.name == "tableCell" { cells.append(pos) }
                return true
            }
            editor.dispatch(editor.state.tr.setSelection(CellSelection.create(editor.doc, anchorCellPos: cells[0], headCellPos: cells[2])))
            switch name {
            case "textColor": try expect(editor.setTextColor("red"))
            case "backgroundColor": try expect(editor.setBackgroundColor("red"))
            case "highlight": try expect(editor.setHighlight("red"))
            default: try expect(editor.run(setLink(editor.schema.marks[name]!, href: "https://example.com")))
            }
            var marked: [String] = []
            editor.doc.descendants { node, _, _, _ in
                if let text = node.text, node.marks.contains(where: { $0.type.name == name }) { marked.append(text) }
                return true
            }
            try expectEqual(marked, ["a", "c"], "\(name) should cover the selected column only")
        }
    }

    test("marks: clearing colors and links covers every selected table cell") {
        for name in ["textColor", "backgroundColor", "link"] {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>")
            let type = editor.schema.marks[name]!
            let mark = type.create(name == "link" ? ["href": .string("https://example.com")] : ["color": .string("red")])
            let tr = editor.state.tr
            try tr.addMark(0, editor.doc.content.size, mark)
            editor.dispatch(tr)
            var cells: [Int] = []
            editor.doc.descendants { node, pos, _, _ in
                if node.type.name == "tableCell" { cells.append(pos) }
                return true
            }
            editor.dispatch(editor.state.tr.setSelection(CellSelection.create(editor.doc, anchorCellPos: cells[0], headCellPos: cells[2])))
            try expect(editor.run(name == "link" ? unsetLink(type) : setColor(type, nil)))
            var marked: [String] = []
            editor.doc.descendants { node, _, _, _ in
                if let text = node.text, node.marks.contains(where: { $0.type === type }) { marked.append(text) }
                return true
            }
            try expectEqual(marked, ["b", "d"], "\(name) should remain only in the unselected column")
        }
    }

    test("marks: subscript/superscript/textColor/backgroundColor are registered") {
        let editor = try Editor(extensions: starterKit())
        for name in ["subscript", "superscript", "textColor", "backgroundColor"] {
            try expectNotNil(editor.schema.marks[name])
        }
    }

    test("subscript: toggleSubscript applies then removes the mark") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.run("toggleSubscript"))
        try expect(editor.isActive(mark: "subscript"))
        try expect(editor.run("toggleSubscript"))
        try expect(!editor.isActive(mark: "subscript"))
    }

    test("subscript/superscript are mutually exclusive") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.run("toggleSubscript"))
        try expect(editor.isActive(mark: "subscript"))
        // Applying superscript over the same range removes the subscript.
        try expect(editor.run("toggleSuperscript"))
        try expect(editor.isActive(mark: "superscript"))
        try expect(!editor.isActive(mark: "subscript"))
    }

    test("superscript: Mod-. toggles the mark") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(key(editor, "Mod-."))
        try expect(editor.isActive(mark: "superscript"))
    }

    test("textColor: setTextColor sets the color attr, nil removes it") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.setTextColor("#ff0000"))
        try expect(editor.isActive(mark: "textColor"))
        try expectEqual(colorAttr(editor, "textColor"), "#ff0000")
        try expect(editor.setTextColor(nil))
        try expect(!editor.isActive(mark: "textColor"))
    }

    test("textColor: a new color replaces the previous one") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.setTextColor("red"))
        try expect(editor.setTextColor("blue"))
        try expectEqual(colorAttr(editor, "textColor"), "blue")
    }

    test("backgroundColor: setBackgroundColor sets the color attr") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.setBackgroundColor("yellow"))
        try expect(editor.isActive(mark: "backgroundColor"))
        try expectEqual(colorAttr(editor, "backgroundColor"), "yellow")
    }
}
