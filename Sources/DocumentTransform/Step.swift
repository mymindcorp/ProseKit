import Foundation
import Synchronization
import DocumentModel

/// The result of applying a step. Contains either a new document or a failure
/// message.
public struct StepResult {
    /// The transformed document, if successful.
    public let doc: Node?
    /// The failure message, if unsuccessful.
    public let failed: String?

    public static func ok(_ doc: Node) -> StepResult { StepResult(doc: doc, failed: nil) }
    public static func fail(_ message: String) -> StepResult { StepResult(doc: nil, failed: message) }

    /// Call `Node.replace`, turning any thrown error into a failed result.
    public static func fromReplace(_ doc: Node, _ from: Int, _ to: Int, _ slice: Slice) -> StepResult {
        do {
            return .ok(try doc.replace(from, to, slice))
        } catch {
            return .fail("\(error)")
        }
    }
}

/// A step object represents an atomic change. It generally applies only to the
/// document it was created for, since the positions stored in it will only make
/// sense for that document.
///
/// New steps are defined by conforming to this protocol and registering a
/// `jsonID` with `StepRegistry`.
public protocol Step: Sendable {
    /// Apply this step to the given document, returning a result.
    func apply(_ doc: Node) -> StepResult
    /// Get the step map that represents the changes made by this step.
    func getMap() -> StepMap
    /// Create an inverted version of this step (undoing it on `doc`).
    func invert(_ doc: Node) -> Step
    /// Map this step through a mappable, returning a new step whose positions
    /// have been adjusted, or `nil` if the step is entirely deleted.
    func map(_ mapping: Mappable) -> Step?
    /// Try to merge this step with another, producing a single combined step.
    func merge(_ other: Step) -> Step?
    /// Serialize to JSON.
    func toJSON() -> [String: AttributeValue]
    /// The identifier used in JSON serialization.
    var jsonID: String { get }
}

public extension Step {
    func getMap() -> StepMap { .empty }
    func merge(_ other: Step) -> Step? { nil }
}

/// Registry mapping JSON step IDs to decoders, used by `Step.fromJSON`.
public enum StepRegistry {
    public typealias StepDecoder = @Sendable (Schema, [String: AttributeValue]) throws -> Step

    private struct State {
        var decoders: [String: StepDecoder] = [:]
        var didBootstrap = false
    }
    private static let state = Mutex(State())

    public static func register(_ id: String, _ decoder: @escaping StepDecoder) {
        state.withLock { $0.decoders[id] = decoder }
    }

    public static func decoder(for id: String) -> StepDecoder? {
        state.withLock { state in
            bootstrap(&state)
            return state.decoders[id]
        }
    }

    /// Register the built-in step types. Idempotent; called while the lock is held.
    private static func bootstrap(_ state: inout State) {
        if state.didBootstrap { return }
        state.didBootstrap = true
        state.decoders["replace"] = { try ReplaceStep.fromJSON($0, $1) }
        state.decoders["replaceAround"] = { try ReplaceAroundStep.fromJSON($0, $1) }
        state.decoders["addMark"] = { try AddMarkStep.fromJSON($0, $1) }
        state.decoders["removeMark"] = { try RemoveMarkStep.fromJSON($0, $1) }
        state.decoders["addNodeMark"] = { try AddNodeMarkStep.fromJSON($0, $1) }
        state.decoders["removeNodeMark"] = { try RemoveNodeMarkStep.fromJSON($0, $1) }
        state.decoders["attr"] = { try AttrStep.fromJSON($0, $1) }
        state.decoders["docAttr"] = { try DocAttrStep.fromJSON($0, $1) }
    }
}

/// Decode a step from its JSON representation.
public func decodeStep(_ schema: Schema, _ json: [String: AttributeValue]) throws -> Step {
    guard let id = json["stepType"]?.stringValue else {
        throw ModelError.invalidJSON("Invalid Step: missing stepType")
    }
    guard let decoder = StepRegistry.decoder(for: id) else {
        throw ModelError.invalidJSON("No step type registered for '\(id)'")
    }
    return try decoder(schema, json)
}
