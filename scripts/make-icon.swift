// Renders the ESPIDE app icon and builds Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS-style rounded square: a circuit-board green, light to deep.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSShadow().apply { $0.shadowColor = .black.withAlphaComponent(0.3); $0.shadowBlurRadius = 30; $0.shadowOffset = NSSize(width: 0, height: -12) }
NSGradient(starting: NSColor(red: 0.16, green: 0.62, blue: 0.47, alpha: 1),
           ending: NSColor(red: 0.02, green: 0.29, blue: 0.24, alpha: 1))!.draw(in: shape, angle: -90)
NSShadow().apply { $0.shadowColor = nil }

// Faint traces running from the chip to the edges.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSColor(red: 0.55, green: 0.95, blue: 0.75, alpha: 0.22).setStroke()
for (index, y) in [330.0, 450.0, 574.0, 694.0].enumerated() {
    let trace = NSBezierPath()
    trace.lineWidth = 14
    trace.lineCapStyle = .round
    trace.move(to: NSPoint(x: 100, y: y + (index.isMultiple(of: 2) ? 40 : -40)))
    trace.line(to: NSPoint(x: 190, y: y))
    trace.line(to: NSPoint(x: 834, y: y))
    trace.line(to: NSPoint(x: 924, y: y + (index.isMultiple(of: 2) ? -40 : 40)))
    trace.stroke()
}
NSGraphicsContext.restoreGraphicsState()

// The chip: pins on all four sides, then a dark package on top.
let chip = NSRect(x: 292, y: 292, width: 440, height: 440)
NSColor(red: 0.86, green: 0.88, blue: 0.90, alpha: 1).setFill()
let pinCount = 6, pinWidth: CGFloat = 30, pinLength: CGFloat = 62
let pitch = (chip.width - 80) / CGFloat(pinCount - 1)
for i in 0..<pinCount {
    let offset = chip.minX + 40 + CGFloat(i) * pitch - pinWidth / 2
    for pin in [NSRect(x: offset, y: chip.maxY - 10, width: pinWidth, height: pinLength),
                NSRect(x: offset, y: chip.minY - pinLength + 10, width: pinWidth, height: pinLength),
                NSRect(x: chip.minX - pinLength + 10, y: offset, width: pinLength, height: pinWidth),
                NSRect(x: chip.maxX - 10, y: offset, width: pinLength, height: pinWidth)] {
        NSBezierPath(roundedRect: pin, xRadius: 8, yRadius: 8).fill()
    }
}
NSShadow().apply { $0.shadowColor = .black.withAlphaComponent(0.35); $0.shadowBlurRadius = 18; $0.shadowOffset = NSSize(width: 0, height: -8) }
NSGradient(starting: NSColor(white: 0.22, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))!
    .draw(in: NSBezierPath(roundedRect: chip, xRadius: 46, yRadius: 46), angle: -90)
NSShadow().apply { $0.shadowColor = nil }
// Pin-1 dot.
NSColor(white: 0.35, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: chip.minX + 40, y: chip.maxY - 82, width: 42, height: 42)).fill()

// A REPL prompt on the package: ">_".
let font = NSFont.monospacedSystemFont(ofSize: 230, weight: .heavy)
let prompt = NSAttributedString(string: ">_", attributes: [
    .font: font, .foregroundColor: NSColor(red: 0.45, green: 1, blue: 0.72, alpha: 1),
])
let promptSize = prompt.size()
prompt.draw(at: NSPoint(x: chip.midX - promptSize.width / 2, y: chip.midY - promptSize.height / 2 - 6))
image.unlockFocus()

extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) { configure(self); set() }
}

// Write the iconset and convert.
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! fm.createDirectory(at: URL(fileURLWithPath: "Resources"), withIntermediateDirectories: true)
let output = URL(fileURLWithPath: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
