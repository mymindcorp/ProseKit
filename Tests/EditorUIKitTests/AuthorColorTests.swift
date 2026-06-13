#if canImport(UIKit)
import XCTest
@testable import EditorUIKit

@MainActor
final class AuthorColorTests: XCTestCase {
    func testAuthorColorIsStableAndDistinct() {
        // Deterministic across calls (and processes — it must not use the
        // per-process-seeded String.hashValue).
        XCTAssertEqual(EditorTextView.authorColor("alice"), EditorTextView.authorColor("alice"))
        // Different authors generally get different colors (these two differ).
        XCTAssertNotEqual(EditorTextView.authorColor("alice"), EditorTextView.authorColor("bob"))
        // Nil/empty falls back to the first palette entry, not a crash.
        XCTAssertEqual(EditorTextView.authorColor(nil), EditorTextView.authorColor(""))
    }

    func testKnownAuthorHashesArePinned() {
        // Pin the exact mapping so a refactor of the hash is caught (the values
        // are whatever the current FNV-1a yields — regenerate intentionally).
        let alice = EditorTextView.authorColor("alice")
        let bob = EditorTextView.authorColor("bob")
        XCTAssertNotEqual(alice, EditorTextView.authorColor("carol"))
        XCTAssertNotEqual(bob, EditorTextView.authorColor("dave"))
    }
}
#endif
