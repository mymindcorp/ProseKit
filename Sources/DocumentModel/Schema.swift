import Foundation

// MARK: - Specs

/// Used to define the attributes a node or mark accepts.
public struct AttributeSpec: Sendable {
    /// The default value for this attribute. When `nil`, the attribute is
    /// required and must be provided when a node/mark of this type is created.
    public var defaultValue: AttributeValue?
    public var hasDefault: Bool

    public init(default value: AttributeValue) {
        self.defaultValue = value
        self.hasDefault = true
    }

    /// A required attribute (no default).
    public init() {
        self.defaultValue = nil
        self.hasDefault = false
    }
}

/// A description of a node type.
public struct NodeSpec: Sendable {
    public var content: String?
    public var marks: String?
    public var group: String?
    public var inline: Bool
    public var atom: Bool
    public var attrs: [String: AttributeSpec]
    public var selectable: Bool
    public var draggable: Bool
    public var code: Bool
    public var whitespace: Whitespace
    public var defining: Bool
    public var isolating: Bool
    /// Overrides whether a gap cursor is allowed inside this node (nil = the
    /// default content-based rule). Read by EditorStateKit's GapCursor.
    public var allowGapCursor: Bool?
    public var leafText: (@Sendable (Node) -> String)?

    public enum Whitespace: Sendable { case normal, pre }

    public init(
        content: String? = nil,
        marks: String? = nil,
        group: String? = nil,
        inline: Bool = false,
        atom: Bool = false,
        attrs: [String: AttributeSpec] = [:],
        selectable: Bool = true,
        draggable: Bool = false,
        code: Bool = false,
        whitespace: Whitespace = .normal,
        defining: Bool = false,
        isolating: Bool = false,
        allowGapCursor: Bool? = nil,
        leafText: (@Sendable (Node) -> String)? = nil
    ) {
        self.content = content
        self.marks = marks
        self.group = group
        self.inline = inline
        self.atom = atom
        self.attrs = attrs
        self.selectable = selectable
        self.draggable = draggable
        self.code = code
        self.whitespace = whitespace
        self.defining = defining
        self.isolating = isolating
        self.allowGapCursor = allowGapCursor
        self.leafText = leafText
    }
}

/// A description of a mark type.
public struct MarkSpec: Sendable {
    public var attrs: [String: AttributeSpec]
    public var inclusive: Bool
    public var excludes: String?
    public var group: String?
    public var spanning: Bool
    /// Marks the content of this mark as code, meaning input rules (and other
    /// smart text behavior) should not apply inside it.
    public var code: Bool

    public init(
        attrs: [String: AttributeSpec] = [:],
        inclusive: Bool = true,
        excludes: String? = nil,
        group: String? = nil,
        spanning: Bool = true,
        code: Bool = false
    ) {
        self.attrs = attrs
        self.inclusive = inclusive
        self.excludes = excludes
        self.group = group
        self.spanning = spanning
        self.code = code
    }
}

// MARK: - NodeType

public final class NodeType: @unchecked Sendable {
    public let name: String
    /// Back-reference to the owning schema. Set during `Schema.init` right
    /// after the type is constructed; never `nil` once the schema exists.
    public unowned(unsafe) var schema: Schema!
    public let spec: NodeSpec
    public let groups: [String]
    public let attrs: [String: AttributeSpec]
    /// Index of this type in the schema's node definition order. Group content
    /// expressions resolve members in this order (matching ProseMirror), which
    /// matters for fill/wrap defaults — e.g. ensuring `paragraph` is preferred
    /// over `blockquote` when filling `block+`.
    public internal(set) var schemaOrder: Int = 0

    /// The default attribute values, or `nil` when there are required attrs.
    public private(set) var defaultAttrs: Attrs = [:]
    public private(set) var hasRequiredAttrs: Bool = false

    /// The starting match of the node type's content expression.
    public internal(set) var contentMatch: ContentMatch = .empty
    /// The set of marks allowed in this node. `nil` means all marks allowed.
    public internal(set) var markSet: [MarkType]? = nil

    public let isBlock: Bool
    public let isText: Bool

    init(name: String, spec: NodeSpec) {
        self.name = name
        self.spec = spec
        self.groups = spec.group?.split(separator: " ").map(String.init) ?? []
        self.attrs = spec.attrs
        self.isBlock = !(spec.inline || name == "text")
        self.isText = name == "text"
        computeDefaults()
    }

    private func computeDefaults() {
        var defaults: Attrs = [:]
        var required = false
        for (name, spec) in attrs {
            if let d = spec.defaultValue {
                defaults[name] = d
            } else {
                required = true
            }
        }
        self.defaultAttrs = defaults
        self.hasRequiredAttrs = required
    }

    public var isInline: Bool { !isBlock }
    public var isTextblock: Bool { isBlock && contentMatch.inlineContent }
    public var inlineContent: Bool { contentMatch.inlineContent }
    public var isLeaf: Bool { contentMatch === ContentMatch.empty }
    public var isAtom: Bool { isLeaf || spec.atom }
    public var whitespace: NodeSpec.Whitespace { spec.whitespace }

    public func compute(attrs given: Attrs) throws(ModelError) -> Attrs {
        try Schema.computeAttrs(self.attrs, given, what: "node '\(name)'")
    }

    public func create(_ attrs: Attrs = [:], content: Fragment = .empty, marks: [Mark] = []) throws(ModelError) -> Node {
        if hasRequiredAttrs || !attrs.isEmpty {
            let computed = try compute(attrs: attrs)
            return Node(type: self, attrs: computed, content: content, marks: Mark.setFrom(marks))
        }
        return Node(type: self, attrs: defaultAttrs, content: content, marks: Mark.setFrom(marks))
    }

    public func create(_ attrs: Attrs = [:], content: Node, marks: [Mark] = []) throws(ModelError) -> Node {
        try create(attrs, content: Fragment.from(content), marks: marks)
    }

    /// Like `create`, but check that the content matches the type's content
    /// expression, and throw if it does not.
    public func createChecked(_ attrs: Attrs = [:], content: Fragment = .empty, marks: [Mark] = []) throws(ModelError) -> Node {
        if contentMatch.matchFragment(content)?.validEnd != true {
            throw ModelError.invalidContent("Invalid content for node \(name)")
        }
        return try create(attrs, content: content, marks: marks)
    }

    /// Create a node, and try to fill it in so that its content matches the
    /// content expression. Returns `nil` if no valid fill exists.
    public func createAndFill(_ attrs: Attrs = [:], content: Fragment = .empty, marks: [Mark] = []) -> Node? {
        guard let computedAttrs = try? compute(attrs: attrs) else { return nil }
        var content = content
        let matched = contentMatch.matchFragment(content)
        guard let after = matched?.fillBefore(.empty, toEnd: true) else { return nil }
        guard let before = contentMatch.fillBefore(content, toEnd: false) else { return nil }
        content = before.append(content).append(after)
        return Node(type: self, attrs: computedAttrs, content: content, marks: Mark.setFrom(marks))
    }

    public func validContent(_ content: Fragment) -> Bool {
        guard let result = contentMatch.matchFragment(content), result.validEnd else { return false }
        for i in 0..<content.childCount {
            if !allowsMarks(content.child(i).marks) { return false }
        }
        return true
    }

    public func checkContent(_ content: Fragment) throws(ModelError) {
        if !validContent(content) {
            throw ModelError.invalidContent("Invalid content for node \(name): \(content)")
        }
    }

    public func checkAttrs(_ attrs: Attrs) throws(ModelError) {
        _ = try Schema.computeAttrs(self.attrs, attrs, what: "node '\(name)'")
    }

    /// Check whether the given node type's content can be appended after this
    /// type's content (used when joining nodes).
    public func compatibleContent(_ other: NodeType) -> Bool {
        self === other || contentMatch.compatible(other.contentMatch)
    }

    public func allowsMarkType(_ markType: MarkType) -> Bool {
        guard let markSet else { return true }
        return markSet.contains { $0 === markType }
    }

    public func allowsMarks(_ marks: [Mark]) -> Bool {
        if markSet == nil { return true }
        for mark in marks where !allowsMarkType(mark.type) { return false }
        return true
    }

    /// Removes the marks that are not allowed in this node from the given set.
    public func allowedMarks(_ marks: [Mark]) -> [Mark] {
        if markSet == nil { return marks }
        return marks.filter { allowsMarkType($0.type) }
    }

    func isInGroup(_ name: String) -> Bool { groups.contains(name) }
}

// MARK: - MarkType

public final class MarkType: @unchecked Sendable {
    public let name: String
    public let rank: Int
    public unowned(unsafe) var schema: Schema!
    public let spec: MarkSpec
    public let attrs: [String: AttributeSpec]

    public private(set) var defaultAttrs: Attrs = [:]
    public private(set) var hasRequiredAttrs: Bool = false
    /// The marks this type excludes (set during schema compilation). `nil`
    /// before computed; when the spec excludes "" it excludes all marks.
    var excluded: [MarkType] = []

    init(name: String, rank: Int, spec: MarkSpec) {
        self.name = name
        self.rank = rank
        self.spec = spec
        self.attrs = spec.attrs
        for (n, s) in attrs {
            if let d = s.defaultValue { defaultAttrs[n] = d } else { hasRequiredAttrs = true }
        }
    }

    public func create(_ attrs: Attrs = [:]) -> Mark {
        if attrs.isEmpty && !hasRequiredAttrs {
            return Mark(type: self, attrs: defaultAttrs)
        }
        let computed = (try? Schema.computeAttrs(self.attrs, attrs, what: "mark '\(name)'")) ?? defaultAttrs
        return Mark(type: self, attrs: computed)
    }

    public func checkAttrs(_ attrs: Attrs) throws(ModelError) {
        _ = try Schema.computeAttrs(self.attrs, attrs, what: "mark '\(name)'")
    }

    /// When there is a mark of this type in the given set, return it.
    public func isInSet(_ set: [Mark]) -> Mark? {
        set.first { $0.type === self }
    }

    /// Queries whether a given mark type is excluded by this one.
    public func excludes(_ other: MarkType) -> Bool {
        excluded.contains { $0 === other }
    }
}

// MARK: - Schema

public final class Schema: @unchecked Sendable {
    public let nodes: [String: NodeType]
    public let marks: [String: MarkType]
    public let topNodeType: NodeType
    /// Cached schema spec for serialization / introspection.
    public let nodeSpecOrder: [String]
    public let markSpecOrder: [String]

    public init(nodes: [(String, NodeSpec)], marks: [(String, MarkSpec)] = [], topNode: String = "doc") throws(ModelError) {
        var nodeTypes: [String: NodeType] = [:]
        var nodeOrder: [String] = []
        // First pass: create node and mark types (schema back-reference set below).
        for (name, spec) in nodes {
            let type = NodeType(name: name, spec: spec)
            type.schemaOrder = nodeOrder.count
            nodeTypes[name] = type
            nodeOrder.append(name)
        }
        var markTypes: [String: MarkType] = [:]
        var markOrder: [String] = []
        for (i, pair) in marks.enumerated() {
            let type = MarkType(name: pair.0, rank: i, spec: pair.1)
            markTypes[pair.0] = type
            markOrder.append(pair.0)
        }

        guard let top = nodeTypes[topNode] else {
            throw ModelError.schemaError("The top node type '\(topNode)' is not in the schema")
        }
        self.nodes = nodeTypes
        self.marks = markTypes
        self.topNodeType = top
        self.nodeSpecOrder = nodeOrder
        self.markSpecOrder = markOrder
        for type in nodeTypes.values { type.schema = self }
        for type in markTypes.values { type.schema = self }

        // Second pass: compile content expressions and mark sets.
        for (name, type) in nodeTypes {
            let contentExpr = type.spec.content ?? ""
            type.contentMatch = try ContentExpression.parse(contentExpr, nodeTypes)
            // Mark set.
            let marksExpr = type.spec.marks
            if let marksExpr {
                if marksExpr == "_" {
                    type.markSet = nil // all marks
                } else if marksExpr.isEmpty {
                    type.markSet = []
                } else {
                    type.markSet = try Schema.gatherMarks(marksExpr, markTypes)
                }
            } else {
                // Default: block nodes that allow inline content allow all marks;
                // others allow none.
                type.markSet = type.inlineContent ? nil : []
            }
            _ = name
        }
        // Compute mark exclusions.
        for (_, mark) in markTypes {
            let excludesSpec = mark.spec.excludes
            if let excludesSpec {
                if excludesSpec.isEmpty {
                    mark.excluded = []
                } else if excludesSpec == "_" {
                    mark.excluded = Array(markTypes.values)
                } else {
                    mark.excluded = try Schema.gatherMarks(excludesSpec, markTypes)
                }
            } else {
                // Default: a mark excludes itself.
                mark.excluded = [mark]
            }
        }
    }

    public func nodeType(_ name: String) throws(ModelError) -> NodeType {
        guard let t = nodes[name] else {
            throw ModelError.rangeError("Unknown node type: \(name)")
        }
        return t
    }

    public func node(_ type: String, _ attrs: Attrs = [:], content: Fragment = .empty, marks: [Mark] = []) throws(ModelError) -> Node {
        try nodeType(type).create(attrs, content: content, marks: marks)
    }

    public func node(_ type: NodeType, _ attrs: Attrs = [:], content: Fragment = .empty, marks: [Mark] = []) throws(ModelError) -> Node {
        try type.create(attrs, content: content, marks: marks)
    }

    /// Create a text node. Empty text is not allowed.
    public func text(_ text: String, _ marks: [Mark] = []) -> Node {
        let type = nodes["text"]!
        return Node(type: type, attrs: type.defaultAttrs, content: .empty, marks: Mark.setFrom(marks), text: text)
    }

    public func mark(_ name: String, _ attrs: Attrs = [:]) -> Mark {
        marks[name]!.create(attrs)
    }

    public func mark(_ type: MarkType, _ attrs: Attrs = [:]) -> Mark {
        type.create(attrs)
    }

    public func nodeFromJSON(_ json: [String: AttributeValue]) throws(ModelError) -> Node {
        try Node.fromJSON(self, json)
    }

    public func markFromJSON(_ json: [String: AttributeValue]) throws(ModelError) -> Mark {
        try Mark.fromJSON(self, json)
    }

    // MARK: helpers

    static func gatherMarks(_ expr: String, _ markTypes: [String: MarkType]) throws(ModelError) -> [MarkType] {
        var found: [MarkType] = []
        for name in expr.split(separator: " ").map(String.init) {
            if let t = markTypes[name] {
                found.append(t)
            } else {
                // group
                let group = markTypes.values.filter { $0.spec.group?.split(separator: " ").map(String.init).contains(name) == true }
                if group.isEmpty {
                    throw ModelError.schemaError("Unknown mark type or group: \(name)")
                }
                found.append(contentsOf: group)
            }
        }
        return found.sorted { $0.rank < $1.rank }
    }

    static func computeAttrs(_ specs: [String: AttributeSpec], _ given: Attrs, what: String) throws(ModelError) -> Attrs {
        var result: Attrs = [:]
        for (name, spec) in specs {
            if let value = given[name] {
                result[name] = value
            } else if let d = spec.defaultValue {
                result[name] = d
            } else {
                throw ModelError.rangeError("No value supplied for required attribute '\(name)' in \(what)")
            }
        }
        return result
    }
}
