// Draws Stash's 1024px app icon to the PNG path given as the first argument.
import AppKit

let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.33, green: 0.56, blue: 1.0, alpha: 1),
           ending: NSColor(calibratedRed: 0.56, green: 0.32, blue: 0.96, alpha: 1))!
    .draw(in: shape, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let size = symbol.size
    symbol.draw(in: NSRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
                           width: size.width, height: size.height))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
