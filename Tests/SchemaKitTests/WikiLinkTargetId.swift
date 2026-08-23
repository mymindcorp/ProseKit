import Foundation
import DocumentModel
import EditorStateKit
import SchemaKit
import TestHarness

/// The `targetId` attribute: a host's own id for the page a `[[wiki-link]]`
/// names. Attributes the spec doesn't declare are dropped on parse, so these
/// pin that one down — created, round-tripped through JSON, and written by
/// accepting a suggestion.
func registerWikiLinkTargetIdTests() {
    test("wiki targetId: survives a JSON round trip") {
        try MainActor.assumeIsolated {
            let editor = try Editor(extensions: fullKit())
            try expect(editor.insertWikiLink(target: "Architecture", targetId: "3xK9", label: "the plan"),
                       "insert should succeed")
            let reparsed = try Node.fromJSON(editor.schema, editor.doc.toJSON())
            let node = try firstWikiLink(reparsed)
            try expectEqual(node.attrs["targetId"]?.stringValue, "3xK9")
            try expectEqual(node.attrs["target"]?.stringValue, "Architecture")
            try expectEqual(node.attrs["label"]?.stringValue, "the plan")
        }
    }

    test("wiki targetId: absent when nobody supplied one") {
        try MainActor.assumeIsolated {
            let editor = try Editor(extensions: fullKit())
            try expect(editor.insertWikiLink(target: "Architecture"), "insert should succeed")
            let node = try firstWikiLink(editor.doc)
            try expect(node.attrs["targetId"]?.stringValue == nil, "no id was given, so none is carried")
        }
    }

    test("wiki targetId: accepting a suggestion writes it over the typed query") {
        try MainActor.assumeIsolated {
            let editor = try Editor(extensions: fullKit(wikiLinkSuggestions: { _ in ["Architecture"] }))
            try type(editor, "[[Arc")
            try expect(editor.acceptWikiLinkSuggestion(target: "Architecture", targetId: "3xK9"),
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
