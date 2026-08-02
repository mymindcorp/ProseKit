public import DocumentModel

public enum TransformError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self { case let .failed(m): return "TransformError: \(m)" }
    }
}

/// Abstracts a series of document transformations as a sequence of `Step`s,
/// tracking the resulting documents and a `Mapping` over all the changes. This
/// is the base class for `Transaction`.
open class Transform {
    /// The current document (the result of applying the steps so far).
    public private(set) var doc: Node
    /// The steps in this transform.
    public private(set) var steps: [any Step] = []
    /// The documents before each of the steps.
    public private(set) var docs: [Node] = []
    /// A mapping with the maps for each of the steps in this transform.
    public let mapping = Mapping()

    public init(_ doc: Node) {
        self.doc = doc
    }

    /// The document at the start of the transformation.
    public var before: Node { docs.first ?? doc }

    /// Apply a new step, throwing if it fails.
    @discardableResult
    public func step(_ step: any Step) throws -> Self {
        let result = maybeStep(step)
        if let failed = result.failed { throw TransformError.failed(failed) }
        return self
    }

    /// Try to apply a step, recording it (and its map) if successful.
    @discardableResult
    public func maybeStep(_ step: any Step) -> StepResult {
        let result = step.apply(doc)
        if let newDoc = result.doc { addStep(step, newDoc) }
        return result
    }

    /// True when the document has been changed (when there are any steps).
    public var docChanged: Bool { !steps.isEmpty }

    open func addStep(_ step: any Step, _ doc: Node) {
        docs.append(self.doc)
        steps.append(step)
        mapping.appendMap(step.getMap())
        self.doc = doc
    }

    // MARK: - Replacement

    /// Replace the part of the document between `from` and `to` with the given
    /// slice, fitting it to the surrounding structure.
    @discardableResult
    public func replace(_ from: Int, _ to: Int? = nil, _ slice: Slice = .empty) throws -> Self {
        let to = to ?? from
        if let s = replaceStep(doc, from, to, slice) {
            try step(s)
        }
        return self
    }

    /// Replace the given range with the given content, which may be a fragment,
    /// node, or array of nodes.
    @discardableResult
    public func replaceWith(_ from: Int, _ to: Int, _ content: Fragment) throws -> Self {
        try replace(from, to, Slice(content: content, openStart: 0, openEnd: 0))
    }

    @discardableResult
    public func replaceWith(_ from: Int, _ to: Int, _ content: Node) throws -> Self {
        try replaceWith(from, to, Fragment.from(content))
    }

    /// Delete the content between the given positions.
    @discardableResult
    public func delete(_ from: Int, _ to: Int) throws -> Self {
        try replace(from, to, .empty)
    }

    /// Insert the given content at the given position.
    @discardableResult
    public func insert(_ pos: Int, _ content: Fragment) throws -> Self {
        try replaceWith(pos, pos, content)
    }

    @discardableResult
    public func insert(_ pos: Int, _ content: Node) throws -> Self {
        try replaceWith(pos, pos, Fragment.from(content))
    }
}
