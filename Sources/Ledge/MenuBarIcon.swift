import AppKit

/// The menu bar icon: the app logo reduced to one color. Three stepped cards, drawn as a template image
/// so macOS tints it for light, dark and highlighted menu bars.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    /// Drawn once into 1x, 2x and 3x bitmaps. Bitmaps, unlike a drawing closure, always render in a status item.
    static var image: NSImage {
        let image = NSImage(size: size)
        for scale in [1, 2, 3] {
            let pixels = Int(size.width) * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ledge"
        return image
    }

    static func draw() {
        func card(_ rect: NSRect, radius: CGFloat, alpha: CGFloat) {
            NSColor.black.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        card(NSRect(x: 8.5, y: 13.2, width: 7.5, height: 3.2), radius: 1.4, alpha: 0.55)   // back
        card(NSRect(x: 5, y: 8.6, width: 11, height: 3.8), radius: 1.6, alpha: 0.8)        // middle
        card(NSRect(x: 2, y: 2, width: 14, height: 5.6), radius: 1.9, alpha: 1)            // front

        // The line on the front card, cut out of it.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: 4.2, width: 5, height: 1.2), xRadius: 0.6, yRadius: 0.6).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}
