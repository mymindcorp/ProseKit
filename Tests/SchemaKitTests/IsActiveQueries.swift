import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

// The Tiptap-shaped selection-state queries a toolbar uses:
// `editor.isActive(name)`, `isActive(name, attrs:)`, and `getAttributes(name)`,
// which resolve a name to either a node or a mark.

func registerIsActiveQueryTests() {
    test("isActive(_:): unified name resolves marks — bold/italic") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(!editor.isActive("bold"))
        try expect(editor.run("toggleBold"))
        try expect(editor.isActive("bold"))
        try expect(!editor.isActive("italic"))
        try expect(editor.run("toggleItalic"))
        try expect(editor.isActive("italic"))
    }

    test("isActive(_:): unified name resolves nodes — heading, any level vs specific") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(!editor.isActive("heading"))
        try expect(editor.run("toggleHeading1"))
        // No attrs → any heading.
        try expect(editor.isActive("heading"))
        // Attrs filter → the level must match.
        try expect(editor.isActive("heading", attrs: ["level": .int(1)]))
        try expect(!editor.isActive("heading", attrs: ["level": .int(2)]))
    }

    test("isActive(_:) + getAttributes(_:): link mark and its href") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        guard let linkType = editor.schema.marks["link"] else { try expect(false, "no link mark"); return }
        try expect(editor.run(setLink(linkType, href: "https://example.com")))
        try expect(editor.isActive("link"))
        try expectEqual(editor.getAttributes("link")["href"], .string("https://example.com"))
    }

    test("isActive(mark:attrs:): attribute filter narrows the match — highlight color") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.setHighlight("#ff0000"))
        try expect(editor.isActive("highlight"))                                    // any color
        try expect(editor.isActive("highlight", attrs: ["color": .string("#ff0000")]))  // matching
        try expect(!editor.isActive("highlight", attrs: ["color": .string("#00ff00")])) // mismatched
    }

    test("getAttributes(_:): empty when nothing of that name is active") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        select(editor, 1, editor.doc.content.size - 1)
        try expect(editor.getAttributes("link").isEmpty)  // no link applied
        try expect(editor.getAttributes("bold").isEmpty)   // marks carry no attrs
    }

    test("isActive(_:)/getAttributes(_:): unknown name is false/empty, never crashes") {
        let editor = try Editor(extensions: starterKit())
        try type(editor, "hello")
        try expect(!editor.isActive("notARealType"))
        try expect(editor.getAttributes("notARealType").isEmpty)
    }

    test("isActive: covers EVERY mark in the schema (inactive → active)") {
        // How to turn each mark on over the current selection. Keyed by mark name
        // so the exhaustiveness check below can prove no schema mark is missed.
        let appliers: [String: (Editor) -> Bool] = [
            "bold": { $0.run("toggleBold") },
            "italic": { $0.run("toggleItalic") },
            "strike": { $0.run("toggleStrike") },
            "underline": { $0.run("toggleUnderline") },
            "highlight": { $0.run("toggleHighlight") },
            "code": { $0.run("toggleCode") },
            "subscript": { $0.run("toggleSubscript") },
            "superscript": { $0.run("toggleSuperscript") },
            "textColor": { $0.setTextColor("#ff0000") },
            "backgroundColor": { $0.setBackgroundColor("#00ff00") },
            "link": { editor in
                guard let type = editor.schema.marks["link"] else { return false }
                return editor.run(setLink(type, href: "https://example.com"))
            },
        ]

        // Exhaustiveness: every mark the schema registers must have an applier, so
        // adding a new mark without isActive coverage fails this test.
        let editor = try Editor(extensions: starterKit())
        for name in editor.schema.marks.keys {
            try expect(appliers[name] != nil, "no isActive coverage for mark '\(name)'")
        }

        // Each mark, on a fresh editor: inactive before, active after — via both
        // the unified `isActive(_:)` and the typed `isActive(mark:)`.
        for (name, apply) in appliers {
            let ed = try Editor(extensions: starterKit())
            try type(ed, "hello")
            select(ed, 1, ed.doc.content.size - 1)
            try expect(!ed.isActive(name), "'\(name)' should be inactive initially")
            try expect(!ed.isActive(mark: name), "'\(name)' should be inactive initially (typed)")
            try expect(apply(ed), "applying '\(name)' should succeed")
            try expect(ed.isActive(name), "'\(name)' should be active via isActive(_:)")
            try expect(ed.isActive(mark: name), "'\(name)' should be active via isActive(mark:)")
        }
    }
}
