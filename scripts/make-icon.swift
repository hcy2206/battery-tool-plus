// Renders macos/AppIcon.icns from code so the icon is reproducible without design tools.
// Usage: swift scripts/make-icon.swift macos/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "macos/AppIcon.icns"
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryTool-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    // macOS icon grid: the tile occupies the centre ~80% of the canvas.
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.height * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.72, blue: 0.47, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.62, alpha: 1)])!
        .draw(in: path, angle: -60)
    // Palette order follows the symbol's layers: bolt first, block second.
    let configuration = NSImage.SymbolConfiguration(pointSize: tile.width * 0.52, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 0.07, green: 0.5, blue: 0.58, alpha: 1), .white]))
    if let symbol = NSImage(systemSymbolName: "bolt.batteryblock.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let glyph = NSRect(x: tile.midX - symbol.size.width / 2, y: tile.midY - symbol.size.height / 2,
                           width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: glyph)
    }
    image.unlockFocus()
    return image
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let image = render(size: pixels)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { fatalError("render failed") }
        bitmap.size = NSSize(width: base, height: base)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
        let suffix = scale == 1 ? "" : "@2x"
        try png.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output)")
