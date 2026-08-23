import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

/// What a `[[wiki-link]]` carries: the `text` it reads as, and — when a host
/// picked the target from its own store — the `targetId` that still resolves
/// after a rename and the `targetType` a renderer draws an icon from.
/// Attributes the spec doesn't declare are dropped on parse, so these pin the
/// whole set down: created, round-tripped through JSON, and written by accepting
/// a suggestion.
func registerWikiLinkTargetIdTests() {
    test("wiki link: the whole attribute set survives a JSON round trip") {
        try MainActor.assumeIsolated {
            let editor = try Editor(extensions: fullKit())
            try expect(editor.insertWikiLink(text: "Architecture", targetId: "3xK9", targetType: "Note"),
                       "insert should succeed")
            let reparsed = try Node.fromJSON(editor.schema, editor.doc.toJSON())
            let node = try firstWikiLink(reparsed)
            try expectEqual(node.attrs["text"]?.stringValue, "Architecture")
            try expectEqual(node.attrs["targetId"]?.stringValue, "3xK9")
            try expectEqual(node.attrs["targetType"]?.stringValue, "Note")
        }
    }

    test("wiki link: typing `[[Page]]` puts the words in `text`") {
        try MainActor.assumeIsolated {
            let editor = try Editor(extensions: fullKit())
            // The closing bracket has to go through the input rules — typing it
            // straight into the document is what the rule watches for.
            try type(editor, "[[Architecture]")
            _ = textInput(editor, at: editor.doc.content.size - 1, "]")
            let node = try firstWikiLink(editor.doc)
            try expectEqual(node.attrs["text"]?.stringValue, "Architecture")
        }
    }

    test("wiki targetId: absent when nobody supplied one") {
        try MainActor.assumeIsolated {
            let editor = try Editor(extensions: fullKit())
            try expect(editor.insertWikiLink(text: "Architecture"), "insert should succeed")
            let node = try firstWikiLink(editor.doc)
            try expect(node.attrs["targetId"]?.stringValue == nil, "no id was given, so none is carried")
        }
    }

    test("wiki targetId: accepting a suggestion writes it over the typed query") {
        try MainActor.assumeIsolated {
            let editor = try Editor(extensions: fullKit(wikiLinkSuggestions: { _ in ["Architecture"] }))
            try type(editor, "[[Arc")
            try expect(editor.acceptWikiLinkSuggestion(text: "Architecture", targetId: "3xK9"),
                       "accept should succeed")
            let node = try firstWikiLink(editor.doc)
            try expectEqual(node.attrs["targetId"]?.stringValue, "3xK9")
            try expect(!editor.doc.textBetween(0, editor.doc.content.size).contains("[["),
                       "the typed query is replaced, not left behind")
        }
    }
}

/// The first `wikiLink` atom in a document. Fails the test when there is none,
/// so a lost link reports where it was looked for rather than where a nil
/// attribute was asserted.
private func firstWikiLink(_ doc: Node, file: StaticString = #file, line: UInt = #line) throws -> Node {
    var found: Node?
    doc.descendants { node, _, _, _ in
        if found == nil, node.type.name == "wikiLink" { found = node }
        return found == nil
    }
    try expectNotNil(found, file: file, line: line)
    return found!
}
