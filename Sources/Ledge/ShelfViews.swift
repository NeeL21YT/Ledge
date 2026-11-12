import AppKit
import CoreVideo
import QuartzCore

/// Rounded translucent background that accepts drops anywhere on the shelf.
final class DropTargetView: NSVisualEffectView {
    static let cornerRadius: CGFloat = 18

    var onDrop: ((NSDraggingInfo) -> Bool)?

    /// Accent outline shown while a drag hovers; never intercepts clicks.
    private let outline = PassthroughView()

    private var isTargeted = false {
        didSet { outline.isHidden = !isTargeted }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        maskImage = Self.roundedMask(radius: Self.cornerRadius)

        outline.wantsLayer = true
        outline.layer?.cornerRadius = Self.cornerRadius
        outline.layer?.borderWidth = 2
        outline.layer?.borderColor = Brand.accent.cgColor
        outline.isHidden = true
        outline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outline)
        NSLayoutConstraint.activate([
            outline.topAnchor.constraint(equalTo: topAnchor),
            outline.bottomAnchor.constraint(equalTo: bottomAnchor),
            outline.leadingAnchor.constraint(equalTo: leadingAnchor),
            outline.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        registerForDraggedTypes(Self.acceptedTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .tiff, .png] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// The operation for a drag over the shelf: copy, unless it came from this shelf or holds nothing we can import.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        // Dragging an item out of this same shelf and back in is a no-op.
        if let source = sender.draggingSource as? NSView, source.isDescendant(of: self) { return [] }
        return sender.draggingPasteboard.availableType(from: Self.acceptedTypes) == nil ? [] : .copy
    }

    /// A stretchable rounded rectangle; unlike a layer corner radius it also clips the blurred backdrop.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override func layout() {
        super.layout()
        // Recomputing the window shadow on every frame of a resize is what makes the animation stutter.
        if (window as? ShelfPanel)?.isAnimatingFrame != true { window?.invalidateShadow() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let result = operation(for: sender)
        isTargeted = !result.isEmpty
        return result
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let result = operation(for: sender)
        isTargeted = !result.isEmpty
        return result
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !operation(for: sender).isEmpty }
    override func draggingExited(_ sender: NSDraggingInfo?) { isTargeted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isTargeted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        return onDrop?(sender) ?? false
    }
}

/// Image view that never accepts drops. NSImageView is editable by default and registers for
/// image/file drags, which would swallow a file dropped on top of an icon.
final class PassiveImageView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        unregisterDraggedTypes()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
}

extension NSView {
    /// Clears drag registrations on every descendant so only the shelf background takes drops.
    func stripDragRegistrations() {
        for child in subviews {
            child.unregisterDraggedTypes()
            child.stripDragRegistrations()
        }
    }
}

final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Collection view that reports Space, Delete, Cmd+C and right-click to its owner.
/// Items are for dragging, not opening, so clicks never leave a highlight behind.
final class ItemCollectionView: NSCollectionView {
    var onQuickLook: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?
    /// Gets first look at key presses so custom action shortcuts work; returns true when it used the event.
    var onShortcut: ((NSEvent) -> Bool)?
    /// Receives whether the click landed on an item.
    var contextMenuProvider: ((Bool) -> NSMenu?)?

    override var acceptsFirstResponder: Bool { true }

    /// Drops belong to the shelf background; the stock collection view would otherwise register and refuse them.
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // The click or drag has finished. Only Cmd/Shift-click keeps a multi-selection for dragging several files.
        if event.modifierFlags.isDisjoint(with: [.command, .shift]) { deselectAll(nil) }
    }

    override func keyDown(with event: NSEvent) {
        if onShortcut?(event) == true { return }
        switch event.keyCode {
        case 49: onQuickLook?()                         // space
        case 51, 117: onDelete?()                       // delete, forward delete
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else { return contextMenuProvider?(false) }
        if !selectionIndexPaths.contains(path) { selectionIndexPaths = [path] }
        return contextMenuProvider?(true)
    }
}

/// Panel that can take keyboard focus (for Space, Delete, Cmd+C) without activating the app.
final class ShelfPanel: NSPanel {
    var onEscape: (() -> Void)?
    /// True while the frame is being animated; the shadow is switched off for the duration.
    private(set) var isAnimatingFrame = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // MARK: Frame animation

    /// Animates to `frame` by moving the window once per display refresh. NSWindow's own frame animation
    /// is timer-driven and visibly steps on a blurred window; this stays locked to the screen.
    /// The shadow is off while it runs, since recomputing it every frame is expensive.
    func animateFrame(to target: NSRect, duration: TimeInterval) {
        stopFrameAnimation()
        animStart = frame
        animTarget = target
        animBegan = CACurrentMediaTime()
        animDuration = duration
        isAnimatingFrame = true
        hasShadow = false

        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess, let link = created else {
            finishFrameAnimation()
            return
        }
        displayLink = link
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            self.tickLock.lock()
            let alreadyQueued = self.tickQueued
            self.tickQueued = true
            self.tickLock.unlock()
            if !alreadyQueued {
                DispatchQueue.main.async { self.tick() }
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
    }

    private var displayLink: CVDisplayLink?
    private var animStart = NSRect.zero
    private var animTarget = NSRect.zero
    private var animBegan: CFTimeInterval = 0
    private var animDuration: TimeInterval = 0.3
    private let tickLock = NSLock()
    private var tickQueued = false

    private func tick() {
        tickLock.lock(); tickQueued = false; tickLock.unlock()
        guard displayLink != nil else { return }
        let t = min(1, (CACurrentMediaTime() - animBegan) / animDuration)
        let eased = 1 - pow(1 - t, 3.5) // fast start, long soft landing
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(eased) }
        let next = NSRect(x: mix(animStart.minX, animTarget.minX), y: mix(animStart.minY, animTarget.minY),
                          width: mix(animStart.width, animTarget.width), height: mix(animStart.height, animTarget.height))
        setFrame(next.integral, display: true, animate: false)
        if t >= 1 { finishFrameAnimation() }
    }

    private func stopFrameAnimation() {
        if let link = displayLink { CVDisplayLinkStop(link) }
        displayLink = nil
    }

    private func finishFrameAnimation() {
        stopFrameAnimation()
        setFrame(animTarget, display: true, animate: false)
        isAnimatingFrame = false
        hasShadow = true
        invalidateShadow()
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
    /// Docked shelves slide partly off-screen, so don't pull them back.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
