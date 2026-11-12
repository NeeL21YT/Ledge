import AppKit

/// Pill-shaped button: file name (or "3 Images") with a trailing chevron, both padded inside the capsule.
final class PillButton: GlassButton {
    /// Widest the pill may get; longer names are trimmed with an ellipsis so the card keeps its shape.
    static let maxWidth = CompactShelfView.size.width - 24
    private static let sidePadding: CGFloat = 14
    private static let chevronGap: CGFloat = 6
    private static let chevronWidth: CGFloat = 8

    private let label = NSTextField(labelWithString: "")
    private let chevron = PassiveImageView()
    private var labelToChevron: NSLayoutConstraint!
    private var labelToEdge: NSLayoutConstraint!

    var text: String = "" {
        didSet { label.stringValue = text; invalidateIntrinsicContentSize() }
    }

    var showsChevron = true {
        didSet {
            chevron.isHidden = !showsChevron
            labelToChevron.isActive = showsChevron
            labelToEdge.isActive = !showsChevron
            invalidateIntrinsicContentSize()
        }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.7 }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.cornerRadius = 14

        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        chevron.contentTintColor = .white

        for v in [label, chevron] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        labelToChevron = label.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -Self.chevronGap)
        labelToEdge = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sidePadding)
        labelToEdge.isActive = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sidePadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sidePadding + 2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: Self.chevronWidth),
            labelToChevron,
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        var width = label.intrinsicContentSize.width + Self.sidePadding * 2
        if showsChevron { width += Self.chevronGap + Self.chevronWidth - 2 }
        return NSSize(width: min(width, Self.maxWidth), height: 28)
    }

    /// Clicks on the label or chevron count as clicks on the pill.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

/// The stack of file previews in the compact shelf. Dragging it drags every file on the shelf.
final class PreviewStackView: NSView, NSDraggingSource {
    var items: [ShelfItem] = [] {
        didSet {
            for item in items.prefix(3) where images[item.url] == nil {
                Thumbnails.load(item.url, points: 110) { [weak self] image in
                    self?.images[item.url] = image
                    self?.needsDisplay = true
                }
            }
            needsDisplay = true
        }
    }

    private var images: [URL: NSImage] = [:]
    private var mouseDownLocation: NSPoint?
    var onDraggedOut: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    private func fit(_ size: NSSize, in box: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: box, height: box) }
        let scale = box / max(size.width, size.height)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shown = Array(items.prefix(3))
        let box: CGFloat = shown.count == 1 ? 100 : 86
        let angles: [CGFloat] = [0, -8, 8]
        // Draw back to front so the first item ends up on top.
        for (index, item) in shown.enumerated().reversed() {
            guard let image = images[item.url], let context = NSGraphicsContext.current else { continue }
            context.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.midX, yBy: bounds.midY)
            transform.rotate(byDegrees: shown.count == 1 ? 0 : angles[index])
            transform.concat()

            let shadow = NSShadow()
            shadow.shadowBlurRadius = 9
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.set()

            let size = fit(image.size, in: box)
            image.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            context.restoreGraphicsState()
        }
    }

    override func mouseDown(with event: NSEvent) { mouseDownLocation = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownLocation = nil
        let dragItems = items.filter { !$0.isMissing }.map { item -> NSDraggingItem in
            let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let image = images[item.url] ?? NSWorkspace.shared.icon(forFile: item.url.path)
            let size = fit(image.size, in: 64)
            dragItem.setDraggingFrame(NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                             width: size.width, height: size.height), contents: image)
            return dragItem
        }
        guard !dragItems.isEmpty else { return }
        beginDraggingSession(with: dragItems, event: event, source: self).draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? Prefs.outsideDragMask : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { onDraggedOut?() }
    }
}

/// The collapsed shelf: a small square with the files' preview, close and actions buttons, and a name pill.
final class CompactShelfView: NSView {
    static let size = NSSize(width: 180, height: 204)

    var onClose: (() -> Void)?
    var onDraggedOut: (() -> Void)? {
        get { preview.onDraggedOut }
        set { preview.onDraggedOut = newValue }
    }
    var onActions: ((NSView) -> Void)?
    var onExpand: (() -> Void)?

    private let preview = PreviewStackView()
    private let emptyIcon = PassiveImageView()
    private let pill = PillButton()
    private var items: [ShelfItem] = []

    override init(frame: NSRect) {
        super.init(frame: frame)

        let handle = NSView()
        handle.wantsLayer = true
        handle.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        handle.layer?.cornerRadius = 2

        let close = makeCircleButton(symbol: "xmark", tooltip: "Close shelf", target: self, action: #selector(closeTapped))
        let actions = makeCircleButton(symbol: "chevron.down", tooltip: "Actions", target: self, action: #selector(actionsTapped(_:)))

        let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        emptyIcon.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        emptyIcon.contentTintColor = NSColor.white.withAlphaComponent(0.35)

        pill.target = self
        pill.action = #selector(expandTapped)

        for v in [handle, close, actions, preview, emptyIcon, pill] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            handle.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            handle.centerXAnchor.constraint(equalTo: centerXAnchor),
            handle.widthAnchor.constraint(equalToConstant: 36),
            handle.heightAnchor.constraint(equalToConstant: 4),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            actions.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            preview.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -8),
            emptyIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyIcon.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(items: [ShelfItem]) {
        self.items = items
        preview.items = items
        preview.isHidden = items.isEmpty
        emptyIcon.isHidden = !items.isEmpty

        switch items.count {
        case 0:
            pill.text = "Drop files here"
            pill.showsChevron = false
            pill.isEnabled = false
        case 1:
            pill.text = items[0].name
            pill.showsChevron = true
            pill.isEnabled = true
        default:
            pill.text = FileInfo.summary(of: items).title
            pill.showsChevron = true
            pill.isEnabled = true
        }
        pill.toolTip = items.count > 1 ? "Show all files" : (items.first?.url.path ?? nil)
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func actionsTapped(_ sender: NSButton) { onActions?(sender) }
    @objc private func expandTapped() { onExpand?() }
}
