import Foundation

/// A mark is a piece of information that can be attached to a node, such as it
/// being emphasized, in code font, or a link. It has a type and optionally a
/// set of attributes that provide further information (such as the target of a
/// link).
///
/// Marks are value types; a marked-up document is described by attaching sets
/// of marks (`[Mark]`, kept sorted by `type.rank`) to inline nodes.
public struct Mark: Hashable, Sendable {
    /// The type of this mark.
    public let type: MarkType
    /// The attributes associated with this mark.
    public let attrs: Attrs

    public init(type: MarkType, attrs: Attrs = [:]) {
        self.type = type
        self.attrs = attrs
    }

    public static func == (lhs: Mark, rhs: Mark) -> Bool {
        lhs.type === rhs.type && lhs.attrs == rhs.attrs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(type))
        hasher.combine(attrs)
    }

    /// Given a set of marks, create a new set which contains this one as well,
    /// in the right position. If this mark is already in the set, the set is
    /// returned unchanged. If any marks that are set to be exclusive with this
    /// mark are present, those are replaced by this one.
    public func addToSet(_ set: [Mark]) -> [Mark] {
        var copy: [Mark] = []
        var placed = false
        for (i, other) in set.enumerated() {
            if self == other { return set }
            if type.excludes(other.type) {
                // Drop `other`.
                continue
            } else if other.type.excludes(type) {
                // `other` excludes us; leave the set untouched.
                return set
            } else {
                if !placed && other.type.rank > type.rank {
                    copy.append(self)
                    placed = true
                }
                copy.append(other)
            }
            _ = i
        }
        if !placed { copy.append(self) }
        return copy
    }

    /// Remove this mark from the given set, returning a new set.
    public func removeFromSet(_ set: [Mark]) -> [Mark] {
        set.filter { $0 != self }
    }

    /// Test whether this mark is in the given set of marks.
    public func isInSet(_ set: [Mark]) -> Bool {
        set.contains(self)
    }

    /// Test whether this mark has the same type and attributes as another.
    public func eq(_ other: Mark) -> Bool { self == other }

    /// JSON serialization (ProseMirror shape).
    public func toJSON() -> [String: AttributeValue] {
        var obj: [String: AttributeValue] = ["type": .string(type.name)]
        if !attrs.isEmpty { obj["attrs"] = .object(attrs) }
        return obj
    }

    public static func fromJSON(_ schema: Schema, _ json: [String: AttributeValue]) throws -> Mark {
        guard let name = json["type"]?.stringValue else {
            throw ModelError.invalidJSON("Invalid mark JSON: missing type")
        }
        guard let type = schema.marks[name] else {
            throw ModelError.rangeError("There is no mark type \(name) in this schema")
        }
        var attrs: Attrs = [:]
        if case let .object(o)? = json["attrs"] { attrs = o }
        return type.create(attrs)
    }
}

public extension Mark {
    /// Test whether two sets of marks are identical.
    static func sameSet(_ a: [Mark], _ b: [Mark]) -> Bool {
        a == b
    }

    /// Create a properly sorted mark set from null, a single mark, or an
    /// unsorted array of marks.
    static func setFrom(_ marks: [Mark]?) -> [Mark] {
        guard let marks, !marks.isEmpty else { return [] }
        let sorted = marks.sorted { $0.type.rank < $1.type.rank }
        return sorted
    }

    /// The empty mark set.
    static let none: [Mark] = []
}

public enum ModelError: Error, CustomStringConvertible {
    case rangeError(String)
    case invalidJSON(String)
    case invalidContent(String)
    case schemaError(String)

    public var description: String {
        switch self {
        case let .rangeError(m): return "RangeError: \(m)"
        case let .invalidJSON(m): return "InvalidJSON: \(m)"
        case let .invalidContent(m): return "InvalidContent: \(m)"
        case let .schemaError(m): return "SchemaError: \(m)"
        }
    }
}
