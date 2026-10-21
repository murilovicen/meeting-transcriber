// Renders the MeetRec app icon: a speech bubble where a waveform turns into lines of text.
// Usage: swift tools/make-icon.swift <out.png> [size]
import AppKit

let out = CommandLine.arguments[1]
let S = CGFloat(Double(CommandLine.arguments.dropFirst(2).first ?? "1024") ?? 1024)
let k = S / 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * k, y: y * k, width: w * k, height: h * k) }

// Tile (Apple grid: 824pt body inside 1024 canvas), with a soft drop shadow.
let tile = CGPath(roundedRect: r(100, 100, 824, 824), cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: rgb(0x000000, 0.35))
ctx.addPath(tile); ctx.setFillColor(rgb(0x3B2A9E)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [rgb(0x7B6CFF), rgb(0x4B32D6), rgb(0x2A1878)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 200 * k, y: 924 * k), end: CGPoint(x: 824 * k, y: 100 * k), options: [])
// glossy top light
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(gloss, startCenter: CGPoint(x: 380 * k, y: 900 * k), startRadius: 0,
                       endCenter: CGPoint(x: 380 * k, y: 900 * k), endRadius: 560 * k, options: [])
ctx.restoreGState()

// Speech bubble with a tail at the bottom-left.
let bubble = CGMutablePath()
bubble.addPath(CGPath(roundedRect: r(215, 330, 594, 420), cornerWidth: 120 * k, cornerHeight: 120 * k, transform: nil))
bubble.move(to: CGPoint(x: 300 * k, y: 350 * k))
bubble.addLine(to: CGPoint(x: 262 * k, y: 232 * k))
bubble.addLine(to: CGPoint(x: 420 * k, y: 340 * k))
bubble.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 30 * k, color: rgb(0x120A40, 0.45))
ctx.addPath(bubble); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()

// Waveform bars (left) morphing into text lines (right).
let accent = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [rgb(0xFF2D6F), rgb(0x5B3BFF)] as CFArray, locations: [0, 1])!
let content = CGMutablePath()
let bars: [CGFloat] = [70, 150, 230, 130, 190]
for (i, h) in bars.enumerated() {
    let x = 285 + CGFloat(i) * 52
    content.addPath(CGPath(roundedRect: r(x, 540 - h / 2, 30, h), cornerWidth: 15 * k, cornerHeight: 15 * k, transform: nil))
}
let lines: [(CGFloat, CGFloat)] = [(610, 150), (540, 110), (470, 135)]
for (y, w) in lines {
    content.addPath(CGPath(roundedRect: r(565, y - 15, w, 30), cornerWidth: 15 * k, cornerHeight: 15 * k, transform: nil))
}
ctx.saveGState()
ctx.addPath(content); ctx.clip()
ctx.drawLinearGradient(accent, start: CGPoint(x: 285 * k, y: 540 * k), end: CGPoint(x: 740 * k, y: 540 * k), options: [])
ctx.restoreGState()

// Live dot.
ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: r(718, 668, 112, 112))
ctx.setFillColor(rgb(0xFF3B5C)); ctx.fillEllipse(in: r(736, 686, 76, 76))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
