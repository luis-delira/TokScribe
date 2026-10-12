// Genera un .iconset sencillo (onda de audio sobre degradado) para la app.
// Uso: swift Tools/MakeIcon.swift <carpeta-destino.iconset>
import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = size * 0.055
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
    path.addClip()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.14, green: 0.83, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.92, alpha: 1),
        NSColor(calibratedRed: 0.98, green: 0.16, blue: 0.36, alpha: 1),
    ])
    gradient?.draw(in: rect, angle: -55)

    // Barras tipo onda de audio.
    let heights: [CGFloat] = [0.22, 0.42, 0.68, 0.95, 0.55, 0.80, 0.34, 0.60, 0.26]
    let barWidth = rect.width * 0.055
    let spacing = rect.width * 0.028
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
    var x = rect.midX - totalWidth / 2
    NSColor.white.withAlphaComponent(0.95).setFill()

    for factor in heights {
        let barHeight = rect.height * 0.46 * factor
        let bar = NSRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + spacing
    }

    image.unlockFocus()
    return image
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = drawIcon(size: CGFloat(variant.pixels))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: outputURL.appendingPathComponent("\(variant.name).png"))
}

print("iconset generado en \(outputURL.path)")
