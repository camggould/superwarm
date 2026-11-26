// Renders a macOS .iconset from the white-on-transparent logo.
// Usage: swift scripts/make-icon.swift <logo.png> <out.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let glyph = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <logo.png> <out.iconset>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: ~80% tile with continuous-ish corners.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.98, green: 0.57, blue: 0.24, alpha: 1),  // amber
        NSColor(srgbRed: 0.76, green: 0.25, blue: 0.05, alpha: 1),  // ember
    ])!
    gradient.draw(in: path, angle: -90)
    let g = tile.width * 0.62
    glyph.draw(in: NSRect(x: tile.midX - g / 2, y: tile.midY - g / 2, width: g, height: g),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
