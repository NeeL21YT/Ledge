import AppKit

/// A button whose layer background is exactly as big as its constraints say.
/// NSButton adds hidden alignment insets, which stretches a 30x30 constraint into a taller frame
/// and turns a rounded background into an oval.
class GlassButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    // MARK: Hover and press
    // The button lights up in the brand color and grows slightly under the pointer, and dips when pressed.

    private var restingColor: CGColor?
    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        hovering = true
        if restingColor == nil { restingColor = layer?.backgroundColor }
        apply(color: Brand.accent.withAlphaComponent(0.6).cgColor, scale: 1.08)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        apply(color: restingColor, scale: 1)
    }

    override func mouseDown(with event: NSEvent) {
        apply(color: Brand.accent.withAlphaComponent(0.8).cgColor, scale: 0.94)
        super.mouseDown(with: event) // returns when the click ends
        apply(color: hovering ? Brand.accent.withAlphaComponent(0.6).cgColor : restingColor, scale: hovering ? 1.08 : 1)
    }

    private func apply(color: CGColor?, scale: CGFloat) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.backgroundColor = color
        // Scale around the center: layers of views anchor at the corner.
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CGAffineTransform(translationX: c.x, y: c.y)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -c.x, y: -c.y)
        layer.transform = CATransform3DMakeAffineTransform(t)
        CATransaction.commit()
    }
}

/// Small round glass button used in shelf headers (close, expand, back, actions).
func makeCircleButton(symbol: String, tooltip: String, target: AnyObject?, action: Selector?) -> NSButton {
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
    let button = GlassButton(image: image ?? NSImage(), target: target, action: action)
    button.isBordered = false
    button.contentTintColor = .white
    button.toolTip = tooltip
    button.wantsLayer = true
    button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
    button.layer?.cornerRadius = 15
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    return button
}
