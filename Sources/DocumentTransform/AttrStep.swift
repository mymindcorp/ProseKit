import DocumentModel

/// Update an attribute on a node at a given position.
public struct AttrStep: Step {
    public let pos: Int
    public let attr: String
    public let value: AttributeValue

    public init(_ pos: Int, _ attr: String, _ value: AttributeValue) {
        self.pos = pos; self.attr = attr; self.value = value
    }

    public var jsonID: String { "attr" }

    public func apply(_ doc: Node) -> StepResult {
        guard let node = doc.nodeAt(pos) else { return .fail("No node at attribute step's position") }
        var attrs = node.attrs
        attrs[attr] = value
        guard let updated = try? node.type.create(attrs, content: .empty, marks: node.marks) else {
            return .fail("Cannot create node with updated attribute")
        }
        return .fromReplace(doc, pos, pos + 1, Slice(content: Fragment.from(updated), openStart: 0, openEnd: node.isLeaf ? 0 : 1))
    }

    public func getMap() -> StepMap { .empty }

    public func invert(_ doc: Node) -> Step {
        let old = doc.nodeAt(pos)?.attrs[attr] ?? .null
        return AttrStep(pos, attr, old)
    }

    public func map(_ mapping: Mappable) -> Step? {
        let p = mapping.mapResult(pos, 1)
        return p.deletedAfter ? nil : AttrStep(p.pos, attr, value)
    }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "attr", "pos": .int(pos), "attr": .string(attr), "value": value]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws -> Step {
        guard let pos = json["pos"]?.intValue, let attr = json["attr"]?.stringValue else {
            throw ModelError.invalidJSON("Invalid input for AttrStep.fromJSON")
        }
        return AttrStep(pos, attr, json["value"] ?? .null)
    }
}

/// Update an attribute on the top-level document node.
public struct DocAttrStep: Step {
    public let attr: String
    public let value: AttributeValue

    public init(_ attr: String, _ value: AttributeValue) { self.attr = attr; self.value = value }

    public var jsonID: String { "docAttr" }

    public func apply(_ doc: Node) -> StepResult {
        var attrs = doc.attrs
        attrs[attr] = value
        guard let updated = try? doc.type.create(attrs, content: doc.content, marks: doc.marks) else {
            return .fail("Cannot create document with updated attribute")
        }
        return .ok(updated)
    }

    public func getMap() -> StepMap { .empty }

    public func invert(_ doc: Node) -> Step {
        DocAttrStep(attr, doc.attrs[attr] ?? .null)
    }

    public func map(_ mapping: Mappable) -> Step? { self }

    public func toJSON() -> [String: AttributeValue] {
        ["stepType": "docAttr", "attr": .string(attr), "value": value]
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws -> Step {
        guard let attr = json["attr"]?.stringValue else {
            throw ModelError.invalidJSON("Invalid input for DocAttrStep.fromJSON")
        }
        return DocAttrStep(attr, json["value"] ?? .null)
    }
}
