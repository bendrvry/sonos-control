// Draws the app icon (white waveform on black glass, its light split into colour at the edges)
// and writes it as an .icns file. Usage: swift make-icon.swift <output.icns>
import AppKit
import CoreImage

let N: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext()
func render(_ draw: (CGContext) -> Void) -> CGImage {
    let c = CGContext(data: nil, width: Int(N), height: Int(N), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(c); return c.makeImage()!
}
func blur(_ img: CGImage, _ r: CGFloat) -> CGImage {
    let out = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: CGRect(x: 0, y: 0, width: N, height: N))
    return ci.createCGImage(out, from: out.extent)!
}
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
func hue(_ h: CGFloat, _ s: CGFloat = 1, _ v: CGFloat = 1, _ a: CGFloat = 1) -> CGColor { NSColor(hue: h, saturation: s, brightness: v, alpha: a).usingColorSpace(.sRGB)!.cgColor }
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
func bars(dx: CGFloat = 0, dy: CGFloat = 0) -> CGPath {
    let p = CGMutablePath()
    for (i, h) in [0.23, 0.44, 0.60, 0.35, 0.17].enumerated() {
        let w = N * 0.058, hh = N * h * 0.92, x = N * (0.281 + Double(i) * 0.095) + dx
        p.addRoundedRect(in: CGRect(x: x, y: (N - hh) / 2 + dy, width: w, height: hh), cornerWidth: w / 2, cornerHeight: w / 2)
    }
    return p
}
func barsImage(_ color: CGColor, dx: CGFloat = 0, dy: CGFloat = 0) -> CGImage {
    render { c in c.setFillColor(color); c.addPath(bars(dx: dx, dy: dy)); c.fillPath() }
}
func gradient(_ c: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    c.drawLinearGradient(CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func rim(_ c: CGContext, light: CGFloat) {
    c.saveGState(); c.addPath(tilePath); c.clip()
    c.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
    c.setLineWidth(6); c.replacePathWithStrokedPath(); c.clip()
    gradient(c, [rgb(1, 1, 1, light), rgb(1, 1, 1, light * 0.15), rgb(1, 1, 1, light * 0.5)], from: CGPoint(x: 200, y: 924), to: CGPoint(x: 824, y: 100))
    c.restoreGState()
}
let spectrum: [CGFloat] = [0.0, 0.07, 0.14, 0.38, 0.52, 0.62, 0.78]
let full = CGRect(x: 0, y: 0, width: N, height: N)
let master = render { c in
    c.addPath(tilePath); c.clip()
    gradient(c, [rgb(0.17, 0.17, 0.19), rgb(0.03, 0.03, 0.04)], from: CGPoint(x: 0, y: 924), to: CGPoint(x: 0, y: 100))
    // A soft halo of the waveform in each hue, fanned out sideways.
    for (i, h) in spectrum.enumerated() {
        let t = CGFloat(i) - 3
        c.setBlendMode(.screen); c.setAlpha(0.55)
        c.draw(blur(barsImage(hue(h), dx: t * 26, dy: -t * 9), 26), in: full)
    }
    // Red, green and blue copies add up to white where they overlap and fringe where they don't.
    c.setAlpha(1); c.setBlendMode(.plusLighter)
    for (color, d) in [(rgb(1, 0, 0), -9.0), (rgb(0, 1, 0), 0.0), (rgb(0, 0, 1), 9.0)] {
        c.setFillColor(color); c.addPath(bars(dx: d, dy: -d * 0.35)); c.fillPath()
    }
    c.setBlendMode(.normal); rim(c, light: 0.28)
}

func png(_ pixels: Int) -> Data {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}
func length(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
var entries = Data()
for (type, pixels) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let data = png(pixels)
    entries += Data(type.utf8) + length(data.count + 8) + data
}
try (Data("icns".utf8) + length(entries.count + 8) + entries).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
