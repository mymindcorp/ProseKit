public import DocumentModel
import DocumentTransform

/// Configuration for creating an `EditorState`.
public struct EditorStateConfig {
    public var schema: Schema
    public var doc: Node?
    public var selection: Selection?
    public var storedMarks: [Mark]?
    public var plugins: [Plugin]

    public init(schema: Schema, doc: Node? = nil, selection: Selection? = nil, storedMarks: [Mark]? = nil, plugins: [Plugin] = []) {
        self.schema = schema
        self.doc = doc
        self.selection = selection
        self.storedMarks = storedMarks
        self.plugins = plugins
    }
}

/// The state of an editor. Immutable: applying a transaction yields a new
/// `EditorState`. Holds the document, the current selection, the active stored
/// marks, and each plugin's state.
public final class EditorState: @unchecked Sendable {
    public let schema: Schema
    public let plugins: [Plugin]
    public let doc: Node
    public let selection: Selection
    public let storedMarks: [Mark]?
    /// Per-plugin state, keyed by plugin key.
    public internal(set) var pluginState: [String: Any] = [:]

    private init(schema: Schema, plugins: [Plugin], doc: Node, selection: Selection, storedMarks: [Mark]?) {
        self.schema = schema
        self.plugins = plugins
        self.doc = doc
        self.selection = selection
        self.storedMarks = storedMarks
    }

    /// Start a new transaction from this state.
    public var tr: Transaction { Transaction(self) }

    /// Create a fresh state from a configuration.
    public static func create(_ config: EditorStateConfig) -> EditorState {
        let doc = config.doc ?? config.schema.topNodeType.createAndFill() ?? (try! config.schema.topNodeType.create())
        let selection = config.selection ?? Selection.atStart(doc)
        let state = EditorState(schema: config.schema, plugins: config.plugins, doc: doc, selection: selection, storedMarks: config.storedMarks)
        for plugin in config.plugins {
            if let field = plugin.stateField {
                state.pluginState[plugin.key] = field.initialize(config, state)
            }
        }
        return state
    }

    /// Apply a transaction, returning the resulting state.
    public func apply(_ tr: Transaction) -> EditorState {
        applyTransaction(tr).state
    }

    /// Apply a transaction, also returning any transactions appended by plugins.
    public func applyTransaction(_ rootTr: Transaction) -> (state: EditorState, transactions: [Transaction]) {
        if !filterTransaction(rootTr, nil) { return (self, []) }
        var trs: [Transaction] = [rootTr]
        var newState = applyInner(rootTr)
        var seen: [(state: EditorState, n: Int)]? = nil

        loop: while true {
            var haveNew = false
            for (i, plugin) in plugins.enumerated() {
                guard let append = plugin.appendTransaction else { continue }
                let n = seen?[i].n ?? 0
                let oldState = seen?[i].state ?? self
                let slice = n < trs.count ? Array(trs[n...]) : []
                if let tr = (n < trs.count ? append(n != 0 ? slice : trs, oldState, newState) : nil),
                   newState.filterTransaction(tr, i) {
                    tr.setMeta("appendedTransaction", rootTr)
                    if seen == nil {
                        seen = plugins.map { _ in (self, 0) }
                        for j in 0..<plugins.count { seen![j] = (self, trs.count) }
                    }
                    trs.append(tr)
                    newState = newState.applyInner(tr)
                    haveNew = true
                }
                if seen != nil { seen![i] = (newState, trs.count) }
            }
            if !haveNew { break loop }
        }
        return (newState, trs)
    }

    private func applyInner(_ tr: Transaction) -> EditorState {
        let newSelection = tr.selection
        let newStoredMarks = newSelection.empty ? tr.storedMarks : nil
        let newState = EditorState(schema: schema, plugins: plugins, doc: tr.doc, selection: newSelection, storedMarks: newStoredMarks)
        for plugin in plugins {
            if let field = plugin.stateField, let value = pluginState[plugin.key] {
                newState.pluginState[plugin.key] = field.apply(tr, value, self, newState)
            }
        }
        return newState
    }

    private func filterTransaction(_ tr: Transaction, _ ignore: Int?) -> Bool {
        for (i, plugin) in plugins.enumerated() where i != ignore {
            if let filter = plugin.filterTransaction, !filter(tr, self) { return false }
        }
        return true
    }

    /// Reconfigure the plugins on this state, preserving doc/selection.
    public func reconfigure(plugins: [Plugin]) -> EditorState {
        let config = EditorStateConfig(schema: schema, doc: doc, selection: selection, storedMarks: storedMarks, plugins: plugins)
        let newState = EditorState(schema: schema, plugins: plugins, doc: doc, selection: selection, storedMarks: storedMarks)
        for plugin in plugins {
            if let field = plugin.stateField {
                if let existing = pluginState[plugin.key] {
                    newState.pluginState[plugin.key] = existing
                } else {
                    newState.pluginState[plugin.key] = field.initialize(config, newState)
                }
            }
        }
        return newState
    }

    // MARK: - JSON

    public func toJSON() -> [String: AttributeValue] {
        ["doc": .object(doc.toJSON()), "selection": .object(selection.toJSON())]
    }

    public static func fromJSON(_ config: EditorStateConfig, _ json: [String: AttributeValue]) throws(ModelError) -> EditorState {
        guard case let .object(docJSON)? = json["doc"] else {
            throw ModelError.invalidJSON("Invalid input for EditorState.fromJSON")
        }
        let doc = try Node.fromJSON(config.schema, docJSON)
        var selection: Selection? = nil
        if case let .object(selJSON)? = json["selection"] {
            selection = try Selection.fromJSON(doc, selJSON)
        }
        var c = config
        c.doc = doc
        c.selection = selection
        return create(c)
    }
}
