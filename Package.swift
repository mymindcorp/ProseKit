// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ProseKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
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
        .library(name: "EditorChangeset", targets: ["EditorChangeset"]),
        .library(name: "EditorUIKit", targets: ["EditorUIKit"]),
        .library(name: "EditorSyntax", targets: ["EditorSyntax"]),
        .library(name: "EditorMath", targets: ["EditorMath"]),
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
            "EditorChangeset", "EditorSerialization",
        ]),
        // M6 — JSON / HTML / Markdown serialization.
        .target(name: "EditorSerialization", dependencies: ["DocumentModel"]),
        // M10 — collaborative editing (prosemirror-collab).
        .target(name: "EditorCollab", dependencies: ["EditorStateKit"]),
        .target(name: "EditorChangeset", dependencies: ["DocumentModel", "DocumentTransform"]),
        // M9 — the iOS (UIKit) renderer + editor host. Source is guarded by
        // `#if canImport(UIKit)` so the macOS build stays green.
        .target(name: "EditorUIKit", dependencies: [
            "SchemaKit", "EditorCommands", "EditorKeymap", "EditorStateKit", "DocumentModel", "DocumentTransform", "EditorSerialization",
        ]),
        // Optional, isolated syntax highlighter for the EditorUIKit code-block
        // hook (JavaScript + CSS, with content-based language detection).
        .target(name: "EditorSyntax", dependencies: ["EditorUIKit"]),
        // Optional LaTeX math typesetter for the EditorUIKit math hook. The
        // parser and box layout are CoreText-only (so they build and test on
        // macOS); only the thin renderer adapter is UIKit-gated.
        .target(name: "EditorMath", dependencies: ["EditorUIKit"]),

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
            // EditorMath so the MathML import can be checked against the very
            // parser that has to render its output.
            dependencies: ["SchemaKit", "EditorHistory", "EditorMath", "TestHarness"],
            path: "Tests/SchemaKitTests",
            resources: [.copy("highlight-doc.json")]),
        .executableTarget(
            name: "EditorSerializationTests",
            dependencies: ["EditorSerialization", "TestHarness"],
            path: "Tests/EditorSerializationTests"),
        .executableTarget(
            name: "EditorCollabTests",
            dependencies: ["EditorCollab", "EditorHistory", "TestHarness"],
            path: "Tests/EditorCollabTests"),
        .executableTarget(
            name: "EditorChangesetTests",
            dependencies: ["EditorChangeset", "TestHarness"],
            path: "Tests/EditorChangesetTests"),
        .executableTarget(
            name: "EditorMathTests",
            dependencies: ["EditorMath", "TestHarness"],
            path: "Tests/EditorMathTests"),
        // iOS-only XCTest target for the renderer (run via xcodebuild on a
        // simulator). Source is #if canImport(UIKit) so it's empty on macOS.
        .testTarget(
            name: "EditorUIKitTests",
            dependencies: ["EditorUIKit", "SchemaKit", "EditorSyntax", "EditorMath"],
            path: "Tests/EditorUIKitTests"),
    ]
)

// Package-wide Swift settings.
//
// Every upcoming feature this toolchain knows about is on unconditionally. They
// only constrain *our* source — each one is a Swift 7 default we adopt early
// (SE-0335 `any`, SE-0409 internal imports, SE-0444 member import visibility,
// SE-0449/0461 isolation, immutable weak captures) — so none of them can conflict
// with how a consumer builds the package. The language mode is Swift 6 (implied
// by the tools version), which already brings complete strict concurrency.
//
// `strictMemorySafety` is likewise unconditional: every unsafe construct in the
// package is explicitly spelled `unsafe`, so it emits no diagnostics on its own.
//
// Warnings-as-errors is the one exception. It is a policy for *developing*
// ProseKit, not something to impose on consumers: it emits `-warnings-as-errors`,
// and when ProseKit is built as an Xcode SPM dependency Xcode injects
// `-suppress-warnings` for package code — swiftc refuses both at once
// ("Conflicting options '-warnings-as-errors' and '-suppress-warnings'"). So it's
// gated behind PROSEKIT_STRICT, which our CI and release script set; consumer
// builds (no env var) get a normal, conflict-free compile.
var packageSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .strictMemorySafety(),
]
if Context.environment["PROSEKIT_STRICT"] != nil {
    packageSwiftSettings.append(.treatAllWarnings(as: .error))
}
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + packageSwiftSettings
}
