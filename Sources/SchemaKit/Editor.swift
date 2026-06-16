import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorHistory
import EditorKeymap
import EditorSerialization

/// The high-level editor facade (the Tiptap `Editor`). Builds a schema from a
/// set of extensions, owns the `EditorState`, and exposes commands.
public final class Editor {
    public private(set) var manager: ExtensionManager
    public private(set) var state: EditorState
    /// Called after every state update.
    public var onChange: ((EditorState) -> Void)?
    /// Called for every applied transaction, before `onChange`. Gives views
    /// access to the transaction's mapping (e.g. to shift cached overlays).
    public var onTransaction: ((Transaction) -> Void)?
    /// Called after a state update whose selection changed (whether or not the
    /// document also changed) — e.g. to refresh toolbar active-state. Fires after
    /// `onChange`.
    public var onSelectionUpdate: ((EditorState) -> Void)?
    /// Optional host for view-dependent command behaviour.
    public weak var host: AnyObject?

    private var namedCommands: [String: Command] = [:]
    /// Suggestion menus contributed by the extensions (slash, wiki, mentions…).
    public private(set) var suggestionSources: [any SuggestionSource] = []

    public var schema: Schema { manager.schema }

    /// Create an editor from extensions and optional initial content (a doc
    /// node, or `nil` for an empty document).
    public init(extensions: [any Extension], content: Node? = nil, history includeHistory: Bool = true) throws {
        let manager = try ExtensionManager(extensions)
        self.manager = manager
        // Temporary placeholder state; rebuilt below once `self` exists.
        self.state = EditorState.create(EditorStateConfig(schema: manager.schema))

        var plugins: [Plugin] = []
        if includeHistory {
            plugins.append(EditorHistory.history())
        }
        plugins.append(contentsOf: manager.buildPlugins(editor: self))
        if includeHistory {
            // Undo/redo keymap as a final keymap layer.
            plugins.append(keymap([
                "Mod-z": { s, d, _ in EditorHistory.undo(s, d) },
                "Mod-y": { s, d, _ in EditorHistory.redo(s, d) },
                "Shift-Mod-z": { s, d, _ in EditorHistory.redo(s, d) },
            ]))
        }
        self.state = EditorState.create(EditorStateConfig(schema: manager.schema, doc: content, plugins: plugins))
        self.namedCommands = manager.commands(editor: self)
        self.suggestionSources = manager.suggestionSources(editor: self)
    }

    // MARK: - Dispatch

    /// Monotonic counter bumped only when a dispatched transaction changes the
    /// document (not for selection-only changes). Renderers key layout caches
    /// off this so moving the caret never invalidates the layout.
    public private(set) var docRevision = 0

    /// Apply a transaction and notify observers. Stamps the transaction's time
    /// so undo history groups rapid edits but separates distinct user actions.
    public func dispatch(_ tr: Transaction) {
        if tr.time == 0 { tr.time = Date().timeIntervalSince1970 * 1000 }
        if tr.docChanged { docRevision &+= 1 }
        let oldSelection = state.selection
        state = state.apply(tr)
        onTransaction?(tr)
        onChange?(state)
        if !state.selection.eq(oldSelection) { onSelectionUpdate?(state) }
    }

    /// Run a command against the current state, dispatching its transaction.
    @discardableResult
    public func run(_ command: Command) -> Bool {
        command(state, { [weak self] tr in self?.dispatch(tr) }, host as? any CommandHost)
    }

    /// Whether a command would apply (a dry run, without dispatching).
    public func can(_ command: Command) -> Bool {
        command(state, nil, host as? any CommandHost)
    }

    /// Run a named command contributed by an extension.
    @discardableResult
    public func run(_ name: String) -> Bool {
        guard let command = namedCommands[name] else { return false }
        return run(command)
    }

    /// Apply a text color (a CSS color string, named or hex) over the selection;
    /// pass nil to remove it. No-op if the textColor mark isn't in the schema.
    @discardableResult
    public func setTextColor(_ color: String?) -> Bool {
        guard let type = schema.marks["textColor"] else { return false }
        return run(setColor(type, color))
    }

    /// Apply a background color over the selection; pass nil to remove it.
    @discardableResult
    public func setBackgroundColor(_ color: String?) -> Bool {
        guard let type = schema.marks["backgroundColor"] else { return false }
        return run(setColor(type, color))
    }

    /// Run a sequence of commands as a chain, threading state through each.
    /// Returns true if all applied.
    @discardableResult
    public func chain(_ commands: [Command]) -> Bool {
        let oldSelection = state.selection
        var working = state
        var any = false
        var changedDoc = false
        var applied: [Transaction] = []
        for command in commands {
            var produced: Transaction? = nil
            let did = command(working, { produced = $0 }, host as? any CommandHost)
            if did, let tr = produced {
                if tr.docChanged { changedDoc = true }
                working = working.apply(tr)
                applied.append(tr)
                any = true
            } else if !did {
                return false
            }
        }
        if any {
            if changedDoc { docRevision &+= 1 }
            state = working
            for tr in applied { onTransaction?(tr) }
            onChange?(state)
            if !state.selection.eq(oldSelection) { onSelectionUpdate?(state) }
        }
        return true
    }

    // MARK: - Queries

    /// Whether the selection is inside a node of the given name (and attrs).
    public func isActive(node name: String, attrs: Attrs? = nil) -> Bool {
        guard let type = schema.nodes[name] else { return false }
        let sel = state.selection
        let from = sel.resolvedFrom
        var depth = from.depth
        while depth >= 0 {
            let node = from.node(depth)
            if node.type === type, attrs == nil || attrsMatch(node.attrs, attrs!) { return true }
            depth -= 1
        }
        // node selection on a leaf
        if let ns = sel as? NodeSelection, ns.node.type === type {
            return attrs == nil || attrsMatch(ns.node.attrs, attrs!)
        }
        return false
    }

    /// Whether the given mark is active over the selection (or stored).
    public func isActive(mark name: String) -> Bool {
        guard let type = schema.marks[name] else { return false }
        let sel = state.selection
        if sel.empty {
            let marks = state.storedMarks ?? sel.resolvedFrom.marks()
            return type.isInSet(marks) != nil
        }
        for range in sel.ranges {
            if !state.doc.rangeHasMark(range.from.pos, range.to.pos, type) { return false }
            // Ensure it covers the whole range, not just part of it.
            var covered = true
            state.doc.nodesBetween(range.from.pos, range.to.pos, { node, _, _, _ in
                if node.isInline && type.isInSet(node.marks) == nil { covered = false }
                return true
            })
            if !covered { return false }
        }
        return true
    }

    /// The attributes of the given mark where it's active over the selection — the
    /// stored marks when the selection is empty, otherwise the first instance of
    /// the mark within it. nil when the mark isn't active. Use this to seed a
    /// toolbar (e.g. the current link's `href`, or the active text color).
    public func attributes(ofMark name: String) -> Attrs? {
        guard let type = schema.marks[name] else { return nil }
        let sel = state.selection
        if sel.empty {
            let marks = state.storedMarks ?? sel.resolvedFrom.marks()
            return type.isInSet(marks)?.attrs
        }
        var found: Attrs?
        for range in sel.ranges where found == nil {
            state.doc.nodesBetween(range.from.pos, range.to.pos, { node, _, _, _ in
                if found == nil, node.isInline, let m = type.isInSet(node.marks) { found = m.attrs }
                return found == nil
            })
        }
        return found
    }

    /// The attributes of the closest ancestor node of the given name.
    public func attributes(ofNode name: String) -> Attrs? {
        guard let type = schema.nodes[name] else { return nil }
        let from = state.selection.resolvedFrom
        var depth = from.depth
        while depth >= 0 {
            let node = from.node(depth)
            if node.type === type { return node.attrs }
            depth -= 1
        }
        return nil
    }

    // MARK: - Content

    public var doc: Node { state.doc }
    public func json() -> [String: AttributeValue] { state.doc.toJSON() }

    /// Whether the document is effectively empty — a single empty textblock.
    public var isEmpty: Bool {
        state.doc.childCount == 1
            && state.doc.firstChild?.isTextblock == true
            && state.doc.firstChild?.content.size == 0
    }

    /// Reset the document to a single empty default block (not undoable).
    public func clearContent() {
        guard let empty = schema.topNodeType.createAndFill() else { return }
        setContent(empty)
    }

    /// The document serialized to HTML.
    public func getHTML() -> String { HTMLSerializer.serialize(state.doc) }

    /// The document serialized to Markdown.
    public func getMarkdown() -> String { MarkdownSerializer.serialize(state.doc) }

    /// The document's plain text, with block boundaries as newlines.
    public func getText() -> String {
        state.doc.textBetween(0, state.doc.content.size, blockSeparator: "\n")
    }

    public func setContent(_ doc: Node) {
        let tr = state.tr
        _ = try? tr.replaceWith(0, state.doc.content.size, doc.content)
        tr.setSelection(Selection.atStart(tr.doc))
        tr.setMeta("addToHistory", false) // initial/replaced content isn't undoable
        dispatch(tr)
    }

    /// Replace the document with content parsed from an HTML string. Throws if the
    /// HTML can't be parsed against the schema.
    public func setContent(html: String) throws {
        setContent(try HTMLParser.parse(html, schema: schema))
    }

    /// Insert a node at `pos` (a valid block boundary is found for a block node),
    /// or replace the current selection when `pos` is nil. Returns false if the
    /// insertion didn't change the document.
    @discardableResult
    public func insertContent(_ node: Node, at pos: Int? = nil) -> Bool {
        let tr = state.tr
        if let pos {
            let p = min(max(pos, 0), tr.doc.content.size)
            guard (try? tr.replaceRangeWith(p, p, node)) != nil else { return false }
        } else {
            tr.replaceSelectionWith(node)
        }
        guard tr.docChanged else { return false }
        dispatch(tr.scrollIntoView())
        return true
    }

    /// Insert content parsed from an HTML string at `pos` (or over the current
    /// selection when nil). Throws if the HTML can't be parsed.
    @discardableResult
    public func insertContent(html: String, at pos: Int? = nil) throws -> Bool {
        let parsed = try HTMLParser.parse(html, schema: schema)
        let slice = Slice(content: parsed.content, openStart: 0, openEnd: 0)
        let tr = state.tr
        let from = pos.map { min(max($0, 0), tr.doc.content.size) } ?? state.selection.from
        let to = pos != nil ? from : state.selection.to
        guard (try? tr.replaceRange(from, to, slice)) != nil, tr.docChanged else { return false }
        dispatch(tr.scrollIntoView())
        return true
    }
}

private func attrsMatch(_ a: Attrs, _ subset: Attrs) -> Bool {
    for (key, value) in subset where a[key] != value { return false }
    return true
}
