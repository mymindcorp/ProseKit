// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EditorSwift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "DocumentModel", targets: ["DocumentModel"]),
        .library(name: "DocumentTransform", targets: ["DocumentTransform"]),
        .library(name: "EditorStateKit", targets: ["EditorStateKit"]),
        .library(name: "EditorCommands", targets: ["EditorCommands"]),
        .library(name: "EditorHistory", targets: ["EditorHistory"]),
        .library(name: "EditorKeymap", targets: ["EditorKeymap"]),
        .library(name: "EditorInputRules", targets: ["EditorInputRules"]),
        .library(name: "SchemaKit", targets: ["SchemaKit"]),
        .library(name: "EditorSerialization", targets: ["EditorSerialization"]),
        .library(name: "EditorCollab", targets: ["EditorCollab"]),
        .library(name: "EditorUIKit", targets: ["EditorUIKit"]),
    ],
    targets: [
        // M0 — the document object model (prosemirror-model).
        .target(name: "DocumentModel"),
        // M1 — steps, mapping, and transforms (prosemirror-transform).
        .target(name: "DocumentTransform", dependencies: ["DocumentModel"]),
        // M2 — editor state, selection, transactions, plugins (prosemirror-state).
        .target(name: "EditorStateKit", dependencies: ["DocumentModel", "DocumentTransform"]),
        // M3 — commands, history, keymap, input rules.
        .target(name: "EditorCommands", dependencies: ["EditorStateKit"]),
        .target(name: "EditorHistory", dependencies: ["EditorStateKit"]),
        .target(name: "EditorKeymap", dependencies: ["EditorStateKit", "EditorCommands"]),
        .target(name: "EditorInputRules", dependencies: ["EditorStateKit"]),
        // M4 — the Tiptap-style extension layer + Editor facade.
        .target(name: "SchemaKit", dependencies: [
            "EditorStateKit", "EditorCommands", "EditorHistory", "EditorKeymap", "EditorInputRules",
        ]),
        // M6 — JSON / HTML / Markdown serialization.
        .target(name: "EditorSerialization", dependencies: ["DocumentModel"]),
        // M10 — collaborative editing (prosemirror-collab).
        .target(name: "EditorCollab", dependencies: ["EditorStateKit"]),
        // M9 — the iOS (UIKit) renderer + editor host. Source is guarded by
        // `#if canImport(UIKit)` so the macOS build stays green.
        .target(name: "EditorUIKit", dependencies: [
            "SchemaKit", "EditorCommands", "EditorKeymap", "EditorStateKit", "DocumentModel", "DocumentTransform", "EditorSerialization",
        ]),

        // Minimal test harness (no XCTest/swift-testing in this CLT-only env).
        .target(name: "TestHarness"),

        // Runnable test suites (invoke with `swift run <Target>`).
        .executableTarget(
            name: "DocumentModelTests",
            dependencies: ["DocumentModel", "TestHarness"],
            path: "Tests/DocumentModelTests"),
        .executableTarget(
            name: "DocumentTransformTests",
            dependencies: ["DocumentTransform", "TestHarness"],
            path: "Tests/DocumentTransformTests"),
        .executableTarget(
            name: "EditorStateKitTests",
            dependencies: ["EditorStateKit", "TestHarness"],
            path: "Tests/EditorStateKitTests"),
        .executableTarget(
            name: "EditorCommandsTests",
            dependencies: ["EditorCommands", "EditorHistory", "EditorKeymap", "EditorInputRules", "TestHarness"],
            path: "Tests/EditorCommandsTests"),
        .executableTarget(
            name: "SchemaKitTests",
            dependencies: ["SchemaKit", "TestHarness"],
            path: "Tests/SchemaKitTests"),
        .executableTarget(
            name: "EditorSerializationTests",
            dependencies: ["EditorSerialization", "TestHarness"],
            path: "Tests/EditorSerializationTests"),
        .executableTarget(
            name: "EditorCollabTests",
            dependencies: ["EditorCollab", "TestHarness"],
            path: "Tests/EditorCollabTests"),
        // iOS-only XCTest target for the renderer (run via xcodebuild on a
        // simulator). Source is #if canImport(UIKit) so it's empty on macOS.
        .testTarget(
            name: "EditorUIKitTests",
            dependencies: ["EditorUIKit", "SchemaKit"],
            path: "Tests/EditorUIKitTests"),
    ]
)
