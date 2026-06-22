import DocumentModel

/// Replace a part of the document with a slice of new content.
public struct ReplaceStep: Step {
    public let from: Int
    public let to: Int
    public let slice: Slice
    public let structure: Bool

    public init(_ from: Int, _ to: Int, _ slice: Slice, structure: Bool = false) {
        self.from = from
        self.to = to
        self.slice = slice
        self.structure = structure
    }

    public var jsonID: String { "replace" }

    public func apply(_ doc: Node) -> StepResult {
        if structure && contentBetween(doc, from, to) {
            return .fail("Structure replace would overwrite content")
        }
        return .fromReplace(doc, from, to, slice)
    }

    public func getMap() -> StepMap {
        StepMap([from, to - from, slice.size])
    }

    public func invert(_ doc: Node) -> any Step {
        ReplaceStep(from, from + slice.size, doc.slice(from, to))
    }

    public func map(_ mapping: any Mappable) -> (any Step)? {
        let from = mapping.mapResult(self.from, 1)
        let to = mapping.mapResult(self.to, -1)
        if from.deletedAcross && to.deletedAcross { return nil }
        // Preserve `structure` across mapping (prosemirror-transform 1.10.4):
        // a mapped structural step must stay structural, or it can later be
        // applied where it would overwrite content it was meant to guard.
        return ReplaceStep(from.pos, Swift.max(from.pos, to.pos), slice, structure: structure)
    }

    public func merge(_ other: any Step) -> (any Step)? {
        guard let other = other as? ReplaceStep, !other.structure, !structure else { return nil }
        if from + slice.size == other.from && slice.openEnd == 0 && other.slice.openStart == 0 {
            let newSlice = slice.size + other.slice.size == 0 ? Slice.empty
                : Slice(content: slice.content.append(other.slice.content), openStart: slice.openStart, openEnd: other.slice.openEnd)
            return ReplaceStep(from, to + (other.to - other.from), newSlice, structure: structure)
        } else if other.to == from && slice.openStart == 0 && other.slice.openEnd == 0 {
            let newSlice = slice.size + other.slice.size == 0 ? Slice.empty
                : Slice(content: other.slice.content.append(slice.content), openStart: other.slice.openStart, openEnd: slice.openEnd)
            return ReplaceStep(other.from, to, newSlice, structure: structure)
        }
        return nil
    }

    public func toJSON() -> [String: AttributeValue] {
        var json: [String: AttributeValue] = ["stepType": "replace", "from": .int(from), "to": .int(to)]
        if let s = slice.toJSON() { json["slice"] = .object(s) }
        if structure { json["structure"] = .bool(true) }
        return json
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> any Step {
        guard let from = json["from"]?.intValue, let to = json["to"]?.intValue else {
            throw ModelError.invalidJSON("Invalid input for ReplaceStep.fromJSON")
        }
        var sliceJSON: [String: AttributeValue]? = nil
        if case let .object(o)? = json["slice"] { sliceJSON = o }
        return ReplaceStep(from, to, try Slice.fromJSON(schema, sliceJSON),
                           structure: json["structure"]?.boolValue ?? false)
    }
}

/// Replace a part of the document with a slice of content, but preserve a range
/// of the replaced content by moving it into the slice. This is used to wrap or
/// unwrap content, or to change the type of a parent block.
public struct ReplaceAroundStep: Step {
    public let from: Int
    public let to: Int
    public let gapFrom: Int
    public let gapTo: Int
    public let slice: Slice
    public let insert: Int
    public let structure: Bool

    public init(_ from: Int, _ to: Int, _ gapFrom: Int, _ gapTo: Int, _ slice: Slice, _ insert: Int, structure: Bool = false) {
        self.from = from
        self.to = to
        self.gapFrom = gapFrom
        self.gapTo = gapTo
        self.slice = slice
        self.insert = insert
        self.structure = structure
    }

    public var jsonID: String { "replaceAround" }

    public func apply(_ doc: Node) -> StepResult {
        if structure && (contentBetween(doc, from, gapFrom) || contentBetween(doc, gapTo, to)) {
            return .fail("Structure gap-replace would overwrite content")
        }
        let gap = doc.slice(gapFrom, gapTo)
        if gap.openStart != 0 || gap.openEnd != 0 {
            return .fail("Gap is not a flat range")
        }
        guard let inserted = slice.insertAt(insert, gap.content) else {
            return .fail("Content does not fit in gap")
        }
        return .fromReplace(doc, from, to, inserted)
    }

    public func getMap() -> StepMap {
        StepMap([from, gapFrom - from, insert,
                 gapTo, to - gapTo, slice.size - insert])
    }

    public func invert(_ doc: Node) -> any Step {
        let gap = gapTo - gapFrom
        return ReplaceAroundStep(
            from, from + slice.size + gap,
            from + insert, from + insert + gap,
            doc.slice(from, to).removeBetween(gapFrom - from, gapTo - from),
            gapFrom - from, structure: structure)
    }

    public func map(_ mapping: any Mappable) -> (any Step)? {
        let from = mapping.mapResult(self.from, 1)
        let to = mapping.mapResult(self.to, -1)
        let gapFrom = self.from == self.gapFrom ? from.pos : mapping.map(self.gapFrom, -1)
        let gapTo = self.to == self.gapTo ? to.pos : mapping.map(self.gapTo, 1)
        if (from.deletedAcross && to.deletedAcross) || gapFrom < from.pos || gapTo > to.pos { return nil }
        return ReplaceAroundStep(from.pos, to.pos, gapFrom, gapTo, slice, insert, structure: structure)
    }

    public func toJSON() -> [String: AttributeValue] {
        var json: [String: AttributeValue] = [
            "stepType": "replaceAround", "from": .int(from), "to": .int(to),
            "gapFrom": .int(gapFrom), "gapTo": .int(gapTo), "insert": .int(insert),
        ]
        if let s = slice.toJSON() { json["slice"] = .object(s) }
        if structure { json["structure"] = .bool(true) }
        return json
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws(ModelError) -> any Step {
        guard let from = json["from"]?.intValue, let to = json["to"]?.intValue,
              let gapFrom = json["gapFrom"]?.intValue, let gapTo = json["gapTo"]?.intValue,
              let insert = json["insert"]?.intValue else {
            throw ModelError.invalidJSON("Invalid input for ReplaceAroundStep.fromJSON")
        }
        var sliceJSON: [String: AttributeValue]? = nil
        if case let .object(o)? = json["slice"] { sliceJSON = o }
        return ReplaceAroundStep(from, to, gapFrom, gapTo, try Slice.fromJSON(schema, sliceJSON), insert,
                                 structure: json["structure"]?.boolValue ?? false)
    }
}

/// Whether there is non-empty, non-leaf content between the two positions.
func contentBetween(_ doc: Node, _ from: Int, _ to: Int) -> Bool {
    let resolvedFrom = doc.resolve(from)
    var dist = to - from
    var depth = resolvedFrom.depth
    while dist > 0 && depth > 0 && resolvedFrom.indexAfter(depth) == resolvedFrom.node(depth).childCount {
        depth -= 1
        dist -= 1
    }
    if dist > 0 {
        var next = resolvedFrom.node(depth).maybeChild(resolvedFrom.indexAfter(depth))
        while dist > 0 {
            guard let n = next, !n.isLeaf else { return true }
            next = n.firstChild
            dist -= 1
        }
    }
    return false
}
