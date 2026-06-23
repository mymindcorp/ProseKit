import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// Registered into the shared `collector` from main.swift.

/// A starter kit plus UniqueID applied to the given node types.
private func uniqueIDKit(types: [String] = ["paragraph", "heading"],
                         generateID: (@Sendable () -> String)? = nil) -> [any Extension] {
    var exts = starterKit()
    if let generateID {
        exts.append(UniqueIDExtension(types: types, generateID: generateID))
    } else {
        exts.append(UniqueIDExtension(types: types))
    }
    return exts
}

/// Collect the ids of every node of the given type, in document order.
private func ids(_ editor: Editor, ofType type: String) -> [String?] {
    var out: [String?] = []
    editor.doc.descendants { node, _, _, _ in
        if node.type.name == type {
            if case let .string(s)? = node.attrs["id"] { out.append(s) } else { out.append(nil) }
        }
        return true
    }
    return out
}

func registerUniqueIDTests() {
    test("uniqueID: adds an `id` attribute to the configured node schemas") {
        let editor = try Editor(extensions: uniqueIDKit())
        try expectNotNil(editor.schema.nodes["paragraph"]?.defaultAttrs["id"])
        try expectNotNil(editor.schema.nodes["heading"]?.defaultAttrs["id"])
        // A type that wasn't listed keeps its original attribute set.
        try expectNil(editor.schema.nodes["codeBlock"]?.defaultAttrs["id"])
    }

    test("uniqueID: assigns ids to initial content on creation") {
        // Build a doc of two paragraphs and load it (no edits yet).
        let schema = try ExtensionManager(uniqueIDKit()).schema
        let doc = try schema.node("doc", [:], content: Fragment.from([
            try schema.node("paragraph", [:], content: Fragment.from([schema.text("alpha")])),
            try schema.node("paragraph", [:], content: Fragment.from([schema.text("bravo")])),
        ]))
        let editor = try Editor(extensions: uniqueIDKit(), content: doc)
        let assigned = ids(editor, ofType: "paragraph")
        try expectEqual(assigned.count, 2)
        try expect(assigned.allSatisfy { $0 != nil }, "every paragraph got an id")
        try expect(assigned[0] != assigned[1], "ids are distinct")
    }

    test("uniqueID: assigns an id as you type a new paragraph") {
        let editor = try Editor(extensions: uniqueIDKit())
        try type(editor, "hello")
        let assigned = ids(editor, ofType: "paragraph")
        try expect(assigned.first.flatMap { $0 } != nil, "the edited paragraph has an id")
    }

    test("uniqueID: splitting a paragraph gives the new half a fresh id") {
        let editor = try Editor(extensions: uniqueIDKit())
        try type(editor, "abcdef")
        let before = ids(editor, ofType: "paragraph")
        try expectEqual(before.count, 1)
        let originalID = before[0]
        try expectNotNil(originalID)

        // Split in the middle of the text.
        var textStart = 0
        editor.doc.descendants { node, pos, _, _ in
            if node.isText { textStart = pos }
            return true
        }
        select(editor, textStart + 3, textStart + 3)
        _ = key(editor, "Enter")

        let after = ids(editor, ofType: "paragraph")
        try expectEqual(after.count, 2, "split produced two paragraphs")
        try expect(after.allSatisfy { $0 != nil }, "both halves have ids")
        try expect(after[0] != after[1], "the two halves have distinct ids")
        // The upper half keeps the original id; the lower half is the new one.
        try expectEqual(after[0], originalID)
    }

    test("uniqueID: deterministic generator still yields unique ids on split") {
        // A counter generator proves duplicates are detected and re-issued
        // rather than blindly copied when a node is split.
        let counter = Counter()
        let editor = try Editor(extensions: uniqueIDKit(generateID: { counter.next() }))
        try type(editor, "abcdef")
        var textStart = 0
        editor.doc.descendants { node, pos, _, _ in
            if node.isText { textStart = pos }
            return true
        }
        select(editor, textStart + 3, textStart + 3)
        _ = key(editor, "Enter")
        let after = ids(editor, ofType: "paragraph")
        try expectEqual(after.count, 2)
        try expect(after[0] != after[1], "distinct ids even with a sequential generator")
    }

    test("uniqueID: ids round-trip through HTML serialization") {
        let editor = try Editor(extensions: uniqueIDKit())
        try type(editor, "hello")
        let original = ids(editor, ofType: "paragraph").first.flatMap { $0 }
        try expectNotNil(original)

        let html = editor.getHTML()
        try expect(html.contains("data-id=\"\(original!)\""), "serialized HTML carries the id: \(html)")

        // Parse it back into a fresh UniqueID editor; the id must survive rather
        // than being dropped (and re-generated) on the way in.
        let reopened = try Editor(extensions: uniqueIDKit())
        try reopened.setContent(html: html)
        let restored = ids(reopened, ofType: "paragraph").first.flatMap { $0 }
        try expectEqual(restored, original, "the id parsed back matches the original")
    }

    test("uniqueID: `all` applies to every node except doc and text") {
        var exts = starterKit()
        exts.append(UniqueIDExtension(types: ["all"]))
        let editor = try Editor(extensions: exts)
        try expectNotNil(editor.schema.nodes["paragraph"]?.defaultAttrs["id"])
        try expectNotNil(editor.schema.nodes["heading"]?.defaultAttrs["id"])
        try expectNil(editor.schema.nodes["doc"]?.defaultAttrs["id"])
        try expectNil(editor.schema.nodes["text"]?.defaultAttrs["id"])
    }
}

/// A tiny deterministic id source for tests.
private final class Counter: @unchecked Sendable {
    private var n = 0
    func next() -> String { n += 1; return "id-\(n)" }
}
