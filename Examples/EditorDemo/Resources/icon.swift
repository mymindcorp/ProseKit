import AppKit

// A page of prose: one heading bar over body lines, ragged at the end like real
// text, on the same blue→cyan the demo's own hero image uses.
let side = 1024.0
// A raw bitmap at exactly 1024x1024 — an NSImage's lockFocus would pick up the
// display's 2x backing and write a 2048 file.
let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Background gradient, corner to corner.
let colors = [NSColor(srgbRed: 0.36, green: 0.42, blue: 0.95, alpha: 1).cgColor,
              NSColor(srgbRed: 0.16, green: 0.78, blue: 0.85, alpha: 1).cgColor]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])

// The page: a soft white card, inset and rounded like the app's own content.
let card = CGRect(x: 196, y: 150, width: 632, height: 724)
ctx.setFillColor(NSColor(white: 1, alpha: 0.16).cgColor)
ctx.addPath(CGPath(roundedRect: card.insetBy(dx: -20, dy: -20),
                   cornerWidth: 84, cornerHeight: 84, transform: nil))
ctx.fillPath()
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(CGPath(roundedRect: card, cornerWidth: 64, cornerHeight: 64, transform: nil))
ctx.fillPath()

func bar(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
                       cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
    ctx.fillPath()
}

// Text lines: a heading over body text, with more air under the heading than
// the body lines take between them — the proportion this app exists to
// demonstrate. The body gap is solved for rather than guessed, so the block
// sits on equal padding top and bottom whatever the other numbers become.
let ink = NSColor(srgbRed: 0.13, green: 0.16, blue: 0.24, alpha: 1)
let body = NSColor(srgbRed: 0.66, green: 0.70, blue: 0.77, alpha: 1)
let pad = 78.0, textX = card.minX + 74
let headingHeight = 54.0, headingGap = 62.0, bodyHeight = 28.0
let widths = [452.0, 452.0, 408.0, 452.0, 452.0, 300.0]   // ragged final line
let bodyTop = card.maxY - pad - headingHeight - headingGap
let bodySpan = bodyTop - (card.minY + pad)
let bodyGap = (bodySpan - Double(widths.count) * bodyHeight) / Double(widths.count - 1)

bar(textX, card.maxY - pad - headingHeight, 328, headingHeight, ink)
var y = bodyTop - bodyHeight
for width in widths {
    bar(textX, y, width, bodyHeight, body)
    y -= bodyHeight + bodyGap
}
// A caret at the end of the ragged line, where the writer left off — centred
// on that line, and rounded by its own width so it reads as a caret rather
// than the lozenge a line-height radius would make of it.
let lastCentre = y + bodyHeight + bodyGap + bodyHeight / 2
let caret = CGRect(x: textX + widths.last! + 26, y: lastCentre - 29, width: 13, height: 58)
ctx.setFillColor(NSColor(srgbRed: 0.16, green: 0.52, blue: 0.96, alpha: 1).cgColor)
ctx.addPath(CGPath(roundedRect: caret, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
ctx.fillPath()

let cg = ctx.makeImage()!
let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
