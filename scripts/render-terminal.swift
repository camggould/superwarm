// Renders terminal output (with ANSI colours) as a terminal-window PNG, for the README.
//
//   COLUMNS=78 superwarm --demo report week --color always \
//     | swift scripts/render-terminal.swift docs/images/cli-report.png "superwarm report week"
//
// Reads stdin. Lines starting with "$ " are drawn as typed commands. Characters
// sit on a fixed grid, so bars stay aligned even when a glyph falls back to
// another font.
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: render-terminal.swift OUT.png [TITLE] < output\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: args[1])
let title = args.count > 2 ? args[2] : "superwarm"
let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let background = color(0x1F1C19)
let chrome = color(0x2B2724)
let foreground = color(0xE6E1D8)
let palette: [Int: NSColor] = [31: color(0xE0855C), 32: color(0x9CBF84), 33: color(0xE8B04A), 34: color(0x6CA0D8), 36: color(0x1AB28C)]

struct Style {
    var bold = false
    var dim = false
    var color: NSColor?
}

struct Cell {
    var character: Character
    var style: Style
}

/// Splits a line into styled cells, applying SGR escape codes.
func cells(_ line: String) -> [Cell] {
    var result: [Cell] = []
    var style = Style()
    var scalars = Array(line.unicodeScalars)[...]
    var pending = ""
    func flush() {
        for character in pending { result.append(Cell(character: character, style: style)) }
        pending = ""
    }
    while let scalar = scalars.first {
        scalars = scalars.dropFirst()
        if scalar == "\u{1B}", scalars.first == "[" {
            flush()
            scalars = scalars.dropFirst()
            var code = ""
            while let next = scalars.first, next != "m" {
                code.unicodeScalars.append(next)
                scalars = scalars.dropFirst()
            }
            scalars = scalars.dropFirst()
            for part in code.split(separator: ";").compactMap({ Int($0) }) {
                switch part {
                case 0: style = Style()
                case 1: style.bold = true
                case 2: style.dim = true
                default: style.color = palette[part] ?? style.color
                }
            }
        } else {
            pending.unicodeScalars.append(scalar)
        }
    }
    flush()
    return result
}

let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
let rows = lines.map(cells)
let fontSize: CGFloat = 13
let regular = NSFont(name: "Menlo", size: fontSize)!
let bold = NSFont(name: "Menlo-Bold", size: fontSize)!
let cellWidth = ("M" as NSString).size(withAttributes: [.font: regular]).width
let lineHeight: CGFloat = 18
let padding: CGFloat = 22
let titleBar: CGFloat = 34
let columns = max(rows.map(\.count).max() ?? 0, 60)
let size = NSSize(width: CGFloat(columns) * cellWidth + padding * 2,
                  height: titleBar + CGFloat(rows.count) * lineHeight + padding * 1.5)
let scale: CGFloat = 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
// Flip so y grows downward like a terminal.
context.cgContext.translateBy(x: 0, y: size.height)
context.cgContext.scaleBy(x: 1, y: -1)

let window = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 12, yRadius: 12)
background.setFill()
window.fill()
NSGraphicsContext.current?.saveGraphicsState()
window.addClip()
chrome.setFill()
NSRect(x: 0, y: 0, width: size.width, height: titleBar).fill()
NSGraphicsContext.current?.restoreGraphicsState()
for (i, hex) in [UInt32(0xEC6A5E), 0xF4BF4F, 0x61C554].enumerated() {
    color(hex).setFill()
    NSBezierPath(ovalIn: NSRect(x: 16 + CGFloat(i) * 20, y: 11, width: 12, height: 12)).fill()
}
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: foreground.withAlphaComponent(0.55),
]
let titleSize = (title as NSString).size(withAttributes: titleAttributes)
NSGraphicsContext.current?.cgContext.saveGState()
NSGraphicsContext.current?.cgContext.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
func draw(_ string: String, at point: NSPoint, attributes: [NSAttributedString.Key: Any]) {
    // Text draws upside down in a flipped CGContext; undo locally.
    let cg = NSGraphicsContext.current!.cgContext
    cg.saveGState()
    cg.translateBy(x: point.x, y: point.y)
    cg.scaleBy(x: 1, y: -1)
    (string as NSString).draw(at: NSPoint(x: 0, y: -lineHeight + 4), withAttributes: attributes)
    cg.restoreGState()
}
draw(title, at: NSPoint(x: (size.width - titleSize.width) / 2, y: 10 + titleSize.height / 2 + 2), attributes: titleAttributes)

for (row, line) in rows.enumerated() {
    let y = titleBar + padding * 0.75 + CGFloat(row) * lineHeight + lineHeight
    let isCommand = lines[row].hasPrefix("$ ")
    for (column, cell) in line.enumerated() {
        var colorValue = cell.style.color ?? foreground
        if isCommand { colorValue = column == 0 ? palette[32]! : foreground }
        // Blend dim colours with the background (not alpha), so overlapping
        // block characters don't show seams.
        if cell.style.dim { colorValue = colorValue.blended(withFraction: 0.45, of: background) ?? colorValue }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: (cell.style.bold || isCommand) ? bold : regular, .foregroundColor: colorValue,
        ]
        draw(String(cell.character), at: NSPoint(x: padding + CGFloat(column) * cellWidth, y: y), attributes: attributes)
    }
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: output)
