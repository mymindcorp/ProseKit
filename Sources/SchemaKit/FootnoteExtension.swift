import Foundation
public import DocumentModel
import DocumentTransform
public import EditorStateKit
public import EditorCommands

// Footnotes, as GitHub and Markdig spell them: `[^1]` in the text, and
// `[^1]: the note` as its own block holding the note's content.
//
// Tiptap has no footnote extension to follow, so the shape here is ours. Two
// nodes rather than one:
//
//   footnoteReference — an inline atom carrying a `label`
//   footnoteDefinition — a block carrying the same `label` and the note itself
//
// ProseMirror's own footnote example instead puts the note's content *inside*
// the inline node and edits it through a node view with a nested editor. That
// needs a view layer that can host an editor inside a text run, which CoreText
// is not. Two nodes keep the note as ordinary blocks: it is editable with the
// machinery that already exists, and it maps onto both the Markdown and the
// HTML without rearranging anything.
//
// `label` is an identifier, not a number. `[^note]` keeps that spelling through
// a round trip, and the *displayed* number is the reference's position in the
// document — which is what GitHub shows, and what `footnoteNumbers` computes.
// Nothing renumbers the labels behind the author's back.
//
// Not registered by `fullKit()`: add `footnoteExtensions()` to opt in.

public final class FootnoteReferenceExtension: NodeExtension {
    public let name = "footnoteReference"
    public init() {}
    public var nodeSpec: NodeSpec {
        NodeSpec(
            group: "inline",
            inline: true,
            atom: true,
            attrs: ["label": AttributeSpec(default: .string(""))],
            selectable: true,
            draggable: false,
            // What the reference reads as in plain text — `textContent`, a
            // copied selection, spell-check's view of the line.
            leafText: { node in "[^" + (node.attrs["label"]?.stringValue ?? "") + "]" })
    }
    public var html: HTMLSpec { HTMLSpec(tag: "sup") }
}

public final class FootnoteDefinitionExtension: NodeExtension {
    public let name = "footnoteDefinition"
    public init() {}
    public var nodeSpec: NodeSpec {
        NodeSpec(content: "block+", group: "block",
                 attrs: ["label": AttributeSpec(default: .string(""))],
                 defining: true, isolating: true)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "div") }

    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        ["insertFootnote": insertFootnote, "removeFootnote": removeFootnote]
    }

    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        ["Mod-Alt-f": insertFootnote]
    }
}

/// Both footnote extensions. Deliberately absent from `fullKit()` — a document
/// that has never had a footnote in it shouldn't carry the nodes.
public func footnoteExtensions() -> [any Extension] {
    [FootnoteReferenceExtension(), FootnoteDefinitionExtension()]
}

// MARK: - Reading the footnotes in a document

/// Every footnote reference in the document, in the order it is read.
public func footnoteReferences(_ doc: Node) -> [(pos: Int, label: String)] {
    var found: [(Int, String)] = []
    doc.descendants { node, pos, _, _ in
        if node.type.name == "footnoteReference" {
            found.append((pos, node.attrs["label"]?.stringValue ?? ""))
        }
        return true
    }
    return found
}

/// Every footnote definition, in document order.
public func footnoteDefinitions(_ doc: Node) -> [(pos: Int, label: String)] {
    var found: [(Int, String)] = []
    doc.descendants { node, pos, _, _ in
        if node.type.name == "footnoteDefinition" {
            found.append((pos, node.attrs["label"]?.stringValue ?? ""))
        }
        return true
    }
    return found
}

/// The number to show for each label: 1, 2, 3… in the order the references are
/// read, which is how GitHub numbers them however the labels are spelled. A
/// label used twice keeps one number, and a definition nothing refers to takes
/// the next number after the referenced ones so it still shows something.
public func footnoteNumbers(_ doc: Node) -> [String: Int] {
    var numbers: [String: Int] = [:]
    var next = 1
    for (_, label) in footnoteReferences(doc) where numbers[label] == nil {
        numbers[label] = next
        next += 1
    }
    for (_, label) in footnoteDefinitions(doc) where numbers[label] == nil {
        numbers[label] = next
        next += 1
    }
    return numbers
}

/// A label no footnote is using yet: the lowest positive number that's free.
///
/// Only numeric labels are considered when counting, so a document written with
/// `[^note]` still gets `[^1]` for its first inserted footnote.
public func nextFootnoteLabel(_ doc: Node) -> String {
    var used = Set<String>()
    for (_, label) in footnoteReferences(doc) { used.insert(label) }
    for (_, label) in footnoteDefinitions(doc) { used.insert(label) }
    var n = 1
    while used.contains(String(n)) { n += 1 }
    return String(n)
}

// MARK: - Commands

/// Insert a footnote: a reference at the cursor, and its definition at the end
/// of the document with an empty paragraph to type the note into.
///
/// The selection moves into that paragraph, since writing the note is what you
/// do next. Nothing is inserted when the cursor isn't somewhere a reference may
/// go — inside a code block, say.
public let insertFootnote: Command = { state, dispatch, _ in
    let schema = state.schema
    guard let referenceType = schema.nodes["footnoteReference"],
          let definitionType = schema.nodes["footnoteDefinition"],
          let paragraphType = schema.nodes["paragraph"] else { return false }
    let selection = state.selection
    guard selection.empty || selection.from < selection.to else { return false }
    let resolved = state.doc.resolve(selection.from)
    guard resolved.parent.type.spec.code != true,
          resolved.parent.inlineContent else { return false }

    let label = nextFootnoteLabel(state.doc)
    guard let reference = try? referenceType.create(["label": .string(label)]),
          let paragraph = paragraphType.createAndFill(),
          let definition = try? definitionType.create(["label": .string(label)],
                                                      content: Fragment.from([paragraph]))
    else { return false }

    let tr = state.tr.replaceSelectionWith(reference)
    // Replacement fitting may silently drop a reference that the parent does
    // not allow. Never publish only one half of the footnote, even in a dry run.
    guard footnoteReferences(tr.doc).contains(where: { $0.label == label }) else { return false }
    // Require the definition itself at the document end. A fitted insertion
    // could otherwise discard its wrapper and leave an ordinary paragraph.
    let end = tr.doc.content.size
    guard (try? tr.step(ReplaceStep(end, end,
        Slice(content: Fragment.from(definition), openStart: 0, openEnd: 0)))) != nil else { return false }
    tr.setSelection(Selection.near(tr.doc.resolve(end + 2)))
    dispatch?(tr.scrollIntoView())
    return true
}

/// Remove the footnote the selection is on: the reference, and the definition
/// carrying the same label.
///
/// Works from either end — the cursor next to a reference, or anywhere inside
/// the definition — because either is where you notice you don't want it.
public let removeFootnote: Command = { state, dispatch, _ in
    guard let label = footnoteLabelAtSelection(state) else { return false }
    let tr = state.tr
    // Highest position first, so removing one doesn't move the next.
    var targets: [(pos: Int, size: Int)] = []
    var remainingReferences: [String] = []
    var remainingDefinitions: [String] = []
    tr.doc.descendants { node, pos, _, _ in
        let name = node.type.name
        guard name == "footnoteReference" || name == "footnoteDefinition" else { return true }
        if node.attrs["label"]?.stringValue == label {
            targets.append((pos, node.nodeSize))
            // Its contents will be deleted with it. Other definitions can
            // contain references to this label, so keep searching those.
            return false
        }
        let retainedLabel = node.attrs["label"]?.stringValue ?? ""
        if name == "footnoteReference" { remainingReferences.append(retainedLabel) }
        else { remainingDefinitions.append(retainedLabel) }
        return true
    }
    for target in targets.sorted(by: { $0.pos > $1.pos }) {
        if tr.doc.nodeAt(target.pos)?.type.name == "footnoteReference" {
            // Fitting a deletion can replace a required reference with a new,
            // empty-label reference. Refuse the whole operation instead of
            // deleting its definition and publishing a broken footnote.
            guard (try? tr.step(ReplaceStep(target.pos, target.pos + target.size, .empty))) != nil else { return false }
        } else {
            // A removed definition may need an empty paragraph in its place
            // to keep a block container (including the document) valid.
            guard (try? tr.delete(target.pos, target.pos + target.size)) != nil else { return false }
        }
    }
    // Fitting may synthesize a required definition, or remove more than the
    // requested nodes. Only publish a removal that leaves precisely the
    // surviving references and definitions collected above.
    guard footnoteReferences(tr.doc).map(\.label) == remainingReferences,
          footnoteDefinitions(tr.doc).map(\.label) == remainingDefinitions else { return false }
    dispatch?(tr)
    return true
}

/// The label of the footnote the selection sits in or beside, if any.
public func footnoteLabelAtSelection(_ state: EditorState) -> String? {
    // An explicit node selection takes precedence over enclosing definitions.
    if let selected = (state.selection as? NodeSelection)?.node,
       selected.type.name == "footnoteReference" || selected.type.name == "footnoteDefinition" {
        return selected.attrs["label"]?.stringValue
    }
    let resolved = state.doc.resolve(state.selection.from)
    // Inside a definition, at any depth.
    for depth in stride(from: resolved.depth, through: 0, by: -1)
    where resolved.node(depth).type.name == "footnoteDefinition" {
        return resolved.node(depth).attrs["label"]?.stringValue
    }
    // Selecting another atom is not a cursor beside the reference. It may
    // still belong to an enclosing definition, which was handled above.
    if state.selection is NodeSelection { return nil }
    // A range may include a reference at its start, but a reference before
    // the range is outside the selection. Only a caret can target that neighbor.
    let candidates = state.selection.empty ? [resolved.nodeAfter, resolved.nodeBefore] : [resolved.nodeAfter]
    for node in candidates {
        if node?.type.name == "footnoteReference" { return node?.attrs["label"]?.stringValue }
    }
    return nil
}
