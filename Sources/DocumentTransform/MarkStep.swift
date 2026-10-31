public import DocumentModel

/// Map every inline node in a fragment through a transformation function.
private func mapFragment(_ fragment: Fragment, _ f: (Node, Node?, Int) -> Node, _ parent: Node?) -> Fragment {
    var mapped: [Node] = []
    for i in 0..<fragment.childCount {
        var child = fragment.child(i)
        if child.content.size != 0 {
            child = child.copy(content: mapFragment(child.content, f, child))
        }
        if child.isInline {
            child = f(child, parent, i)
        }
        mapped.append(child)
    }
    return Fragment.from(mapped)
}

/// Add a mark to all inline content between two positions.
public struct AddMarkStep: Step {
    public let from: Int
    public let to: Int
    public let mark: Mark

    public init(_ from: Int, _ to: Int, _ mark: Mark) {
        self.from = from; self.to = to; self.mark = mark
    }

    public var jsonID: String { "addMark" }

    public func apply(_ doc: Node) -> StepResult {
        if let failure = StepResult.outOfRange(doc, from, to) { return failure }
        let oldSlice = doc.slice(from, to)
        let resolvedFrom = doc.resolve(from)
        let parent = resolvedFrom.node(resolvedFrom.sharedDepth(to))
        let content = mapFragment(oldSlice.content, { node, parent, _ in
            guard node.isAtom, let parent, parent.type.allowsMarkType(mark.type) else { return node }
            return node.mark(mark.addToSet(node.marks))
        }, parent)
        let slice = Slice(content: content, openStart: oldSlice.openStart, openEnd: oldSlice.openEnd)
        // Text left with equal marks joins, which can merge graphemes: a mark
        // step has an empty map, so it can't change the document's size.
        if slice.size != oldSlice.size { return .fail("Mark change would merge graphemes") }
        return .fromReplace(doc, from, to, slice)
    }

    /// Remove the mark only where this step added it, and put back any mark
    /// it pushed out by exclusion. A plain `RemoveMarkStep` over the range
    /// would also strip the mark from text that already had it, and leave a
    /// replaced mark (one link swapped for another) gone.
    public func invert(_ doc: Node) -> any Step {
        var steps: [any Step] = []
        doc.nodesBetween(from, to, { node, pos, _, _ in
            if node.isInline && node.isAtom {
                let added = mark.addToSet(node.marks)
                if added != node.marks {
                    let from = Swift.max(self.from, pos), to = Swift.min(self.to, pos + node.nodeSize)
                    pushMarkStep(&steps, adding: false, from, to, mark)
                    for m in node.marks where !m.isInSet(added) {
                        pushMarkStep(&steps, adding: true, from, to, m)
                    }
                }
            }
            return true
        })
        return steps.count == 1 ? steps[0] : MarkSetStep(steps)
    }

    /// Dropped only when nothing is left of the range. A step whose two ends
    /// were both deleted can still cover content between the deletions.
    public func map(_ mapping: any Mappable) -> (any Step)? {
        let from = mapping.map(self.from, 1)
        let to = mapping.map(self.to, -1)
        if from >= to { return nil }
        return AddMarkStep(from, to, mark)
    }

    public func merge(_ other: any Step) -> (any Step)? {
        guard let other = other as? AddMarkStep, other.mark == mark, from <= other.to, to >= other.from else { return nil }
        return AddMarkStep(Swift.min(from, other.from), Swift.max(to, other.to), mark)
    }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "addMark", "mark": .object(mark.toJSON()), "from": .int(from), "to": .int(to)]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> any Step {
        guard let from = json["from"]?.intValue, let to = json["to"]?.intValue,
              case let .object(markJSON)? = json["mark"] else {
            throw ModelError.invalidJSON("Invalid input for AddMarkStep.fromJSON")
        }
        try checkStepPositions("AddMarkStep", from, to)
        try checkStepOrder("AddMarkStep", from, to)
        return AddMarkStep(from, to, try Mark.fromJSON(schema, markJSON))
    }
}

/// Remove a mark from all inline content between two positions.
public struct RemoveMarkStep: Step {
    public let from: Int
    public let to: Int
    public let mark: Mark

    public init(_ from: Int, _ to: Int, _ mark: Mark) {
        self.from = from; self.to = to; self.mark = mark
    }

    public var jsonID: String { "removeMark" }

    public func apply(_ doc: Node) -> StepResult {
        if let failure = StepResult.outOfRange(doc, from, to) { return failure }
        let oldSlice = doc.slice(from, to)
        let content = mapFragment(oldSlice.content, { node, _, _ in
            node.mark(mark.removeFromSet(node.marks))
        }, nil)
        let slice = Slice(content: content, openStart: oldSlice.openStart, openEnd: oldSlice.openEnd)
        // Text left with equal marks joins, which can merge graphemes: a mark
        // step has an empty map, so it can't change the document's size.
        if slice.size != oldSlice.size { return .fail("Mark change would merge graphemes") }
        return .fromReplace(doc, from, to, slice)
    }

    /// Add the mark back only where this step took it away.
    public func invert(_ doc: Node) -> any Step {
        var steps: [any Step] = []
        doc.nodesBetween(from, to, { node, pos, _, _ in
            if node.isInline && node.isAtom && mark.isInSet(node.marks) {
                pushMarkStep(&steps, adding: true, Swift.max(from, pos), Swift.min(to, pos + node.nodeSize), mark)
            }
            return true
        })
        return steps.count == 1 ? steps[0] : MarkSetStep(steps)
    }

    public func map(_ mapping: any Mappable) -> (any Step)? {
        let from = mapping.map(self.from, 1)
        let to = mapping.map(self.to, -1)
        if from >= to { return nil }
        return RemoveMarkStep(from, to, mark)
    }

    public func merge(_ other: any Step) -> (any Step)? {
        guard let other = other as? RemoveMarkStep, other.mark == mark, from <= other.to, to >= other.from else { return nil }
        return RemoveMarkStep(Swift.min(from, other.from), Swift.max(to, other.to), mark)
    }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "removeMark", "mark": .object(mark.toJSON()), "from": .int(from), "to": .int(to)]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> any Step {
        guard let from = json["from"]?.intValue, let to = json["to"]?.intValue,
              case let .object(markJSON)? = json["mark"] else {
            throw ModelError.invalidJSON("Invalid input for RemoveMarkStep.fromJSON")
        }
        try checkStepPositions("RemoveMarkStep", from, to)
        try checkStepOrder("RemoveMarkStep", from, to)
        return RemoveMarkStep(from, to, try Mark.fromJSON(schema, markJSON))
    }
}

/// Append an add- or remove-mark step to `target`, extending the last step
/// instead when it is the same kind, for the same mark, and ends where this
/// one starts.
func pushMarkStep(_ target: inout [any Step], adding: Bool, _ from: Int, _ to: Int, _ mark: Mark) {
    if adding, let last = target.last as? AddMarkStep, last.to == from, last.mark == mark {
        target[target.count - 1] = AddMarkStep(last.from, to, mark)
    } else if !adding, let last = target.last as? RemoveMarkStep, last.to == from, last.mark == mark {
        target[target.count - 1] = RemoveMarkStep(last.from, to, mark)
    } else {
        target.append(adding ? AddMarkStep(from, to, mark) : RemoveMarkStep(from, to, mark))
    }
}

/// Several add- and remove-mark steps applied in order, as one step. This is
/// what inverting a mark step produces when undoing it takes more than one
/// range or more than one mark.
public struct MarkSetStep: Step {
    /// Only `AddMarkStep`s and `RemoveMarkStep`s. A `MarkSetStep` passed in is
    /// spliced into its parent, so this never nests.
    public let steps: [any Step]

    public init(_ steps: [any Step]) {
        self.steps = steps.flatMap { ($0 as? MarkSetStep)?.steps ?? [$0] }
    }

    public var jsonID: String { "markSet" }

    public func apply(_ doc: Node) -> StepResult {
        var doc = doc
        for step in steps {
            let result = step.apply(doc)
            guard let next = result.doc else { return result }
            doc = next
        }
        return .ok(doc)
    }

    /// Upstream inverts every part against the document *before* the whole
    /// set and keeps their order. That is right for the sets mark-step
    /// inversion builds, where the parts never overlap except to swap an
    /// excluded mark back in, but not for a set in general. Here each part is
    /// inverted against the document it was actually applied to, and the
    /// inverses run last-first.
    public func invert(_ doc: Node) -> any Step {
        var doc = doc
        var inverses: [any Step] = []
        for step in steps {
            inverses.append(step.invert(doc))
            guard let next = step.apply(doc).doc else { break }
            doc = next
        }
        return MarkSetStep(inverses.reversed())
    }

    public func map(_ mapping: any Mappable) -> (any Step)? {
        let mapped = steps.compactMap { $0.map(mapping) }
        return mapped.isEmpty ? nil : MarkSetStep(mapped)
    }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "markSet", "steps": .array(steps.map { .object($0.toJSON()) })]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> any Step {
        guard case let .array(items)? = json["steps"] else {
            throw ModelError.invalidJSON("Invalid JSON for MarkSetStep")
        }
        var steps: [any Step] = []
        for item in items {
            guard case let .object(stepJSON) = item else {
                throw ModelError.invalidJSON("Invalid JSON for MarkSetStep")
            }
            switch stepJSON["stepType"]?.stringValue {
            case "addMark": steps.append(try AddMarkStep.fromJSON(schema, stepJSON))
            case "removeMark": steps.append(try RemoveMarkStep.fromJSON(schema, stepJSON))
            default: throw ModelError.invalidJSON("Invalid JSON for MarkSetStep")
            }
        }
        return MarkSetStep(steps)
    }
}

/// Add a mark to a single (block or atom) node.
public struct AddNodeMarkStep: Step {
    // Both node-mark steps build the same slice: the node with its marks
    // changed and its content *dropped*, open at the end so the document's own
    // copy of that content flows back in as the step is applied. Handing the
    // slice a node that still carries its content would put the content in
    // twice — once from the slice, once from the document — which is why these
    // rebuild the node through `create` rather than through `Node.mark`. The
    // same reason `AttrStep` passes `content: .empty`.
    public let pos: Int
    public let mark: Mark

    public init(_ pos: Int, _ mark: Mark) { self.pos = pos; self.mark = mark }

    public var jsonID: String { "addNodeMark" }

    public func apply(_ doc: Node) -> StepResult {
        guard let node = doc.nodeAt(pos) else { return .fail("No node at mark step's position") }
        guard let updated = try? node.type.create(node.attrs, content: .empty, marks: mark.addToSet(node.marks)) else {
            return .fail("Cannot create node with updated marks")
        }
        return .fromReplace(doc, pos, pos + 1, Slice(content: Fragment.from(updated), openStart: 0, openEnd: node.isLeaf ? 0 : 1))
    }

    public func invert(_ doc: Node) -> any Step {
        if let node = doc.nodeAt(pos) {
            let newSet = mark.addToSet(node.marks)
            if newSet.count == node.marks.count {
                for m in node.marks where !m.isInSet(newSet) { return AddNodeMarkStep(pos, m) }
                return AddNodeMarkStep(pos, mark)
            }
        }
        return RemoveNodeMarkStep(pos, mark)
    }

    public func map(_ mapping: any Mappable) -> (any Step)? {
        let p = mapping.mapResult(pos, 1)
        return p.deletedAfter ? nil : AddNodeMarkStep(p.pos, mark)
    }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "addNodeMark", "pos": .int(pos), "mark": .object(mark.toJSON())]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> any Step {
        guard let pos = json["pos"]?.intValue, case let .object(markJSON)? = json["mark"] else {
            throw ModelError.invalidJSON("Invalid input for AddNodeMarkStep.fromJSON")
        }
        return AddNodeMarkStep(pos, try Mark.fromJSON(schema, markJSON))
    }
}

/// Remove a mark from a single node.
public struct RemoveNodeMarkStep: Step {
    public let pos: Int
    public let mark: Mark

    public init(_ pos: Int, _ mark: Mark) { self.pos = pos; self.mark = mark }

    public var jsonID: String { "removeNodeMark" }

    public func apply(_ doc: Node) -> StepResult {
        guard let node = doc.nodeAt(pos) else { return .fail("No node at mark step's position") }
        guard let updated = try? node.type.create(node.attrs, content: .empty, marks: mark.removeFromSet(node.marks)) else {
            return .fail("Cannot create node with updated marks")
        }
        return .fromReplace(doc, pos, pos + 1, Slice(content: Fragment.from(updated), openStart: 0, openEnd: node.isLeaf ? 0 : 1))
    }

    public func invert(_ doc: Node) -> any Step {
        guard let node = doc.nodeAt(pos), mark.isInSet(node.marks) else { return self }
        return AddNodeMarkStep(pos, mark)
    }

    public func map(_ mapping: any Mappable) -> (any Step)? {
        let p = mapping.mapResult(pos, 1)
        return p.deletedAfter ? nil : RemoveNodeMarkStep(p.pos, mark)
    }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "removeNodeMark", "pos": .int(pos), "mark": .object(mark.toJSON())]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> any Step {
        guard let pos = json["pos"]?.intValue, case let .object(markJSON)? = json["mark"] else {
            throw ModelError.invalidJSON("Invalid input for RemoveNodeMarkStep.fromJSON")
        }
        return RemoveNodeMarkStep(pos, try Mark.fromJSON(schema, markJSON))
    }
}
