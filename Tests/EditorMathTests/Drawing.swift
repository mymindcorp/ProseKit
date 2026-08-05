import Foundation
import CoreGraphics
import CoreText
import EditorMath
import TestHarness

// `MathBox.draw` — the one part of the box that nothing exercised. Everything
// above it is arithmetic a test can read off; this is where the arithmetic
// finally meets a context, and a formula that lays out perfectly and draws
// nothing looks exactly like one that isn't there.
//
// So these render into a bitmap and count ink. Each of the four primitives has
// a formula that produces it: glyphs from any letter, a rule from a fraction
// bar, a path from a radical or a stretched delimiter.

/// A white bitmap context to draw into.
private func bitmap(_ size: Int = 120) -> CGContext? {
    let ctx = unsafe CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                               bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx?.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return ctx
}

/// Run a closure over the context's pixels as (r, g, b) triples.
private func eachPixel(_ ctx: CGContext, _ body: (Int, UInt8, UInt8, UInt8) -> Void) {
    guard let data = unsafe ctx.data else { return }
    let count = ctx.bytesPerRow * ctx.height
    let bytes = unsafe data.bindMemory(to: UInt8.self, capacity: count)
    for i in stride(from: 0, to: count, by: 4) {
        unsafe body(i / 4, bytes[i], bytes[i + 1], bytes[i + 2])
    }
}

/// How many pixels are no longer white.
private func inkPixels(_ ctx: CGContext) -> Int {
    var ink = 0
    eachPixel(ctx) { _, r, g, b in if r < 250 || g < 250 || b < 250 { ink += 1 } }
    return ink
}

/// Draw a formula into a fresh bitmap and count its ink.
private func inkFor(_ latex: String, display: Bool = true) throws -> Int {
    let box = typesetter().layout(latex, display: display).box
    guard let ctx = bitmap() else { try expect(false, "no context"); return 0 }
    // Origin low and left, with room above: box coordinates put +y up.
    box.draw(in: ctx, at: CGPoint(x: 8, y: 40), color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    return inkPixels(ctx)
}

/// Which primitives a formula's box contains.
private func kinds(_ latex: String) -> Set<String> {
    var found: Set<String> = []
    for item in typesetter().layout(latex, display: true).box.drawItems {
        switch item {
        case .glyphs: found.insert("glyphs")
        case .rule: found.insert("rule")
        case .strokedPath: found.insert("strokedPath")
        case .filledPath: found.insert("filledPath")
        }
    }
    return found
}

func registerMathDrawingTests() {
    test("MathBox.draw: glyphs put ink on the page") {
        let ink = try inkFor("x + y")
        try expect(ink > 0, "a formula of letters should draw something")
    }

    test("MathBox.draw: a fraction draws its bar") {
        // The rule primitive. A fraction whose bar is missing still lays out
        // with the right height, so only the drawing shows it.
        let found = kinds("\\frac{a}{b}")
        try expect(found.contains("rule"), "expected a rule, got \(found)")
        let fraction = try inkFor("\\frac{a}{b}"), plain = try inkFor("ab")
        try expect(fraction > plain, "the bar and the stacking should add ink")
    }

    test("MathBox.draw: a radical draws its sign") {
        let found = kinds("\\sqrt{x}")
        try expect(!found.isEmpty, "a radical should draw something, got \(found)")
        let radical = try inkFor("\\sqrt{x}"), bare = try inkFor("x")
        try expect(radical > bare, "the sign should add ink")
    }

    test("MathBox.draw: a stretched delimiter draws") {
        let bracketed = try inkFor("\\left(\\frac{a}{b}\\right)")
        let bare = try inkFor("\\frac{a}{b}")
        try expect(bracketed > bare, "the brackets should add ink of their own")
    }

    test("MathBox.draw: an empty box draws nothing") {
        guard let ctx = bitmap() else { try expect(false, "no context"); return }
        typesetter().layout("", display: true).box
            .draw(in: ctx, at: CGPoint(x: 8, y: 40),
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        try expectEqual(inkPixels(ctx), 0, "nothing to draw, so nothing drawn")
    }

    test("MathBox.draw: the colour asked for is the colour used") {
        let box = typesetter().layout("x", display: true).box
        guard let ctx = bitmap() else { try expect(false, "no context"); return }
        box.draw(in: ctx, at: CGPoint(x: 8, y: 40),
                 color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        var red = 0
        eachPixel(ctx) { _, r, g, b in if r > 200, g < 100, b < 100 { red += 1 } }
        try expect(red > 0, "expected red pixels, found none")
    }

    test("MathBox.draw: the origin moves the ink") {
        // The same box at two origins must ink different pixels — otherwise the
        // translate is being ignored and every formula lands in one place.
        let box = typesetter().layout("x", display: true).box
        func leftmostInkedColumn(_ x: CGFloat) throws -> Int {
            guard let ctx = bitmap() else { return -1 }
            box.draw(in: ctx, at: CGPoint(x: x, y: 40),
                     color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            var leftmost = ctx.width
            let width = ctx.width
            eachPixel(ctx) { index, r, _, _ in
                if r < 250 { leftmost = min(leftmost, index % width) }
            }
            return leftmost
        }
        let near = try leftmostInkedColumn(8), far = try leftmostInkedColumn(48)
        try expect(near < far, "further right should ink further right: \(near) vs \(far)")
    }

    test("MathBox.draw: the context is handed back as it was given") {
        // `draw` flips into box space to work — +y up — and has to undo that,
        // or everything drawn after a formula comes out upside down. Comparing
        // the transform says so exactly; comparing pixels wouldn't, since
        // drawing twice darkens antialiased edges rather than repeating them.
        let box = typesetter().layout("\\frac{a}{b}", display: true).box
        guard let ctx = bitmap() else { try expect(false, "no context"); return }
        let before = ctx.ctm
        box.draw(in: ctx, at: CGPoint(x: 8, y: 40),
                 color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let after = ctx.ctm
        try expect(before == after, "the transform was left changed: \(before) then \(after)")
    }

    test("MathBox.draw: a second pass lands on the first") {
        // Same box, same origin, twice: the ink has to occupy the same extent.
        // Not the same *count* — a second pass over an antialiased edge darkens
        // it past the threshold — so this compares where the ink is.
        let box = typesetter().layout("x", display: true).box
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        func extent(_ passes: Int) throws -> (Int, Int) {
            guard let ctx = bitmap() else { return (-1, -1) }
            for _ in 0..<passes {
                box.draw(in: ctx, at: CGPoint(x: 8, y: 40), color: black)
            }
            var left = ctx.width, right = -1
            let width = ctx.width
            eachPixel(ctx) { index, r, _, _ in
                if r < 250 {
                    left = min(left, index % width)
                    right = max(right, index % width)
                }
            }
            return (left, right)
        }
        try expectEqual("\(try extent(1))", "\(try extent(2))")
    }

    test("MathBox.draw: a display formula inks more than an inline one") {
        // Display style sets fractions full size; inline squeezes them.
        let big = try inkFor("\\frac{a}{b}", display: true)
        let small = try inkFor("\\frac{a}{b}", display: false)
        try expect(big > small, "display style should draw larger")
    }
}
