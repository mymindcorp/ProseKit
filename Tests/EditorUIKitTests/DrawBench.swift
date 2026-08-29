#if canImport(UIKit) && PROSEKIT_BENCH
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// What `DocumentLayout.draw(in:clipY:)` costs per frame — the other half of the
/// paint path `RealizeBench` measures. Compiled out by default; same invocation:
///
///     xcodebuild test -scheme ProseKit-Package -configuration Release \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:EditorUIKitTests/DrawBench \
///       ENABLE_TESTABILITY=YES SWIFT_OPTIMIZATION_LEVEL=-O \
///       SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PROSEKIT_BENCH'
///
/// Release matters: debug numbers are dominated by unspecialized generics.
@MainActor
final class DrawBench: XCTestCase {
    private static let width: CGFloat = 362
    private static let viewport: CGFloat = 800

    private func schema() -> Schema { try! Editor(extensions: fullKit()).schema }

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

    private func withBitmapContext(_ body: (CGContext) -> Void) {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: Self.width, height: Self.viewport), true, 2)
        defer { UIGraphicsEndImageContext() }
        body(UIGraphicsGetCurrentContext()!)
    }

    /// One frame of the paint path: what `render(into:)` does after realize.
    private func drawFrame(_ layout: DocumentLayout, in ctx: CGContext, offsetY: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -offsetY)
        layout.draw(in: ctx, clipY: offsetY ... (offsetY + Self.viewport))
        ctx.restoreGState()
    }

    /// A fully-realized many-paragraph document — the state after a reader has
    /// scrolled through it once. Every frame's draw then walks every realized
    /// block and decoration to cull them.
    func testDrawScrolledLongDocument() {
        let s = schema()
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        for n in [60, 500, 2000] {
            let paras = (0 ..< n).map { i in
                try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
            }
            let doc = try! s.node("doc", [:], content: Fragment.from(paras))
            let layout = DocumentLayout(doc: doc, width: Self.width, theme: DocumentTheme(),
                                        realizeWindow: 0 ... Self.viewport)
            _ = layout.realize(window: 0 ... .greatestFiniteMagnitude)
            let mid = max((layout.height - Self.viewport) / 2, 0)
            print("\n  --- \(n) paragraphs, \(Int(layout.height)) pt tall, fully realized ---")
            unsafe fflush(stdout)
            withBitmapContext { ctx in
                time("draw one viewport mid-document x10") {
                    for _ in 0 ..< 10 { drawFrame(layout, in: ctx, offsetY: mid) }
                }
            }
        }
    }

    /// One giant code block, mostly off screen. A visible block draws all of its
    /// lines — there is no per-line clip — so this measures what scrolling
    /// through a long code block pays per frame.
    func testDrawTallCodeBlock() {
        let s = schema()
        for lines in [200, 2000] {
            let text = (0 ..< lines).map { "let value\($0) = compute(\($0)) // a line of code" }
                .joined(separator: "\n")
            let code = try! s.node("codeBlock", [:], content: Fragment.from([s.text(text)]))
            let doc = try! s.node("doc", [:], content: Fragment.from([code]))
            let layout = DocumentLayout(doc: doc, width: Self.width, theme: DocumentTheme())
            print("\n  --- codeBlock of \(lines) lines, \(Int(layout.height)) pt tall ---")
            unsafe fflush(stdout)
            withBitmapContext { ctx in
                time("draw one viewport at top x10") {
                    for _ in 0 ..< 10 { drawFrame(layout, in: ctx, offsetY: 0) }
                }
            }
        }
    }

    /// Many short paragraphs each carrying a highlight mark: the flat highlight
    /// list is walked per frame (band-rejected on position), and each in-band
    /// mark pays selectionRects. Sanity-checks that the band rejection holds.
    func testDrawWithManyHighlights() {
        let s = schema()
        let n = 1000
        let paras = (0 ..< n).map { i -> Node in
            let marked = s.text("highlighted \(i)", [s.mark("highlight", ["color": .string("yellow")])])
            return try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i) "), marked]))
        }
        let doc = try! s.node("doc", [:], content: Fragment.from(paras))
        let layout = DocumentLayout(doc: doc, width: Self.width, theme: DocumentTheme(),
                                    realizeWindow: 0 ... Self.viewport)
        _ = layout.realize(window: 0 ... .greatestFiniteMagnitude)
        let mid = max((layout.height - Self.viewport) / 2, 0)
        print("\n  --- \(n) highlighted paragraphs, \(Int(layout.height)) pt tall ---")
        unsafe fflush(stdout)
        withBitmapContext { ctx in
            time("draw one viewport mid-document x10") {
                for _ in 0 ..< 10 { drawFrame(layout, in: ctx, offsetY: mid) }
            }
        }
    }
}
#endif
