import AppKit

/// Stand-in id for the "Reveal in Finder" tile that trails the items in the expanded shelf.
let actionTileID = UUID(uuidString: "00000000-0000-0000-0000-00000000ACE5")!

/// Cell background that shows a remove button while the pointer is over it.
final class ItemCellView: NSView {
    let removeButton = NSButton()
    var allowsRemove = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        removeButton.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    var isSelectedLook = false { didSet { refreshBackground() } }
    private var isHovering = false { didSet { refreshBackground() } }

    override func mouseEntered(with event: NSEvent) { removeButton.isHidden = !allowsRemove; isHovering = true }
    override func mouseExited(with event: NSEvent) { removeButton.isHidden = true; isHovering = false }

    /// Selected tiles get a strong brand tint, hovered ones a light one. The change fades in.
    func refreshBackground() {
        let color: NSColor? = isSelectedLook ? Brand.accent.withAlphaComponent(0.30)
            : isHovering ? Brand.accent.withAlphaComponent(0.13) : nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer?.backgroundColor = color?.cgColor
        CATransaction.commit()
    }
}

/// One file (or the Reveal tile) in the expanded shelf, laid out as a grid tile or a list row.
final class ItemCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ItemCell")
    static let gridSize = NSSize(width: 122, height: 132)
    static let listRowHeight: CGFloat = 46

    private let icon = PassiveImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private var gridConstraints: [NSLayoutConstraint] = []
    private var listConstraints: [NSLayoutConstraint] = []
    private var isListMode: Bool?
    private var onRemove: (() -> Void)?
    private var onAction: (() -> Void)?
    private var currentID: UUID?

    private var cellView: ItemCellView { view as! ItemCellView }

    override var isSelected: Bool { didSet { updateSelection() } }

    override func loadView() {
        let root = ItemCellView(frame: NSRect(origin: .zero, size: Self.gridSize))
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        view = root

        icon.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let remove = root.removeButton
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.target = self
        remove.action = #selector(removeTapped)
        remove.toolTip = "Remove from shelf"

        actionButton.isBordered = false
        actionButton.title = ""
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.isHidden = true

        for v in [icon, nameLabel, detailLabel, remove, actionButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let common = [
            remove.widthAnchor.constraint(equalToConstant: 18),
            remove.heightAnchor.constraint(equalToConstant: 18),
            actionButton.topAnchor.constraint(equalTo: root.topAnchor),
            actionButton.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            actionButton.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            actionButton.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ]
        NSLayoutConstraint.activate(common)

        gridConstraints = [
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72),
            nameLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            detailLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            remove.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
        ]
        listConstraints = [
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            nameLabel.bottomAnchor.constraint(equalTo: root.centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: root.centerYAnchor, constant: 1),
            remove.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
        ]
        root.stripDragRegistrations()
    }

    private func apply(list: Bool) {
        guard isListMode != list else { return }
        isListMode = list
        NSLayoutConstraint.deactivate(list ? gridConstraints : listConstraints)
        NSLayoutConstraint.activate(list ? listConstraints : gridConstraints)
        nameLabel.alignment = list ? .left : .center
        detailLabel.alignment = list ? .left : .center
    }

    func configure(with item: ShelfItem, list: Bool, onRemove: @escaping () -> Void) {
        apply(list: list)
        currentID = item.id
        self.onRemove = onRemove
        cellView.allowsRemove = true
        actionButton.isHidden = true
        icon.contentTintColor = nil
        nameLabel.stringValue = item.name
        detailLabel.stringValue = item.isMissing ? "Missing" : FileInfo.subtitle(for: item.url)
        view.alphaValue = item.isMissing ? 0.45 : 1
        view.toolTip = item.url.path
        Thumbnails.load(item.url, points: list ? 34 : 72) { [weak self] image in
            if self?.currentID == item.id { self?.icon.image = image }
        }
        updateSelection()
    }

    /// The trailing "Reveal in Finder" tile.
    func configureAction(title: String, symbol: String, list: Bool, handler: @escaping () -> Void) {
        apply(list: list)
        currentID = actionTileID
        onAction = handler
        cellView.allowsRemove = false
        cellView.removeButton.isHidden = true
        actionButton.isHidden = false
        view.alphaValue = 1
        view.toolTip = nil
        let config = NSImage.SymbolConfiguration(pointSize: list ? 22 : 52, weight: .light)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        nameLabel.stringValue = title
        detailLabel.stringValue = ""
        updateSelection()
    }

    private func updateSelection() {
        cellView.isSelectedLook = isSelected
    }

    @objc private func removeTapped() { onRemove?() }
    @objc private func actionTapped() { onAction?() }
}
