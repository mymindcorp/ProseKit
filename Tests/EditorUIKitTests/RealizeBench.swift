#if canImport(UIKit) && PROSEKIT_BENCH
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// What `DocumentLayout.realize(window:)` costs, since `draw(_:)` calls it via
/// `realizeForPaint`. Compiled out by default so the suite stays quiet — a
/// compilation condition rather than an environment check, because xcodebuild's
/// `TEST_RUNNER_` prefix does not reach an SPM scheme's test runner:
///
///     xcodebuild test -scheme ProseKit-Package -configuration Release \
///       -destination 'platform=iOS Simulator,name=iPhone 17' \
///       -only-testing:EditorUIKitTests/RealizeBench \
///       ENABLE_TESTABILITY=YES SWIFT_OPTIMIZATION_LEVEL=-O \
///       SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PROSEKIT_BENCH'
///
/// Release matters: debug numbers are dominated by unspecialized generics.
///
/// Measured at a phone column (362 pt) with an 800 pt viewport, the shape of the
/// notes that showed the bug.
@MainActor
final class RealizeBench: XCTestCase {
    private static let width: CGFloat = 362
    private static let viewport: CGFloat = 800

    private func bigDoc(_ n: Int) -> Node {
        let s = try! Editor(extensions: fullKit()).schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let paras = (0 ..< n).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        return try! s.node("doc", [:], content: Fragment.from(paras))
    }

    private func lazyLayout(_ doc: Node) -> DocumentLayout {
        DocumentLayout(doc: doc, width: Self.width, theme: DocumentTheme(),
                       realizeWindow: 0 ... Self.viewport)
    }

    /// Best-of-`runs` wall time for `body`, printed in ms.
    private func time(_ label: String, runs: Int = 5, _ body: () -> Void) {
        var best = Double.infinity
        for _ in 0 ..< runs {
            let start = Date()
            body()
            best = min(best, Date().timeIntervalSince(start))
        }
        unsafe print(String(format: "  %-54@ %9.3f ms", label as NSString, best * 1000))
        unsafe fflush(stdout)
    }

    /// Best-of-`runs` mean cost of one `realize` on a *fresh* lazy layout, so
    /// the construction is not timed.
    private func timeFreshRealize(_ label: String, doc: Node, window: (CGFloat) -> ClosedRange<CGFloat>,
                                  at offset: CGFloat, runs: Int = 5) {
        var best = Double.infinity
        var didWork = false
        for _ in 0 ..< runs {
            let l = lazyLayout(doc)
            let w = window(offset)
            let start = Date()
            let changed = l.realize(window: w)
            let dt = Date().timeIntervalSince(start)
            didWork = didWork || changed
            best = min(best, dt)
        }
        unsafe print(String(format: "  %-54@ %9.3f ms  (realized: %@)",
                     label as NSString, best * 1000, didWork ? "yes" : "NO-OP"))
        unsafe fflush(stdout)
    }

    func testRealizeCost() {
        let vp = Self.viewport
        let narrow: (CGFloat) -> ClosedRange<CGFloat> = { o in o ... (o + vp) }
        // What realizeWindow() actually asks for: offset ± max(height*2, 600).
        let wide: (CGFloat) -> ClosedRange<CGFloat> = { o in
            let margin = max(vp * 2, 600)
            return (o - margin) ... (o + vp + margin)
        }

        for n in [60, 249, 500] {
            let doc = bigDoc(n)
            let probe = lazyLayout(doc)
            let height = probe.height
            unsafe print("\n  --- \(n) blocks, \(Int(height)) pt tall, \(Int(Self.width)) pt column ---")
            unsafe fflush(stdout)

            // 1. Steady state while scrolling inside already-realized content.
            //    This is what the paint path pays on EVERY frame that needs
            //    nothing new. Layout still has estimated entries elsewhere.
            let stillLazy = lazyLayout(doc)
            time("realize(window:) no-op, doc still partly estimated x1000") {
                for _ in 0 ..< 1000 { _ = stillLazy.realize(window: 0 ... vp) }
            }
            time("hasEstimatedContent x1000") {
                for _ in 0 ..< 1000 { _ = stillLazy.hasEstimatedContent }
            }

            // 2. Same, once the whole document has been realized — the guard
            //    at the top of realize() short-circuits.
            let fully = lazyLayout(doc)
            _ = fully.realize(window: 0 ... .greatestFiniteMagnitude)
            time("realize(window:) no-op, doc fully realized x1000") {
                for _ in 0 ..< 1000 { _ = fully.realize(window: 0 ... vp) }
            }

            // 3. One realize that actually typesets, far down the document.
            let far = max(height - vp * 2, vp)
            timeFreshRealize("realize 1 viewport (paint path) at \(Int(far)) pt",
                             doc: doc, window: narrow, at: far)
            timeFreshRealize("realize 5 viewports (realizeWindow) at \(Int(far)) pt",
                             doc: doc, window: wide, at: far)

            // 4. Scrolling the whole document through, a viewport at a time.
            for (name, w) in [("1 viewport", narrow), ("5 viewports", wide)] {
                let l = lazyLayout(doc)
                var calls = 0, worked = 0
                let start = Date()
                var y: CGFloat = 0
                while y < l.height {
                    calls += 1
                    if l.realize(window: w(y)) { worked += 1 }
                    y += vp
                }
                let dt = Date().timeIntervalSince(start)
                unsafe print(String(format: "  %-54@ %9.3f ms  (%d calls, %d did work)",
                             "scroll whole doc, \(name) per step" as NSString, dt * 1000, calls, worked))
                unsafe fflush(stdout)
            }
        }
    }
}
#endif
