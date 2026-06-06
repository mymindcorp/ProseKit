import DocumentModel

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
        let oldSlice = doc.slice(from, to)
        let resolvedFrom = doc.resolve(from)
        let parent = resolvedFrom.node(resolvedFrom.sharedDepth(to))
        let content = mapFragment(oldSlice.content, { node, parent, _ in
            guard node.isAtom, let parent, parent.type.allowsMarkType(mark.type) else { return node }
            return node.mark(mark.addToSet(node.marks))
        }, parent)
        let slice = Slice(content: content, openStart: oldSlice.openStart, openEnd: oldSlice.openEnd)
        return .fromReplace(doc, from, to, slice)
    }

    public func invert(_ doc: Node) -> Step { RemoveMarkStep(from, to, mark) }

    public func map(_ mapping: Mappable) -> Step? {
        let from = mapping.mapResult(self.from, 1)
        let to = mapping.mapResult(self.to, -1)
        if (from.deleted && to.deleted) || from.pos >= to.pos { return nil }
        return AddMarkStep(from.pos, Swift.max(from.pos, to.pos), mark)
    }

    public func merge(_ other: Step) -> Step? {
        guard let other = other as? AddMarkStep, other.mark == mark, from <= other.to, to >= other.from else { return nil }
        return AddMarkStep(Swift.min(from, other.from), Swift.max(to, other.to), mark)
    }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "addMark", "mark": .object(mark.toJSON()), "from": .int(from), "to": .int(to)]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> Step {
        guard let from = json["from"]?.intValue, let to = json["to"]?.intValue,
              case let .object(markJSON)? = json["mark"] else {
            throw ModelError.invalidJSON("Invalid input for AddMarkStep.fromJSON")
        }
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
        let oldSlice = doc.slice(from, to)
        let content = mapFragment(oldSlice.content, { node, _, _ in
            node.mark(mark.removeFromSet(node.marks))
        }, nil)
        let slice = Slice(content: content, openStart: oldSlice.openStart, openEnd: oldSlice.openEnd)
        return .fromReplace(doc, from, to, slice)
    }

    public func invert(_ doc: Node) -> Step { AddMarkStep(from, to, mark) }

    public func map(_ mapping: Mappable) -> Step? {
        let from = mapping.mapResult(self.from, 1)
        let to = mapping.mapResult(self.to, -1)
        if (from.deleted && to.deleted) || from.pos >= to.pos { return nil }
        return RemoveMarkStep(from.pos, Swift.max(from.pos, to.pos), mark)
    }

    public func merge(_ other: Step) -> Step? {
        guard let other = other as? RemoveMarkStep, other.mark == mark, from <= other.to, to >= other.from else { return nil }
        return RemoveMarkStep(Swift.min(from, other.from), Swift.max(to, other.to), mark)
    }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "removeMark", "mark": .object(mark.toJSON()), "from": .int(from), "to": .int(to)]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> Step {
        guard let from = json["from"]?.intValue, let to = json["to"]?.intValue,
              case let .object(markJSON)? = json["mark"] else {
            throw ModelError.invalidJSON("Invalid input for RemoveMarkStep.fromJSON")
        }
        return RemoveMarkStep(from, to, try Mark.fromJSON(schema, markJSON))
    }
}

/// Add a mark to a single (block or atom) node.
public struct AddNodeMarkStep: Step {
    public let pos: Int
    public let mark: Mark

    public init(_ pos: Int, _ mark: Mark) { self.pos = pos; self.mark = mark }

    public var jsonID: String { "addNodeMark" }

    public func apply(_ doc: Node) -> StepResult {
        guard let node = doc.nodeAt(pos) else { return .fail("No node at mark step's position") }
        let updated = node.mark(mark.addToSet(node.marks))
        return .fromReplace(doc, pos, pos + 1, Slice(content: Fragment.from(updated), openStart: 0, openEnd: node.isLeaf ? 0 : 1))
    }

    public func invert(_ doc: Node) -> Step {
        if let node = doc.nodeAt(pos) {
            let newSet = mark.addToSet(node.marks)
            if newSet.count == node.marks.count {
                for m in node.marks where !m.isInSet(newSet) { return AddNodeMarkStep(pos, m) }
                return AddNodeMarkStep(pos, mark)
            }
        }
        return RemoveNodeMarkStep(pos, mark)
    }

    public func map(_ mapping: Mappable) -> Step? {
        let p = mapping.mapResult(pos, 1)
        return p.deletedAfter ? nil : AddNodeMarkStep(p.pos, mark)
    }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "addNodeMark", "pos": .int(pos), "mark": .object(mark.toJSON())]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> Step {
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
        let updated = node.mark(mark.removeFromSet(node.marks))
        return .fromReplace(doc, pos, pos + 1, Slice(content: Fragment.from(updated), openStart: 0, openEnd: node.isLeaf ? 0 : 1))
    }

    public func invert(_ doc: Node) -> Step {
        guard let node = doc.nodeAt(pos), mark.isInSet(node.marks) else { return self }
        return AddNodeMarkStep(pos, mark)
    }

    public func map(_ mapping: Mappable) -> Step? {
        let p = mapping.mapResult(pos, 1)
        return p.deletedAfter ? nil : RemoveNodeMarkStep(p.pos, mark)
    }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "removeNodeMark", "pos": .int(pos), "mark": .object(mark.toJSON())]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> Step {
        guard let pos = json["pos"]?.intValue, case let .object(markJSON)? = json["mark"] else {
            throw ModelError.invalidJSON("Invalid input for RemoveNodeMarkStep.fromJSON")
        }
        return RemoveNodeMarkStep(pos, try Mark.fromJSON(schema, markJSON))
    }
}
