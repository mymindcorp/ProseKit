import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A shared driver for the fuzz suites that need an editor being *used* rather
// than a document being inspected: history, steps, collaboration.
//
// `SelectionFuzz` sweeps every position of a static document. These sweeps need
// the opposite — a live editor taking a long, varied sequence of edits — and
// three suites were otherwise going to grow their own copy of "do something
// random to this editor". One driver means an op added here immediately
// deepens all of them.

/// The commands the driver picks from. Ones that are no-ops outside their
/// context (the table family outside a table) are kept deliberately: a command
/// declining has to be as safe as a command running.
let fuzzOpCommands = [
    "toggleBold", "toggleItalic", "toggleCode", "toggleStrike", "toggleUnderline",
    "toggleBulletList", "toggleOrderedList", "toggleTaskList",
    "toggleHeading1", "toggleHeading2", "toggleBlockquote", "toggleCodeBlock",
    "setHorizontalRule", "setParagraph", "lift", "liftListItem", "sinkListItem",
    "joinBackward", "joinForward", "selectParentNode", "splitBlock",
    "addColumnBefore", "addColumnAfter", "deleteColumn", "addRowBefore", "addRowAfter",
    "deleteRow", "mergeCells", "splitCell", "toggleHeaderRow", "toggleHeaderColumn",
    "goToNextCell", "goToPreviousCell", "deleteTable",
]

let fuzzOpKeys = ["Enter", "Backspace", "Delete", "Tab", "Shift-Tab", "Mod-Enter",
                  "Mod-a", "ArrowLeft", "ArrowRight", "Shift-ArrowLeft", "Shift-ArrowRight"]

private let fuzzOpAlphabet = Array("ab cd\nef 🙂g.,#-*>`[]")

func fuzzOpText(_ rng: inout SelRNG) -> String {
    let n = Int.random(in: 0 ... 6, using: &rng)
    return String((0 ..< n).map { _ in fuzzOpAlphabet.randomElement(using: &rng)! })
}

/// Every position that currently holds a table cell — the input for the cell
/// selections the table machinery only sees through a `CellSelection`.
func fuzzCellPositions(_ doc: Node) -> [Int] {
    var out: [Int] = []
    doc.descendants { node, pos, _, _ in
        if fuzzCellTypeNames.contains(node.type.name) { out.append(pos) }
        return true
    }
    return out
}

/// Do one random thing to `editor`, and say what it was.
///
/// The description is the whole point of returning a value: a property that
/// fails 40 ops into a seed is unreadable without the list of what got it
/// there, and reconstructing that from the seed alone means re-deriving the
/// RNG by hand.
@discardableResult
func fuzzStep(_ editor: Editor, _ rng: inout SelRNG) -> String {
    let size = editor.doc.content.size
    func pos() -> Int { Int.random(in: 0 ... Swift.max(0, size), using: &rng) }

    switch Int.random(in: 0 ..< 12, using: &rng) {
    case 0:
        let at = Swift.min(pos(), size), text = fuzzOpText(&rng)
        let tr = editor.state.tr
        _ = try? tr.insertText(text, at)
        editor.dispatch(tr)
        return "insertText(\(text.debugDescription), \(at))"
    case 1:
        let a = pos(), b = pos()
        let tr = editor.state.tr
        _ = try? tr.delete(Swift.min(a, b), Swift.max(a, b))
        editor.dispatch(tr)
        return "delete(\(Swift.min(a, b)), \(Swift.max(a, b)))"
    case 2:
        // `between`, not `create`: `create` takes the positions it is handed
        // without asking whether text can go there, which is what the
        // never-trap sweep in `Fuzz.swift` wants and the opposite of what these
        // sweeps do — they assert that the selections in play are ones the
        // library would produce, so they have to start from one.
        let a = pos(), b = pos()
        editor.dispatch(editor.state.tr.setSelection(
            TextSelection.between(editor.doc.resolve(Swift.min(a, b)), editor.doc.resolve(Swift.max(a, b)))))
        return "select(\(Swift.min(a, b))..\(Swift.max(a, b)))"
    case 3:
        let at = pos()
        editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, at)))
        return "nodeSelect(\(at))"
    case 4:
        let cmd = fuzzOpCommands.randomElement(using: &rng)!
        return "run(\(cmd)) -> \(editor.run(cmd))"
    case 5:
        let k = fuzzOpKeys.randomElement(using: &rng)!
        return "key(\(k)) -> \(key(editor, k))"
    case 6:
        let at = Swift.min(pos(), size), depth = Int.random(in: 1 ... 3, using: &rng)
        let tr = editor.state.tr
        _ = try? tr.split(at, depth)
        editor.dispatch(tr)
        return "split(\(at), \(depth))"
    case 7:
        let rows = Int.random(in: 1 ... 3, using: &rng), cols = Int.random(in: 1 ... 3, using: &rng)
        _ = editor.insertTable(rows: rows, cols: cols, withHeaderRow: Bool.random(using: &rng))
        return "insertTable(\(rows)x\(cols))"
    case 8:
        let cells = fuzzCellPositions(editor.doc)
        guard cells.count >= 2 else { return "cellSelect(skipped)" }
        let a = cells.randomElement(using: &rng)!, b = cells.randomElement(using: &rng)!
        editor.dispatch(editor.state.tr.setSelection(CellSelection.create(editor.doc, a, b)))
        return "cellSelect(\(a), \(b))"
    case 9:
        editor.dispatch(editor.state.tr.setSelection(AllSelection(editor.doc)))
        return "selectAll"
    case 10:
        // A mark applied over an explicit range rather than at the cursor —
        // the cursor path is what `toggleBold` and friends usually take.
        let a = pos(), b = pos()
        guard let type = editor.schema.markSpecOrder.randomElement(using: &rng)
            .flatMap({ editor.schema.marks[$0] }) else { return "mark(skipped)" }
        var attrs: Attrs = [:]
        if type.attrs["href"] != nil { attrs["href"] = .string("https://example.com/") }
        if type.attrs["color"] != nil { attrs["color"] = .string("#00ff00") }
        let tr = editor.state.tr
        let from = Swift.min(a, b), to = Swift.max(a, b)
        if Bool.random(using: &rng) {
            _ = try? tr.addMark(from, to, editor.schema.mark(type, attrs))
        } else {
            _ = try? tr.removeMark(from, to, editor.schema.mark(type, attrs))
        }
        editor.dispatch(tr)
        return "mark(\(type.name), \(from)..\(to))"
    default:
        let at = Swift.min(pos(), size)
        guard let para = editor.schema.nodes["paragraph"]?
            .createAndFill([:], content: Fragment.from(editor.schema.text(fuzzOpText(&rng) + "z")))
        else { return "insertNode(skipped)" }
        let tr = editor.state.tr
        _ = try? tr.replaceWith(at, at, para)
        editor.dispatch(tr)
        return "insertParagraph(\(at))"
    }
}

/// An editor plus the transactions it dispatched, so a property can look at the
/// steps a command produced rather than only at the document it left behind.
///
/// Only the *root* transaction of each dispatch is recorded: `Editor.dispatch`
/// reports that one, and the transactions plugins append (table fixing, unique
/// IDs) stay inside `EditorState.applyTransaction`. Their steps are ordinary
/// replaces and attribute changes that the recorded ones cover too, so the loss
/// is coverage of who built the step, not of what kinds of step get checked.
final class FuzzRecorder {
    let editor: Editor
    private(set) var transactions: [Transaction] = []

    init(_ extensions: [any Extension] = fullKit(), content: Node? = nil) throws {
        editor = try Editor(extensions: extensions, content: content)
        editor.onTransaction = { [weak self] tr in self?.transactions.append(tr) }
    }

    /// Run one random operation and return the transactions it dispatched,
    /// paired with the description of what was asked for.
    func step(_ rng: inout SelRNG) -> (what: String, transactions: [Transaction]) {
        let mark = transactions.count
        let what = fuzzStep(editor, &rng)
        return (what, Array(transactions[mark...]))
    }
}

/// Every `(step, the document it runs on)` pair in a transaction.
func fuzzSteps(_ trs: [Transaction]) -> [(step: any Step, doc: Node)] {
    trs.flatMap { tr in tr.steps.enumerated().map { (step: $0.element, doc: tr.docs[$0.offset]) } }
}
