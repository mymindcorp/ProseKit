import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// Regressions for the RTF importer bugs `RTFImportProperties` found: each is a
// place a paste lost or rejected content it should have kept.

private let fixHeader = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}{\f1\fmodern Courier New;}}"#
private func fixRTF(_ body: String) -> String { fixHeader + body + "}" }

/// The test schema with some nodes' content expressions replaced.
private func narrowed(_ content: [String: String]) throws -> Schema {
    var nodes: [(String, NodeSpec)] = []
    for name in schema.nodeSpecOrder {
        guard let type = schema.nodes[name] else { continue }
        var spec = type.spec
        if let c = content[name] { spec.content = c }
        nodes.append((name, spec))
    }
    let marks = schema.markSpecOrder.compactMap { name in schema.marks[name].map { (name, $0.spec) } }
    return try Schema(nodes: nodes, marks: marks, topNode: "doc")
}

/// Every textblock's text, one per line.
private func textblocks(_ d: Node) -> [String] {
    var out: [String] = []
    d.descendants { node, _, _, _ in
        guard node.isTextblock else { return true }
        out.append(node.textContent)
        return false
    }
    return out
}

func registerRTFImportFixTests() {
    test("RTF: a footnote ends where its own group does, not at the first group nested in it") {
        let d = try RTFParser.parse(fixRTF(
            #"\pard body{\footnote\pard {\i Smith} 2020, p. 4.\par} continues.\par"#), schema: schema)
        try d.check()
        try expectEqual(d.childCount, 2)
        try expectEqual(d.child(0), p(t("body"), node("footnoteReference", ["label": .string("1")]), t(" continues.")))
        let definition = d.child(1)
        try expectEqual(definition.type.name, "footnoteDefinition")
        try expectEqual(textblocks(definition), ["Smith 2020, p. 4."])
    }

    test("RTF: Word's footnote, every run in a group of its own, keeps all of its text") {
        let d = try RTFParser.parse(fixRTF(
            #"\pard x{\cs17\super \chftn}{\footnote \pard {\cs17\super \chftn}{ Note text.}{ More.}\par}{ after}\par"#),
            schema: schema)
        try d.check()
        try expectEqual(textblocks(d), ["x[^1] after", " Note text. More."])
    }

    test("RTF: a paragraph the schema can't give a break keeps its text") {
        let narrow = try narrowed(["paragraph": "text*"])
        let d = try RTFParser.parse(fixRTF(#"\pard a\line b\par\pard c\par"#), schema: narrow)
        try d.check()
        try expectEqual(textblocks(d), ["a b", "c"])
        // A footnote reference it can't hold goes; the words around it stay.
        let f = try RTFParser.parse(fixRTF(#"\pard body{\footnote\pard note\par} more\par"#), schema: narrow)
        try f.check()
        try expectEqual(textblocks(f), ["body more", "note"])
    }

    test("RTF: a nested list whose items can't hold a sublist follows its parent item") {
        let narrow = try narrowed(["listItem": "paragraph"])
        let d = try RTFParser.parse(fixRTF(
            #"\pard\ls1\ilvl0 {\listtext \'95\tab}a\par\pard\ls1\ilvl1 {\listtext \'95\tab}b\par"# +
            #"\pard\ls1\ilvl0 {\listtext \'95\tab}c\par"#), schema: narrow)
        try d.check()
        try expectEqual(textblocks(d), ["a", "b", "c"])
        try expectEqual(d.childCount, 1)
        try expectEqual(d.child(0).type.name, "bulletList")
        try expectEqual(d.child(0).childCount, 3)
    }

    test("RTF: a table nested in a paragraph-only cell spills every one of its cells") {
        let narrow = try narrowed(["tableCell": "paragraph", "tableHeader": "paragraph"])
        let d = try RTFParser.parse(fixRTF(
            #"\trowd\cellx4000\pard\intbl\itap2 in1\nestcell in2\nestcell{\*\nesttableprops\trowd\cellx1000\cellx2000\nestrow}"# +
            #"\pard\intbl\itap1 tail\cell\row"#), schema: narrow)
        try d.check()
        try expectEqual(textblocks(d), ["in1", "in2", "tail"])
    }

    test("RTF: a merge continuation cell adds no empty paragraph to the merged cell") {
        let d = try RTFParser.parse(fixRTF(#"\trowd\clmgf\cellx2000\clmrg\cellx4000\pard\intbl a\cell\cell\row"#),
                                    schema: schema)
        try d.check()
        let cell = d.child(0).child(0).child(0)
        try expectEqual(cell.attrs["colspan"], .int(2))
        try expectEqual(cell.childCount, 1)
        try expectEqual(cell.child(0), p("a"))
        // Vertically, too.
        let v = try RTFParser.parse(fixRTF(
            #"\trowd\clvmgf\cellx2000\cellx4000\pard\intbl a\cell b\cell\row"# +
            #"\trowd\clvmrg\cellx2000\cellx4000\pard\intbl \cell c\cell\row"#), schema: schema)
        try v.check()
        let anchor = v.child(0).child(0).child(0)
        try expectEqual(anchor.attrs["rowspan"], .int(2))
        try expectEqual(anchor.childCount, 1)
    }

    test("RTF: a table three deep nests three deep when the innermost comes first") {
        let d = try RTFParser.parse(fixRTF(
            #"\trowd\cellx6000"# +
            #"\pard\intbl\itap3 deepest\nestcell{\*\nesttableprops\trowd\cellx2000\nestrow}"# +
            #"\pard\intbl\itap2 \nestcell{\*\nesttableprops\trowd\cellx4000\nestrow}"# +
            #"\pard\intbl\itap1 outer\cell\row\pard end\par"#), schema: schema)
        try d.check()
        let outerCell = d.child(0).child(0).child(0)
        let middle = outerCell.child(0)
        try expectEqual(middle.type.name, "table")
        let middleCell = middle.child(0).child(0)
        try expectEqual(middleCell.child(0).type.name, "table", "the innermost table sits in the middle one's cell")
        try expectEqual(middleCell.child(0).textContent, "deepest")
        try expectEqual(outerCell.child(1), p("outer"))
        try expectEqual(d.child(1), p("end"))
    }

    test("RTF: an absurd \\itap still opens a bounded number of tables") {
        let d = try RTFParser.parse(fixRTF(#"\trowd\cellx6000\pard\intbl\itap1000 x\cell\row"#), schema: schema)
        try d.check()
        try expectEqual(d.textContent, "x")
    }

    test("RTF: whitespace between the opening brace and \\rtf isn't text") {
        try expectEqual(try RTFParser.parse(#"{ \rtf1 x}"#, schema: schema), doc(p("x")))
        try expectEqual(try RTFParser.parse("{\n\\rtf1 x}", schema: schema), doc(p("x")))
    }
}
