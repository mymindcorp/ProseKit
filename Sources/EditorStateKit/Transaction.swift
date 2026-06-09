import DocumentModel
import DocumentTransform

/// An editing transaction: a `Transform` that also tracks the selection,
/// stored marks, scroll intent, and arbitrary metadata. Applying a transaction
/// to an `EditorState` produces a new state.
public final class Transaction: Transform {
    private var curSelection: Selection
    private var curSelectionFor: Int = 0
    /// The stored marks set for this transaction, if any.
    public private(set) var storedMarks: [Mark]?
    private var updatedMarks = false
    private var meta: [String: Any] = [:]
    /// Whether the view should scroll the selection into view.
    public private(set) var scrolledIntoView = false
    /// The timestamp (ms) at which the transaction was created.
    public var time: Double

    init(_ state: EditorState) {
        self.curSelection = state.selection
        self.storedMarks = state.storedMarks
        self.time = 0
        super.init(state.doc)
    }

    /// The transaction's current selection, mapped to the latest document.
    public var selection: Selection {
        if curSelectionFor < steps.count {
            curSelection = curSelection.map(doc, mapping.slice(curSelectionFor))
            curSelectionFor = steps.count
        }
        return curSelection
    }

    /// Whether the selection was explicitly updated by this transaction.
    public private(set) var selectionSet = false
    /// Whether stored marks were explicitly updated.
    public var storedMarksSet: Bool { updatedMarks }

    public override func addStep(_ step: Step, _ doc: Node) {
        super.addStep(step, doc)
        updatedMarks = false
        storedMarks = nil
    }

    /// Update the selection.
    @discardableResult
    public func setSelection(_ selection: Selection) -> Transaction {
        curSelection = selection
        curSelectionFor = steps.count
        selectionSet = true
        updatedMarks = false
        storedMarks = nil
        return self
    }

    /// Set the stored marks.
    @discardableResult
    public func setStoredMarks(_ marks: [Mark]?) -> Transaction {
        storedMarks = marks
        updatedMarks = true
        return self
    }

    /// Ensure the given marks are the stored marks.
    @discardableResult
    public func ensureMarks(_ marks: [Mark]) -> Transaction {
        if !Mark.sameSet(storedMarks ?? selection.resolvedFrom.marks(), marks) {
            setStoredMarks(marks)
        }
        return self
    }

    @discardableResult
    public func addStoredMark(_ mark: Mark) -> Transaction {
        ensureMarks(mark.addToSet(storedMarks ?? selection.resolvedHead.marks()))
    }

    @discardableResult
    public func removeStoredMark(_ mark: Mark) -> Transaction {
        ensureMarks(mark.removeFromSet(storedMarks ?? selection.resolvedHead.marks()))
    }

    @discardableResult
    public func removeStoredMark(_ markType: MarkType) -> Transaction {
        let marks = storedMarks ?? selection.resolvedHead.marks()
        return ensureMarks(marks.filter { $0.type !== markType })
    }

    // MARK: - Selection editing

    /// Replace the current selection with the given slice.
    @discardableResult
    public func replaceSelection(_ slice: Slice) -> Transaction {
        selection.replace(self, slice)
        return self
    }

    /// Replace the current selection with the given node.
    @discardableResult
    public func replaceSelectionWith(_ node: Node, inheritMarks: Bool = true) -> Transaction {
        let selection = self.selection
        var node = node
        if inheritMarks {
            // Apply the inherited marks directly (like ProseMirror) — don't filter by
            // node.type.allowedMarks: a text node's own markSet is empty, so filtering
            // would wrongly strip inline marks the parent block does allow.
            let marks = storedMarks ?? (selection.empty ? selection.resolvedFrom.marks()
                : (selection.resolvedFrom.marksAcross(selection.resolvedTo) ?? Mark.none))
            node = node.mark(marks)
        }
        selection.replaceWith(self, node)
        return self
    }

    /// Delete the current selection.
    @discardableResult
    public func deleteSelection() -> Transaction {
        selection.replace(self, .empty)
        return self
    }

    /// Replace the given range (or the selection) with text.
    @discardableResult
    public func insertText(_ text: String, _ from: Int? = nil, _ to: Int? = nil) throws -> Transaction {
        let schema = doc.type.schema!
        if from == nil {
            if text.isEmpty { return deleteSelection() }
            return replaceSelectionWith(schema.text(text), inheritMarks: true)
        }
        let from = from!
        let to = to ?? from
        if text.isEmpty {
            try delete(from, to)
            return self
        }
        let marks = storedMarks ?? (to == from ? doc.resolve(from).marks()
            : (doc.resolve(from).marksAcross(doc.resolve(to)) ?? Mark.none))
        try replaceWith(from, to, schema.text(text, marks))
        return self
    }

    // MARK: - Meta

    @discardableResult
    public func setMeta(_ key: String, _ value: Any) -> Transaction {
        meta[key] = value
        return self
    }

    public func getMeta(_ key: String) -> Any? { meta[key] }

    @discardableResult
    public func scrollIntoView() -> Transaction {
        scrolledIntoView = true
        return self
    }
}
