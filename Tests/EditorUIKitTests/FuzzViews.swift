#if canImport(UIKit) && PROSEKIT_FUZZ
import XCTest
import UIKit
import CoreText
import DocumentModel
import SchemaKit
import TestDocGen
@testable import EditorUIKit

/// The corpus the UIKit fuzzers sweep, and the small facts about a laid-out
/// view they all need. Shared because more than one suite asks questions of the
/// same documents — geometry of one, text input of another — and neither should
/// own the corpus.
@MainActor
enum FuzzViews {
// MARK: - Corpus

/// The documents to sweep, with the width to lay each one out at:
/// generated documents (schema coverage) plus prose long enough to wrap —
/// most geometry bugs are wrapping bugs.
///
/// One editor for all of them, and the view built after its content is set.
/// A document only belongs to the schema instance that made it: hand a
/// second editor's node to `setContent` and the replace fails its content
/// check, which `setContent` swallows, leaving an empty paragraph that
/// passes every property here without testing one.
static func forEachView(_ body: (String, EditorTextView) throws -> Void) throws {
    try forEachView { name, v, _ in try body(name, v) }
}

/// The `ltr` flag says the view's text runs left to right throughout. Only
/// the two properties that talk about screen order care; everything else
/// holds whichever way the text runs.
static func forEachView(_ body: (String, EditorTextView, Bool) throws -> Void) throws {
    let editor = try Editor(extensions: fullKit())
    let schema = editor.schema
    var specs: [(name: String, doc: Node, width: CGFloat, ltr: Bool)] = []
    for (seed, doc) in generatedCorpus(schema, count: 8) {
        specs.append(("\(seed)@320", doc, 320, true))
    }
    for (i, doc) in wrappingDocs(schema).enumerated() {
        // 140pt is the interesting one: at a phone width a line holds a
        // phrase, at a third of it a line holds a word, and the degenerate
        // shapes (a line with one glyph on it, a word wider than the column)
        // only show up down there.
        for width in [CGFloat(140), 320, 390] {
            specs.append(("wrap\(i)@\(Int(width))", doc, width, true))
        }
    }
    for (i, doc) in bidiDocs(schema).enumerated() {
        for width in [CGFloat(140), 320] {
            specs.append(("bidi\(i)@\(Int(width))", doc, width, false))
        }
    }
    for spec in specs {
        editor.setContent(spec.doc)
        XCTAssertEqual(editor.doc, spec.doc, "the editor didn't take the document for \(spec.name)")
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: spec.width, height: 900)
        v.layoutIfNeeded()
        try body(spec.name, v, spec.ltr)
    }
}

/// Documents whose text is long enough to wrap several times, mixed with the
/// block kinds that sit next to prose and change the vertical rhythm.
static func wrappingDocs(_ s: Schema) -> [Node] {
    func n(_ t: String, _ c: [Node] = [], _ a: Attrs = [:]) -> Node {
        try! s.node(t, a, content: Fragment.from(c))
    }
    let long = Array(repeating: "lorem ipsum dolor sit amet consectetur adipiscing elit", count: 4)
        .joined(separator: " ")
    let short = "a short line"
    return [
        n("doc", [n("paragraph", [s.text(long)])]),
        n("doc", [
            n("heading", [s.text(long)], ["level": .int(1)]),
            n("paragraph", [s.text(long)]),
            n("paragraph", [s.text(short)]),
        ]),
        n("doc", [
            n("paragraph", [s.text(long)]),
            n("horizontalRule"),
            n("blockquote", [n("paragraph", [s.text(long)])]),
            n("codeBlock", [s.text("let x = 1\nlet y = 2\n")]),
        ]),
        n("doc", [
            n("bulletList", [
                n("listItem", [n("paragraph", [s.text(long)])]),
                n("listItem", [n("paragraph", [s.text(short)])]),
            ]),
            n("paragraph", [s.text(long)]),
        ]),
        n("doc", [
            n("paragraph", [s.text(short), n("hardBreak"), s.text(long)]),
            n("paragraph", []),
            n("paragraph", [s.text(long)]),
        ]),
    ]
}

/// Right-to-left and mixed-direction text. Nothing in the layout is
/// direction-aware, so this is the corpus most likely to be telling us
/// something: an Arabic run reverses screen order within the line, a Hebrew
/// run with Latin words in it reverses twice, and digits inside an RTL run
/// are their own left-to-right island.
static func bidiDocs(_ s: Schema) -> [Node] {
    func n(_ t: String, _ c: [Node] = [], _ a: Attrs = [:]) -> Node {
        try! s.node(t, a, content: Fragment.from(c))
    }
    let arabic = Array(repeating: "مرحبا بالعالم هذا نص طويل", count: 4).joined(separator: " ")
    let hebrew = Array(repeating: "שלום עולם זהו טקסט ארוך", count: 4).joined(separator: " ")
    let mixed = "the word مرحبا sits inside an English line"
    let mixedRTL = "שלום world שלום 12345 שלום"
    return [
        n("doc", [n("paragraph", [s.text(arabic)])]),
        n("doc", [n("paragraph", [s.text(hebrew)])]),
        n("doc", [n("paragraph", [s.text(mixed)]), n("paragraph", [s.text(mixedRTL)])]),
        n("doc", [
            n("heading", [s.text(arabic)], ["level": .int(2)]),
            n("bulletList", [n("listItem", [n("paragraph", [s.text(mixedRTL)])]),
                             n("listItem", [n("paragraph", [s.text(hebrew)])])]),
            n("paragraph", [s.text(mixed)]),
        ]),
        n("doc", [n("paragraph", [s.text("abc"), n("hardBreak"), s.text(arabic)])]),
    ]
}

/// Every document position a caret can occupy.
static func caretPositions(_ v: EditorTextView) -> [Int] {
    let doc = v.editor.doc
    return (0 ... doc.content.size).filter { doc.resolve($0).parent.inlineContent }
}

/// Whether every glyph run on the line reads left to right.
///
/// It matters because a bidi boundary is one screen position naming two
/// logical ones — the end of the Arabic run and the start of the Latin one
/// are drawn in the same place — and telling them apart needs a caret
/// affinity the editor deliberately doesn't carry. So on a line with an RTL
/// run in it, a tap can only be asked to stay on the same line.
static func lineIsLTR(_ line: LineLayout) -> Bool {
    guard let runs = CTLineGetGlyphRuns(line.ctLine) as? [CTRun] else { return true }
    return runs.allSatisfy { !CTRunGetStatus($0).contains(.rightToLeft) }
}

/// The laid-out line containing a caret rect, if any.
static func line(of rect: CGRect, in layout: DocumentLayout) -> LineLayout? {
    for block in layout.blocks {
        for line in block.lines where abs(line.baselineOrigin.y - line.ascent - rect.minY) < 0.5 {
            return line
        }
    }
    return nil
}

static func isFinite(_ r: CGRect) -> Bool {
    r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite
}

}
#endif
