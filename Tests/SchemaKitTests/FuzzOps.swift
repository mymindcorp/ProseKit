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

/// The extensions every live-editor sweep drives.
///
/// The same set `fuzzSchema` builds, not bare `fullKit()`. The two had drifted:
/// the document corpus covered figures, footnotes and math because
/// `fuzzSchema` adds them, while every sweep that *edited* a document ran on a
/// schema that had none of those node types — so the commands that build them
/// were never run, and the structures whose shapes are least like a paragraph
/// were only ever generated, never edited.
func fuzzKit() -> [any Extension] { fullKit() + figureExtensions() + footnoteExtensions() }

/// The commands the driver picks from. Ones that are no-ops outside their
/// context (the table family outside a table) are kept deliberately: a command
/// declining has to be as safe as a command running.
let fuzzOpCommands = [
    "toggleBold", "toggleItalic", "toggleCode", "toggleStrike", "toggleUnderline",
    "toggleHighlight", "toggleSubscript", "toggleSuperscript",
    "toggleBulletList", "toggleOrderedList", "toggleTaskList", "toggleTaskChecked",
    "toggleHeading1", "toggleHeading2", "toggleBlockquote", "toggleCodeBlock",
    "setHorizontalRule", "setParagraph", "setHardBreak", "lift", "liftListItem", "sinkListItem",
    "joinBackward", "joinForward", "selectParentNode", "splitBlock",
    "addColumnBefore", "addColumnAfter", "deleteColumn", "addRowBefore", "addRowAfter",
    "deleteRow", "mergeCells", "splitCell", "mergeOrSplit", "toggleHeaderRow",
    "toggleHeaderColumn", "toggleHeaderCell", "goToNextCell", "goToPreviousCell", "deleteTable",
    // The nested containers, whose shapes are the least paragraph-like in the
    // kit and the ones the fitter has the most trouble placing content into.
    "setDetails", "toggleDetails", "toggleDetailsOpen",
    "setFigure", "toggleFigure",
    "insertFootnote", "removeFootnote",
    "insertInlineMath", "insertBlockMath", "deleteInlineMath", "deleteBlockMath",
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

    switch Int.random(in: 0 ..< 18, using: &rng) {
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
        //
        // A removal draws from the marks the document is *wearing* rather than
        // from the schema. `removeMark` writes no step when the range holds
        // nothing to remove, so a mark picked at random almost never produced a
        // `RemoveMarkStep` — the sweeps above were running on five of the seven
        // step kinds a sweep can produce, and the coverage property is what
        // said so.
        let a = pos(), b = pos()
        let from = Swift.min(a, b), to = Swift.max(a, b)
        let adding = Bool.random(using: &rng)
        let worn = adding ? [] : fuzzMarksInRange(editor.doc, from, to)
        guard let mark = worn.randomElement(using: &rng) ?? fuzzRandomMark(editor.schema, &rng)
        else { return "mark(skipped)" }
        let tr = editor.state.tr
        if adding {
            _ = try? tr.addMark(from, to, mark)
        } else {
            _ = try? tr.removeMark(from, to, mark)
        }
        editor.dispatch(tr)
        return "\(adding ? "addMark" : "removeMark")(\(mark.type.name), \(from)..\(to))"
    case 11:
        let at = Swift.min(pos(), size)
        guard let para = editor.schema.nodes["paragraph"]?
            .createAndFill([:], content: Fragment.from(editor.schema.text(fuzzOpText(&rng) + "z")))
        else { return "insertNode(skipped)" }
        let tr = editor.state.tr
        _ = try? tr.replaceWith(at, at, para)
        editor.dispatch(tr)
        return "insertParagraph(\(at))"
    case 12:
        // `replaceRange`, not `replace`: the range-expanding fitter is what
        // paste and drop go through, and it is the one that decides to swallow
        // a parent or open the slice a level further. A plain `ReplaceStep`
        // never exercises any of that.
        let a = pos(), b = pos(), from = Swift.min(a, b), to = Swift.max(a, b)
        let slice = fuzzSlice(editor.schema, &rng, cutFrom: editor.doc)
        let tr = editor.state.tr
        _ = try? tr.replaceRange(from, to, slice)
        editor.dispatch(tr)
        return "replaceRange(\(from), \(to), openStart: \(slice.openStart), openEnd: \(slice.openEnd))"
    case 13:
        // The other half of the same pair: `deleteRange` widens a deletion
        // outward when the inner content was all its parent held, so deleting
        // the only paragraph of a list item takes the item with it. Backspace
        // over a selection lands here, and nothing else in the driver did.
        let a = pos(), b = pos(), from = Swift.min(a, b), to = Swift.max(a, b)
        let tr = editor.state.tr
        _ = try? tr.deleteRange(from, to)
        editor.dispatch(tr)
        return "deleteRange(\(from), \(to))"
    case 14:
        // An `AttrStep` on whatever node happens to be there. The commands
        // reach a few attributes (a heading's level, a task's checked flag);
        // this reaches the rest, including the ones no command writes.
        // Sorted before the draw: Swift randomizes a `Dictionary`'s iteration
        // order per process, so drawing straight from `type.attrs` would make
        // the same seed pick a different attribute on every run and a failure
        // would stop reproducing from the seed printed with it.
        guard let at = fuzzNodePositions(editor.doc).randomElement(using: &rng),
              let node = editor.doc.nodeAt(at),
              let name = node.type.attrs.keys.sorted().randomElement(using: &rng)
        else { return "setAttr(skipped)" }
        let value = fuzzAttrValue(name, &rng)
        let tr = editor.state.tr
        _ = try? tr.setNodeAttribute(at, name, value)
        editor.dispatch(tr)
        return "setNodeAttribute(\(at), \(node.type.name).\(name))"
    case 15:
        // `AddNodeMarkStep` / `RemoveNodeMarkStep` — a mark on a *node* rather
        // than on a range of text. No command in the kit produces one, so
        // before this the two step types were decoded by the collab layer and
        // never once built by a sweep.
        // The mark has to be one the node's *parent* accepts, or the step fails
        // and never reaches the transaction — which is how `addNodeMark` went
        // missing from the sweeps until the coverage property named it. A nil
        // `markSet` means the parent takes anything.
        guard let at = fuzzNodePositions(editor.doc).randomElement(using: &rng)
        else { return "nodeMark(skipped)" }
        let allowed = editor.doc.resolve(at).parent.type.markSet
        guard let type = allowed?.randomElement(using: &rng)
            ?? fuzzRandomMark(editor.schema, &rng)?.type else { return "nodeMark(skipped)" }
        var attrs: Attrs = [:]
        if type.attrs["href"] != nil { attrs["href"] = .string("https://example.com/") }
        if type.attrs["color"] != nil { attrs["color"] = .string("#00ff00") }
        let mark = editor.schema.mark(type, attrs)
        // Biased towards adding: a remove only writes a step when the mark is
        // there, and nothing but this arm ever puts one on a node.
        let adding = Int.random(in: 0 ..< 3, using: &rng) != 0
        let tr = editor.state.tr
        if adding { _ = try? tr.addNodeMark(at, mark) } else { _ = try? tr.removeNodeMark(at, mark) }
        editor.dispatch(tr)
        return "\(adding ? "addNodeMark" : "removeNodeMark")(\(at), \(type.name))"
    case 16:
        // `setNodeMarkup` retypes a node in place — the step behind "turn this
        // blockquote into a details". It emits a `ReplaceAroundStep` whose
        // slice carries the *new* node's markup around the old node's content,
        // which is the shape the fitter and the mappers find hardest.
        guard let at = fuzzNodePositions(editor.doc).randomElement(using: &rng),
              let node = editor.doc.nodeAt(at), !node.isText,
              let name = editor.schema.nodeSpecOrder.randomElement(using: &rng),
              let type = editor.schema.nodes[name] else { return "setNodeMarkup(skipped)" }
        let tr = editor.state.tr
        var attrs: Attrs = [:]
        for (attr, spec) in type.attrs.sorted(by: { $0.key < $1.key }) where !spec.hasDefault {
            attrs[attr] = fuzzAttrValue(attr, &rng)
        }
        _ = try? tr.setNodeMarkup(at, type, attrs)
        editor.dispatch(tr)
        return "setNodeMarkup(\(at), \(node.type.name) -> \(type.name))"
    default:
        // `clearIncompatible` is what every block-type conversion runs before
        // it retypes a node: strip the children and marks the new parent won't
        // take. It is only ever called with a type the caller already chose, so
        // the pairing it gets tested against in the hand-written suites is
        // always a sensible one. Here it is any node against any type.
        guard let at = fuzzNodePositions(editor.doc).randomElement(using: &rng),
              let node = editor.doc.nodeAt(at), !node.isText, !node.isLeaf,
              let name = editor.schema.nodeSpecOrder.randomElement(using: &rng),
              let type = editor.schema.nodes[name] else { return "clearIncompatible(skipped)" }
        let tr = editor.state.tr
        _ = try? tr.clearIncompatible(at, type)
        editor.dispatch(tr)
        return "clearIncompatible(\(at), \(node.type.name) as \(type.name))"
    }
}

/// A mark of a random type, with plausible values for whatever attributes it
/// requires.
func fuzzRandomMark(_ schema: Schema, _ rng: inout SelRNG) -> Mark? {
    guard let type = schema.markSpecOrder.randomElement(using: &rng)
        .flatMap({ schema.marks[$0] }) else { return nil }
    var attrs: Attrs = [:]
    if type.attrs["href"] != nil { attrs["href"] = .string("https://example.com/") }
    if type.attrs["color"] != nil { attrs["color"] = .string("#00ff00") }
    return schema.mark(type, attrs)
}

/// Every mark actually worn by content in `from ..< to` — the only marks a
/// `removeMark` over that range can produce a step for.
func fuzzMarksInRange(_ doc: Node, _ from: Int, _ to: Int) -> [Mark] {
    guard from < to, to <= doc.content.size else { return [] }
    var out: [Mark] = []
    doc.nodesBetween(from, to) { node, _, _, _ in
        for mark in node.marks where !out.contains(where: { $0.eq(mark) }) { out.append(mark) }
        return true
    }
    return out
}

/// A plausible value for an attribute, by name.
///
/// Typed rather than always-a-string: `level` is an int and `checked` a bool,
/// and an `AttrStep` that writes the wrong type into one is a document the
/// serializers then have to guess about, which is a different bug from the one
/// these sweeps are hunting.
func fuzzAttrValue(_ name: String, _ rng: inout SelRNG) -> AttributeValue {
    switch name {
    case "level": return .int(Int.random(in: 1 ... 6, using: &rng))
    case "checked", "open": return .bool(Bool.random(using: &rng))
    case "href", "src": return .string("https://example.com/a")
    case "latex": return .string(["x^2", "\\frac{a}{b}", ""].randomElement(using: &rng)!)
    case "colspan", "rowspan": return .int(Int.random(in: 1 ... 3, using: &rng))
    case "colwidth": return .null
    default: return .string(["x", "", "note"].randomElement(using: &rng)!)
    }
}

/// Every position holding a non-text node — the input for the steps that
/// address a node rather than a range (`AttrStep`, the node-mark steps,
/// `setNodeMarkup`).
func fuzzNodePositions(_ doc: Node) -> [Int] {
    var out: [Int] = []
    doc.descendants { node, pos, _, _ in
        if !node.isText { out.append(pos) }
        return true
    }
    return out
}

/// A random slice, sometimes a well-formed cut of the document and sometimes a
/// hand-built one whose open depths don't describe its content.
///
/// Both matter, and for different reasons. A cut of the document is what copy
/// and drag produce, so it is the input the fitter is *meant* to place. A
/// hand-built one with an over-large `openStart` is what arrives from a peer,
/// from a corrupt pasteboard, and from a serializer with a bug — the fitter is
/// allowed to refuse it, and not allowed to trap on it or to place it into a
/// document the schema rejects.
func fuzzSlice(_ schema: Schema, _ rng: inout SelRNG, cutFrom doc: Node? = nil) -> Slice {
    if let doc, doc.content.size > 0, Bool.random(using: &rng) {
        let a = Int.random(in: 0 ... doc.content.size, using: &rng)
        let b = Int.random(in: 0 ... doc.content.size, using: &rng)
        return doc.slice(Swift.min(a, b), Swift.max(a, b))
    }
    var nodes: [Node] = []
    for _ in 0 ..< Int.random(in: 0 ... 3, using: &rng) {
        switch Int.random(in: 0 ..< 4, using: &rng) {
        case 0: nodes.append(schema.text(fuzzOpText(&rng) + "t"))
        case 1:
            if let p = schema.nodes["paragraph"]?.createAndFill([:], content: Fragment.from(schema.text("p"))) {
                nodes.append(p)
            }
        case 2:
            if let li = schema.nodes["listItem"], let p = schema.nodes["paragraph"],
               let inner = p.createAndFill([:], content: Fragment.from(schema.text("i"))),
               let item = li.createAndFill([:], content: Fragment.from(inner)) {
                nodes.append(item)
            }
        default:
            if let cell = schema.nodes["tableCell"], let n = cell.createAndFill() { nodes.append(n) }
        }
    }
    let content = Fragment.from(nodes)
    // Deliberately unclamped: an open depth deeper than the content is exactly
    // the malformed input this arm exists to hand over.
    return Slice(content: content,
                 openStart: Int.random(in: 0 ... 3, using: &rng),
                 openEnd: Int.random(in: 0 ... 3, using: &rng))
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

    init(_ extensions: [any Extension] = fuzzKit(), content: Node? = nil) throws {
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
