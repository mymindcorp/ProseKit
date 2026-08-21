#if canImport(UIKit) && PROSEKIT_FUZZ
import XCTest
import UIKit
import CoreText
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
@testable import EditorUIKit

/// A fuzzer for the layer the selection fuzzer can't reach: where a position is
/// on screen, and which position a point on screen belongs to.
///
/// Everything here is a property of the *pair* `caretRect` / `position(at:)` and
/// their neighbours, checked over random documents at several widths rather than
/// over hand-picked shapes — the wrapping and block-gap cases that hand-written
/// tests keep missing are exactly the ones a generator stumbles into.
///
/// Compiled out by default, because it lays out hundreds of documents. A
/// compilation condition rather than an environment check for the reason
/// `RealizeBench` documents: xcodebuild's `TEST_RUNNER_` prefix does not reach
/// an SPM scheme's test runner.
///
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     xcodebuild test -scheme ProseKit-Package \
///       -only-testing:EditorUIKitTests/GeometryFuzzTests \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PROSEKIT_FUZZ' 
@MainActor
final class GeometryFuzzTests: XCTestCase {
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
    private func forEachView(_ body: (String, EditorTextView) throws -> Void) throws {
        let editor = try Editor(extensions: fullKit())
        let schema = editor.schema
        var specs: [(name: String, doc: Node, width: CGFloat)] = []
        for (seed, doc) in generatedCorpus(schema, count: 8) {
            specs.append(("\(seed)@320", doc, 320))
        }
        for (i, doc) in wrappingDocs(schema).enumerated() {
            // 140pt is the interesting one: at a phone width a line holds a
            // phrase, at a third of it a line holds a word, and the degenerate
            // shapes (a line with one glyph on it, a word wider than the column)
            // only show up down there.
            for width in [CGFloat(140), 320, 390] {
                specs.append(("wrap\(i)@\(Int(width))", doc, width))
            }
        }
        for spec in specs {
            editor.setContent(spec.doc)
            XCTAssertEqual(editor.doc, spec.doc, "the editor didn't take the document for \(spec.name)")
            let v = EditorTextView(editor: editor)
            v.frame = CGRect(x: 0, y: 0, width: spec.width, height: 900)
            v.layoutIfNeeded()
            try body(spec.name, v)
        }
    }

    /// Documents whose text is long enough to wrap several times, mixed with the
    /// block kinds that sit next to prose and change the vertical rhythm.
    private func wrappingDocs(_ s: Schema) -> [Node] {
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

    /// Every document position a caret can occupy.
    private func caretPositions(_ v: EditorTextView) -> [Int] {
        let doc = v.editor.doc
        return (0 ... doc.content.size).filter { doc.resolve($0).parent.inlineContent }
    }

    private func isFinite(_ r: CGRect) -> Bool {
        r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite
    }

    // MARK: - The caret and the tap agree

    func testTheCorpusIsWorthSweeping() throws {
        // A fuzzer that quietly lays out nothing passes every property it has.
        var views = 0, blocks = 0, lines = 0, positions = 0, wrapped = 0
        try forEachView { name, v in
            // Not every document has text in it — one that is nothing but an
            // image or a rule lays out no text blocks at all, which is correct.
            let layout = v.ensureLayout()
            views += 1
            blocks += layout.blocks.count
            for b in layout.blocks {
                lines += b.lines.count
                if b.lines.count > 1 { wrapped += 1 }
            }
            positions += caretPositions(v).count
        }
        XCTAssertGreaterThanOrEqual(views, 20, "the corpus is too small to mean anything")
        XCTAssertGreaterThan(blocks, 50, "only \(blocks) blocks laid out")
        XCTAssertGreaterThan(lines, blocks, "only \(lines) lines for \(blocks) blocks")
        XCTAssertGreaterThan(wrapped, 10, "only \(wrapped) blocks wrapped — the sweep isn't seeing soft wraps")
        XCTAssertGreaterThan(positions, 2000, "only \(positions) caret positions to sweep")
    }

    func testTappingTheDrawnCaretLeavesItWhereItIs() throws {
        // The property a user feels: put the caret somewhere, tap exactly on it,
        // and it must not move. Stated as rects rather than positions because a
        // soft wrap gives one screen place to two ways of naming it.
        var checked = 0
        try forEachView { name, v in
            let layout = v.ensureLayout()
            for pos in caretPositions(v) {
                guard let rect = layout.caretRect(at: pos) else { continue }
                checked += 1
                XCTAssertTrue(isFinite(rect), "caret rect isn't finite at \(pos) in \(name)")
                XCTAssertGreaterThan(rect.height, 0, "caret rect has no height at \(pos) in \(name)")
                let point = CGPoint(x: rect.minX + 0.5, y: rect.midY)
                guard let hit = layout.position(at: point) else {
                    XCTFail("tapping the caret at \(pos) hit nothing in \(name)")
                    continue
                }
                guard let hitRect = layout.caretRect(at: hit) else {
                    XCTFail("tapping the caret at \(pos) gave \(hit), which has no caret rect, in \(name)")
                    continue
                }
                XCTAssertEqual(hitRect.minX, rect.minX, accuracy: 0.5,
                               "tapping the caret at \(pos) moved it to \(hit) in \(name)")
                XCTAssertEqual(hitRect.midY, rect.midY, accuracy: 0.5,
                               "tapping the caret at \(pos) moved it to another line (\(hit)) in \(name)")
            }
        }
        XCTAssertGreaterThan(checked, 2000, "only \(checked) carets were tapped")
    }

    func testATapAnywhereLandsSomewhereACaretCanGo() throws {
        // Including the margins and the gaps between blocks: every point in the
        // view has to answer with a position that can actually hold a cursor.
        try forEachView { name, v in
            let layout = v.ensureLayout()
            let doc = v.editor.doc
            let size = doc.content.size
            var y: CGFloat = -20
            while y < v.bounds.height + 20 {
                var x: CGFloat = -20
                while x < v.bounds.width + 20 {
                    if let pos = layout.position(at: CGPoint(x: x, y: y)) {
                        XCTAssertTrue(pos >= 0 && pos <= size,
                                      "a tap at (\(x), \(y)) gave \(pos), outside 0...\(size), in \(name)")
                        XCTAssertTrue(doc.resolve(pos).parent.inlineContent,
                                      "a tap at (\(x), \(y)) gave \(pos), inside \(doc.resolve(pos).parent.type.name), in \(name)")
                    }
                    x += 13
                }
                y += 11
            }
        }
    }

    func testHitTestingRunsLeftToRightAlongALine() throws {
        // Sweeping a finger rightwards across a line can only ever move the
        // position forwards.
        try forEachView { name, v in
            let layout = v.ensureLayout()
            for (bi, block) in layout.blocks.enumerated() {
                for (li, line) in block.lines.enumerated() {
                    let y = line.baselineOrigin.y - line.ascent + line.height / 2
                    let width = CGFloat(CTLineGetTypographicBounds(line.ctLine, nil, nil, nil))
                    var last = Int.min
                    var x = line.baselineOrigin.x
                    while x <= line.baselineOrigin.x + width {
                        if let pos = layout.position(at: CGPoint(x: x, y: y)) {
                            XCTAssertGreaterThanOrEqual(pos, last,
                                                        "hit testing went backwards at x=\(x) on block \(bi) line \(li) in \(name)")
                            last = pos
                        }
                        x += 2
                    }
                }
            }
        }
    }

    func testCaretsAdvanceAcrossALine() throws {
        // Consecutive *document positions* on one line are drawn left to right.
        // Document positions, not attributed-string indices: one position can
        // span several UTF-16 units, and an index inside a grapheme cluster
        // isn't a place a caret goes.
        try forEachView { name, v in
            let layout = v.ensureLayout()
            for block in layout.blocks {
                var byLine: [CGFloat: [(pos: Int, x: CGFloat)]] = [:]
                for pos in block.contentStart ... block.contentEnd {
                    guard let rect = layout.caretRect(at: pos) else { continue }
                    byLine[rect.minY.rounded(), default: []].append((pos, rect.minX))
                }
                for (top, carets) in byLine {
                    for (a, b) in zip(carets, carets.dropFirst()) {
                        XCTAssertGreaterThanOrEqual(b.x, a.x - 0.5,
                                                    "caret for \(b.pos) is left of \(a.pos) on the line at y=\(top) in \(name)")
                    }
                }
            }
        }
    }

    // MARK: - Selection geometry

    func testSelectionRectsAreSaneAndClippingOnlyDropsWhatIsOutsideTheBand() throws {
        // The source promises clipping "changes the cost, never the drawing".
        try forEachView { name, v in
            let layout = v.ensureLayout()
            let positions = caretPositions(v)
            guard positions.count >= 2 else { return }
            var rng = SeededRNG(9)
            for _ in 0 ..< 40 {
                let a = positions.randomElement(using: &rng)!
                let b = positions.randomElement(using: &rng)!
                let (from, to) = (min(a, b), max(a, b))
                let rects = layout.selectionRects(from: from, to: to)
                for r in rects {
                    XCTAssertTrue(isFinite(r), "selection rect isn't finite for \(from)..\(to) in \(name)")
                    XCTAssertGreaterThan(r.height, 0, "a zero-height selection rect for \(from)..\(to) in \(name)")
                }
                guard !rects.isEmpty else { continue }
                let lo = rects.map(\.minY).min()!, hi = rects.map(\.maxY).max()!
                let band = (lo + (hi - lo) / 3) ... (hi - (hi - lo) / 3)
                let clipped = layout.selectionRects(from: from, to: to, clipY: band)
                let expected = rects.filter { $0.maxY >= band.lowerBound && $0.minY <= band.upperBound }
                XCTAssertEqual(clipped.count, expected.count,
                               "clipping \(from)..\(to) to \(band) changed which rects are drawn in \(name)")
            }
        }
    }

    // MARK: - The layout cache

    func testEditingThenRelayingOutMatchesLayingOutFromScratch() throws {
        // Each view keeps a `TextBlockLayoutCache`, which is what keeps typing
        // off the whole document. A warm layout that disagrees with a cold one
        // means the document is being drawn from a stale measurement — carets
        // and taps land where the text used to be.
        //
        // The cold view needs its own editor, and a document only belongs to the
        // schema that made it, so the edited doc goes across as JSON.
        let editor = try Editor(extensions: fullKit())
        let cold = try Editor(extensions: fullKit())
        let schema = editor.schema
        var rng = SeededRNG(77)
        var compared = 0
        for (seed, doc) in generatedCorpus(schema, count: 6) + wrappingDocs(schema).enumerated().map({ ("wrap\($0.offset)", $0.element) }) {
            for width in [CGFloat(140), 320] {
                editor.setContent(doc)
                let warmView = EditorTextView(editor: editor)
                warmView.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                warmView.layoutIfNeeded()
                _ = warmView.ensureLayout()

                // An edit in the middle of the document, then lay out again.
                let typable = (0 ... editor.doc.content.size).filter { editor.doc.resolve($0).parent.inlineContent }
                guard let at = typable.randomElement(using: &rng) else { continue }
                let tr = editor.state.tr
                guard (try? tr.insertText("typed", at)) != nil, tr.docChanged else { continue }
                editor.dispatch(tr)
                warmView.layoutIfNeeded()
                let warm = warmView.ensureLayout()

                let coldDoc = try cold.schema.nodeFromJSON(editor.doc.toJSON())
                cold.setContent(coldDoc)
                let coldView = EditorTextView(editor: cold)
                coldView.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                coldView.layoutIfNeeded()
                let fresh = coldView.ensureLayout()

                let ctx = "\(seed)@\(Int(width)) after typing at \(at)"
                XCTAssertEqual(warm.blocks.count, fresh.blocks.count, "block count differs — \(ctx)")
                for (a, b) in zip(warm.blocks, fresh.blocks) {
                    XCTAssertEqual(a.contentStart, b.contentStart, "block start differs — \(ctx)")
                    XCTAssertEqual(a.contentEnd, b.contentEnd, "block end differs — \(ctx)")
                    XCTAssertEqual(a.frame.minY, b.frame.minY, accuracy: 0.5, "block y differs — \(ctx)")
                    XCTAssertEqual(a.frame.height, b.frame.height, accuracy: 0.5, "block height differs — \(ctx)")
                    XCTAssertEqual(a.lines.count, b.lines.count, "line count differs in block \(a.contentStart) — \(ctx)")
                    for (la, lb) in zip(a.lines, b.lines) {
                        XCTAssertEqual(la.stringRange, lb.stringRange, "line range differs — \(ctx)")
                        XCTAssertEqual(la.baselineOrigin.y, lb.baselineOrigin.y, accuracy: 0.5, "line y differs — \(ctx)")
                    }
                    compared += 1
                }
            }
        }
        XCTAssertGreaterThan(compared, 100, "only \(compared) blocks compared")
    }

    // MARK: - Line edges and vertical movement

    func testLineEdgesBracketThePositionAndAreFixedPoints() throws {
        try forEachView { name, v in
            let layout = v.ensureLayout()
            for pos in caretPositions(v) {
                guard let start = layout.lineBoundary(from: pos, toEnd: false),
                      let end = layout.lineBoundary(from: pos, toEnd: true) else { continue }
                XCTAssertLessThanOrEqual(start, pos, "the line start is after \(pos) in \(name)")
                XCTAssertLessThanOrEqual(pos, end, "the line end is before \(pos) in \(name)")
                XCTAssertEqual(layout.lineBoundary(from: start, toEnd: false), start,
                               "going to the line start twice moved again, from \(pos), in \(name)")
                // The `toEnd` side is deliberately not a fixed point at a soft
                // wrap: the end of the wrapped line and the start of the line it
                // wrapped onto are one position, and the layout reads it as the
                // later of the two (the same rule that gives it one caret). So
                // asking again from there answers about the *next* line. What
                // must hold is that it doesn't go backwards.
                if let again = layout.lineBoundary(from: end, toEnd: true) {
                    XCTAssertGreaterThanOrEqual(again, end,
                                                "going to the line end twice went backwards, from \(pos), in \(name)")
                }
                // Both edges belong to the line the position is on.
                if let here = layout.caretRect(at: pos), let atStart = layout.caretRect(at: start) {
                    XCTAssertEqual(atStart.minY, here.minY, accuracy: 0.5,
                                   "the line start of \(pos) is on another line in \(name)")
                }
            }
        }
    }

    func testMovingDownThenUpReturnsToTheSameLine() throws {
        try forEachView { name, v in
            let layout = v.ensureLayout()
            for pos in caretPositions(v) {
                guard let here = layout.caretRect(at: pos) else { continue }
                let x = here.midX
                guard let down = layout.verticalPosition(from: pos, up: false, preferredX: x),
                      let downRect = layout.caretRect(at: down) else { continue }
                XCTAssertGreaterThan(downRect.minY, here.minY - 0.5,
                                     "moving down from \(pos) went up, to \(down), in \(name)")
                guard let back = layout.verticalPosition(from: down, up: true, preferredX: x),
                      let backRect = layout.caretRect(at: back) else { continue }
                XCTAssertEqual(backRect.minY, here.minY, accuracy: 0.5,
                               "down then up from \(pos) landed on another line (\(back)) in \(name)")
            }
        }
    }

    func testMovingDownAlwaysMakesProgressAndTerminates() throws {
        // The "stuck arrow" the layout guards against: a down move that returns
        // the line it started on loops forever under a held key.
        try forEachView { name, v in
            let layout = v.ensureLayout()
            guard let first = caretPositions(v).first, let start = layout.caretRect(at: first) else { return }
            var pos = first
            var y = start.minY
            var steps = 0
            let limit = layout.blocks.reduce(0) { $0 + $1.lines.count } + 4
            while let next = layout.verticalPosition(from: pos, up: false, preferredX: start.midX) {
                guard let rect = layout.caretRect(at: next) else { break }
                XCTAssertGreaterThan(rect.minY, y - 0.5, "a down move stalled at \(next) in \(name)")
                y = rect.minY
                pos = next
                steps += 1
                if steps > limit {
                    XCTFail("moving down never reached the end after \(steps) steps in \(name)")
                    break
                }
            }
        }
    }
}
#endif
