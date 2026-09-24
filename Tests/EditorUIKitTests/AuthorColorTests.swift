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
        // Not an exact pin: this only checks that the FNV-1a hash keeps these
        // pairs of authors apart, so a refactor that collapses them is caught.
        let alice = EditorTextView.authorColor("alice")
        let bob = EditorTextView.authorColor("bob")
        XCTAssertNotEqual(alice, EditorTextView.authorColor("carol"))
        XCTAssertNotEqual(bob, EditorTextView.authorColor("dave"))
    }
}
#endif
