// Draws Dropoverr's 1024px app icon: the logo on a soft white tile.
// Usage: swift make-icon.swift Resources/logo.svg out.png
import AppKit

let logo = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The tile, with a soft drop shadow like built-in macOS icons.
let tile = NSRect(x: 100, y: 110, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1),
           ending: NSColor(calibratedRed: 0.88, green: 0.90, blue: 1.0, alpha: 1))!
    .draw(in: shape, angle: -90)

// The logo.
logo.draw(in: tile.insetBy(dx: 92, dy: 92))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
