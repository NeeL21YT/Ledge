import AppKit
import Quartz

/// A shelf has two faces: a compact square (file preview + name pill) and an expanded
/// grid or list of every file. Files are for dragging out, not opening.
final class ShelfViewController: NSViewController, NSCollectionViewDelegate, NSMenuDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    enum Presentation { case compact, expanded }

    private static let expandedWidth: CGFloat = 406
    private static let headerHeight: CGFloat = 62
    private static let gridRowHeight: CGFloat = ItemCell.gridSize.height + 8
    private static let listRowHeight: CGFloat = ItemCell.listRowHeight + 6

    let shelf: Shelf
    var onClose: (() -> Void)?
    var onDesiredSizeChange: ((NSSize) -> Void)?
    var onToggleDock: (() -> Void)?
    var isDocked: () -> Bool = { false }

    private(set) var presentation: Presentation = .compact

    private let dropView = DropTargetView(frame: .zero)
    private let compactView = CompactShelfView(frame: .zero)
    private let expandedView = NSView()
    private let collection = ItemCollectionView()
    private let scroll = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var layoutControl = NSSegmentedControl()
    private var optionsButton = NSButton()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, UUID>!
    private var previewURLs: [NSURL] = []
    private var isCompressing = false
    private lazy var expandedHeight = expandedView.heightAnchor.constraint(equalToConstant: expandedSize.height)
    private var isConverting = false
    private var isLinking = false
    private var renderedList: Bool?
    /// The items a right-click was on; held until the menu's action has run.
    private var menuTargets: [ShelfItem]?

    private var isList: Bool { Prefs.listLayout }

    init(shelf: Shelf) {
        self.shelf = shelf
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    var desiredSize: NSSize {
        switch presentation {
        case .compact:
            return CompactShelfView.size
        case .expanded:
            return expandedSize
        }
    }

    private var expandedSize: NSSize {
        let tiles = shelf.items.count + 1 // plus the Reveal tile
        let content: CGFloat = isList
            ? CGFloat(min(tiles, 5)) * Self.listRowHeight
            : CGFloat(min(Int(ceil(Double(tiles) / 3.0)), 3)) * Self.gridRowHeight
        return NSSize(width: Self.expandedWidth, height: Self.headerHeight + content + 16)
    }

    // MARK: Layout

    override func loadView() {
        dropView.frame = NSRect(origin: .zero, size: desiredSize)
        dropView.onDrop = { [weak self] info in self?.acceptDrop(info) ?? false }
        view = dropView

        compactView.onClose = { [weak self] in self?.onClose?() }
        compactView.onDraggedOut = { [weak self] in self?.draggedOut() }
        compactView.onActions = { [weak self] anchor in self?.showActionsMenu(from: anchor) }
        compactView.onExpand = { [weak self] in self?.setPresentation(.expanded) }

        let header = makeHeader()
        configureCollection()
        for v in [header, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            expandedView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: expandedView.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: expandedView.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: expandedView.trailingAnchor, constant: -14),
            header.heightAnchor.constraint(equalToConstant: 40),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: expandedView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: expandedView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: expandedView.bottomAnchor),
        ])

        // Both faces keep a fixed size, pinned top-left. The window then resizes around them without
        // relaying out either one on every frame, which is what keeps expand and collapse smooth.
        for v in [compactView, expandedView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            dropView.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: dropView.topAnchor),
                v.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            compactView.widthAnchor.constraint(equalToConstant: CompactShelfView.size.width),
            compactView.heightAnchor.constraint(equalToConstant: CompactShelfView.size.height),
            expandedView.widthAnchor.constraint(equalToConstant: Self.expandedWidth),
            expandedHeight,
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        shelf.onChange = { [weak self] in self?.refresh() }
        refresh(animated: false)
        dropView.stripDragRegistrations()
    }


    private func makeHeader() -> NSView {
        let back = makeCircleButton(symbol: "chevron.left", tooltip: "Collapse", target: self, action: #selector(collapseTapped))
        optionsButton = makeCircleButton(symbol: "slider.horizontal.3", tooltip: "Actions", target: self, action: #selector(optionsTapped))

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 0

        let images = ["square.grid.2x2", "list.bullet"].map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage() }
        layoutControl = NSSegmentedControl(images: images, trackingMode: .selectOne, target: self, action: #selector(layoutChanged(_:)))
        layoutControl.segmentStyle = .capsule
        layoutControl.selectedSegment = isList ? 1 : 0
        layoutControl.selectedSegmentBezelColor = Brand.accent

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [back, titles, spacer, optionsButton, layoutControl])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        // The header is hidden in compact mode; its content must not set the window's minimum width.
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func configureCollection() {
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 2, left: 12, bottom: 12, right: 12)

        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.delegate = self
        collection.register(ItemCell.self, forItemWithIdentifier: ItemCell.identifier)
        collection.setDraggingSourceOperationMask(Prefs.outsideDragMask, forLocal: false)
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)

        collection.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        collection.onDelete = { [weak self] in self?.removeSelected() }
        collection.onCopy = { [weak self] in self?.copyTargets() }
        collection.onShortcut = { [weak self] event in
            guard let self, let action = Prefs.customActions.first(where: { $0.matches(event) }) else { return false }
            ActionRunner.run(action, on: self.targets().map(\.url))
            return true
        }
        collection.contextMenuProvider = { [weak self] onItem in self?.makeContextMenu(onItem: onItem) }

        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        dataSource = NSCollectionViewDiffableDataSource<Int, UUID>(collectionView: collection) { [weak self] cv, path, id in
            let cell = cv.makeItem(withIdentifier: ItemCell.identifier, for: path) as! ItemCell
            guard let self else { return cell }
            if id == actionTileID {
                cell.configureAction(title: "Reveal in Finder", symbol: "arrowshape.turn.up.right.circle", list: self.isList) { [weak self] in
                    self?.revealTargets()
                }
            } else if let item = self.shelf.item(id: id) {
                cell.configure(with: item, list: self.isList) { [weak self] in self?.shelf.remove(ids: [id]) }
            }
            return cell
        }
    }

    // MARK: State

    func setPresentation(_ new: Presentation) {
        guard new != presentation else { return }
        presentation = new
        refresh(animated: false, crossfade: true)
    }

    func refresh(animated: Bool = true, crossfade: Bool = false) {
        if presentation == .expanded, shelf.items.isEmpty { presentation = .compact }

        let showCompact = presentation == .compact
        if crossfade {
            // Both faces are visible while the window resizes, then the hidden one is dropped.
            compactView.isHidden = false
            expandedView.isHidden = false
            compactView.alphaValue = showCompact ? 0 : 1
            expandedView.alphaValue = showCompact ? 1 : 0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                compactView.animator().alphaValue = showCompact ? 1 : 0
                expandedView.animator().alphaValue = showCompact ? 0 : 1
            }, completionHandler: { [weak self] in
                guard let self else { return }
                let compactNow = self.presentation == .compact
                self.compactView.isHidden = !compactNow
                self.expandedView.isHidden = compactNow
                self.compactView.alphaValue = 1
                self.expandedView.alphaValue = 1
            })
        } else {
            compactView.isHidden = !showCompact
            expandedView.isHidden = showCompact
            compactView.alphaValue = 1
            expandedView.alphaValue = 1
        }
        compactView.update(items: shelf.items)
        Thumbnails.prefetch(shelf.items.map(\.url))

        let summary = FileInfo.summary(of: shelf.items)
        titleLabel.stringValue = isLinking ? "Getting link…" : isConverting ? "Converting…" : isCompressing ? "Compressing…" : summary.title
        subtitleLabel.stringValue = summary.subtitle

        expandedHeight.constant = expandedSize.height
        let list = isList
        layout.itemSize = list ? NSSize(width: Self.expandedWidth - 24, height: ItemCell.listRowHeight) : ItemCell.gridSize
        layout.invalidateLayout()

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        var ids = shelf.items.map(\.id)
        if !ids.isEmpty { ids.append(actionTileID) }
        snapshot.appendItems(ids)
        let changed = shelf.takeChangedIDs()
        if renderedList != list { snapshot.reloadItems(ids) } // cells need the other layout
        else { snapshot.reloadItems(ids.filter { changed.contains($0) }) }
        renderedList = list
        dataSource.apply(snapshot, animatingDifferences: animated && presentation == .expanded)

        onDesiredSizeChange?(desiredSize)
    }

    // MARK: Selection and drag out

    /// The clicked items while a menu is open, else the selected items, else every item.
    private func targets() -> [ShelfItem] {
        if let menuTargets { return menuTargets.filter { !$0.isMissing } }
        let selected = collection.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) }.compactMap { shelf.item(id: $0) }
        return (selected.isEmpty ? shelf.items : selected).filter { !$0.isMissing }
    }

    func collectionView(_ cv: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        indexPaths.filter { dataSource.itemIdentifier(for: $0) != actionTileID }
    }

    func collectionView(_ cv: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        cv.setDraggingSourceOperationMask(Prefs.outsideDragMask, forLocal: false) // pick up settings changes
    }

    func collectionView(_ cv: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        if !operation.isEmpty { draggedOut() }
    }

    /// Files left the shelf for another app or folder; close it if the user asked for that.
    func draggedOut() {
        guard Prefs.autoCloseAfterDrag else { return }
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }

    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        indexPaths.allSatisfy { dataSource.itemIdentifier(for: $0) != actionTileID }
    }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = shelf.item(id: id), !item.isMissing else { return nil }
        return item.url as NSURL
    }

    // MARK: Drop in

    private func acceptDrop(_ info: NSDraggingInfo) -> Bool {
        PasteboardImporter.urls(from: info.draggingPasteboard) { [weak self] urls in self?.shelf.add(urls) }
        return true
    }

    // MARK: Actions

    private func revealTargets() { NSWorkspace.shared.activateFileViewerSelecting(targets().map(\.url)) }

    private func copyTargets() {
        let urls = targets().map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }

    private func removeSelected() {
        let ids = Set(collection.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) }).subtracting([actionTileID])
        shelf.remove(ids: ids)
    }

    private func compress() {
        let urls = targets().map(\.url)
        guard !urls.isEmpty, !isCompressing else { return }
        isCompressing = true
        refresh(animated: false)
        Archiver.zip(urls) { [weak self] archive in
            guard let self else { return }
            self.isCompressing = false
            if let archive { self.shelf.add([archive]) } else { NSSound.beep(); self.refresh(animated: false) }
        }
    }

    private func showActionsMenu(from anchor: NSView) {
        let menu = makeContextMenu(onItem: !shelf.items.isEmpty)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 6), in: anchor)
    }

    @objc private func collapseTapped() { setPresentation(.compact) }
    @objc private func optionsTapped() { showActionsMenu(from: optionsButton) }

    @objc private func layoutChanged(_ sender: NSSegmentedControl) {
        Prefs.listLayout = sender.selectedSegment == 1
        refresh(animated: false)
    }

    @objc private func addFilesTapped() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.begin { [weak self] response in
            if response == .OK { self?.shelf.add(panel.urls) }
        }
    }

    @objc private func contextQuickLook() { toggleQuickLook() }
    @objc private func contextReveal() { revealTargets() }
    @objc private func contextCopy() { copyTargets() }
    @objc private func contextCompress() { compress() }
    @objc private func contextCustomAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let action = Prefs.customActions.first(where: { $0.id == id }) else { return }
        ActionRunner.run(action, on: targets().map(\.url))
    }
    /// Publishes the files through iCloud Drive and puts the links on the clipboard.
    @objc private func contextICloudLink() {
        guard !isLinking else { return }
        let urls = targets().map(\.url)
        guard !urls.isEmpty else { return }
        isLinking = true
        refresh(animated: false)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CloudLinks.makeLinks(for: urls) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLinking = false
                self.refresh(animated: false)
                switch result {
                case .success(let links):
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(links.map(\.absoluteString).joined(separator: "\n"), forType: .string)
                    NSSound(named: "Glass")?.play()
                case .failure(let error):
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t get an iCloud link"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
    @MainActor @objc private func contextRename() { Renamer.run(items: targets(), shelf: shelf) }
    @objc private func contextQuickConvert() { quickConvert() }

    /// One-click conversion with the Quick Convert settings. By default converted files replace their sources on the shelf;
    /// the originals on disk are never touched.
    private func quickConvert() {
        guard !isConverting else { return }
        let sources = targets()
        var settings = Prefs.quickSettings
        settings.destination = .shelf
        let replace = Prefs.quickReplacesSources
        let jobs: [(source: ShelfItem, files: [URL])] = sources.map { ($0, ImageConverter.imageFiles(in: [$0.url])) }
        let urls = jobs.flatMap(\.files)
        guard !urls.isEmpty else { NSSound.beep(); return }
        isConverting = true
        refresh(animated: false)

        DispatchQueue.global(qos: .userInitiated).async {
            let outputs = ImageConverter.plan(urls, settings: settings, stagingFolder: Staging.makeFolder())
            let watermark = ImageConverter.loadWatermark(settings)
            var succeeded = [Bool](repeating: false, count: urls.count)
            let lock = NSLock()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
            for i in urls.indices {
                queue.addOperation {
                    let ok = (try? ImageConverter.convert(urls[i], to: outputs[i], settings: settings, watermark: watermark)) != nil
                    lock.lock(); succeeded[i] = ok; lock.unlock()
                }
            }
            queue.waitUntilAllOperationsAreFinished()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isConverting = false
                var offset = 0
                var replaced: Set<UUID> = []
                var added: [URL] = []
                for job in jobs {
                    let range = offset..<(offset + job.files.count)
                    offset += job.files.count
                    guard !range.isEmpty else { continue }
                    let good = range.filter { succeeded[$0] }
                    added += good.map { outputs[$0] }
                    if replace, good.count == range.count { replaced.insert(job.source.id) }
                }
                if succeeded.contains(false) { NSSound.beep() }
                self.shelf.add(added) // first, so the shelf never empties and collapses
                self.shelf.remove(ids: replaced)
                self.refresh(animated: false)
            }
        }
    }

    @MainActor @objc private func contextConvert() {
        ConverterWindow.show(urls: targets().map(\.url)) { [weak self] converted in self?.shelf.add(converted) }
    }
    @objc private func contextRemove() { removeSelected(menuTargets: menuTargets) }
    @objc private func contextClear() { shelf.clear() }
    @objc private func contextDock() { onToggleDock?() }
    @objc private func contextSettings() { SettingsWindow.show() }
    @objc private func contextCopyTo() { transfer(move: false) }
    @objc private func contextMoveTo() { transfer(move: true) }
    @objc private func contextAddFromClipboard() {
        PasteboardImporter.urls(from: .general) { [weak self] urls in
            if urls.isEmpty { NSSound.beep() } else { self?.shelf.add(urls) }
        }
    }

    /// "Remove from Shelf" acts on the clicked items even though nothing stays highlighted.
    private func removeSelected(menuTargets: [ShelfItem]?) {
        if let menuTargets { shelf.remove(ids: Set(menuTargets.map(\.id))) } else { removeSelected() }
    }

    @objc private func contextOpenWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(targets().map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func contextShareWith(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? NSSharingService else { return }
        service.perform(withItems: targets().map(\.url))
    }

    /// Copies or moves the chosen files into a folder picked by the user.
    private func transfer(move: Bool) {
        let items = targets()
        guard !items.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = move ? "Move Here" : "Copy Here"
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url, let self else { return }
            let fm = FileManager.default
            var moved: Set<UUID> = []
            for item in items {
                let destination = Self.uniqueURL(folder.appendingPathComponent(item.name))
                do {
                    if move { try fm.moveItem(at: item.url, to: destination); moved.insert(item.id) }
                    else { try fm.copyItem(at: item.url, to: destination) }
                } catch {
                    NSAlert(error: error).runModal()
                    break
                }
            }
            self.shelf.remove(ids: moved)
        }
    }

    private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base) \(n)").appendingPathExtension(url.pathExtension)
            n += 1
        }
        return candidate
    }

    private func makeContextMenu(onItem: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menuTargets = onItem ? targets() : nil
        @discardableResult
        func add(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
            menu.addItem(item)
            return item
        }

        if onItem {
            let chosen = menuTargets ?? []
            if let first = chosen.first {
                let apps = NSWorkspace.shared.urlsForApplications(toOpen: first.url)
                if !apps.isEmpty {
                    let sub = NSMenu()
                    for app in apps.prefix(14) {
                        let item = NSMenuItem(title: app.deletingPathExtension().lastPathComponent,
                                              action: #selector(contextOpenWith(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = app
                        let icon = NSWorkspace.shared.icon(forFile: app.path)
                        icon.size = NSSize(width: 16, height: 16)
                        item.image = icon
                        sub.addItem(item)
                    }
                    let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                    openWith.submenu = sub
                    menu.addItem(openWith)
                }
            }
            add("Show in Finder", #selector(contextReveal), symbol: "folder")
            add("Quick Look", #selector(contextQuickLook), symbol: "eye")
            menu.addItem(.separator())

            let services = NSSharingService.sharingServices(forItems: chosen.map(\.url))
            let favorites = ["AirDrop", "Mail", "Messages", "Notes"].compactMap { name in
                services.first { $0.title.localizedCaseInsensitiveContains(name) }
            }
            func serviceItem(_ service: NSSharingService) -> NSMenuItem {
                let item = NSMenuItem(title: service.title, action: #selector(contextShareWith(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = service
                let icon = service.image.copy() as? NSImage
                icon?.size = NSSize(width: 16, height: 16)
                item.image = icon
                return item
            }
            favorites.forEach { menu.addItem(serviceItem($0)) }
            let others = services.filter { s in !favorites.contains { $0 === s } }
            if !others.isEmpty {
                let sub = NSMenu()
                others.forEach { sub.addItem(serviceItem($0)) }
                let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
                more.submenu = sub
                menu.addItem(more)
            }
            menu.addItem(.separator())
        }

        add("Add Files…", #selector(addFilesTapped), symbol: "plus")
        add("Add From Clipboard", #selector(contextAddFromClipboard), symbol: "doc.on.clipboard")
        if onItem {
            let chosen = menuTargets ?? []
            let copyTitle = chosen.count == 1 ? String(format: "Copy “%@”", chosen[0].name) : String(format: "Copy %d Items", chosen.count)
            add(copyTitle, #selector(contextCopy), symbol: "doc.on.doc")
            add("Copy to…", #selector(contextCopyTo), symbol: "arrow.right.circle.fill")
            add("Move to…", #selector(contextMoveTo), symbol: "arrow.right.circle")
            let actions = Prefs.customActions.filter { !$0.name.isEmpty && !$0.command.isEmpty }
            if !actions.isEmpty {
                let sub = NSMenu()
                for action in actions {
                    let item = NSMenuItem(title: action.name, action: #selector(contextCustomAction(_:)), keyEquivalent: action.hasShortcut ? action.key.lowercased() : "")
                    if action.hasShortcut { item.keyEquivalentModifierMask = action.modifierFlags }
                    item.target = self
                    item.representedObject = action.id
                    sub.addItem(item)
                }
                let parent = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
                parent.submenu = sub
                menu.addItem(parent)
            }
            add("Copy iCloud Link", #selector(contextICloudLink), symbol: "icloud")
            add("Rename…", #selector(contextRename), symbol: "pencil")
            add("Compress", #selector(contextCompress), symbol: "archivebox")
            if chosen.contains(where: { ImageConverter.canRead($0.url) || FileInfo.isDirectory($0.url) }) {
                let quick = Prefs.quickSettings
                let formats = Set(chosen.filter { ImageConverter.canRead($0.url) }.map { ImageConverter.resolvedFormat(quick, for: $0.url) })
                let target = formats.count == 1 ? formats.first!.shortTitle : "Selected Format"
                add(String(format: "Quick Convert to %@", target), #selector(contextQuickConvert), symbol: "bolt")
            }
            add("Convert Images…", #selector(contextConvert), symbol: "photo.on.rectangle")
        }
        menu.addItem(.separator())
        add("Clear Shelf", #selector(contextClear), symbol: "delete.left")
        add(isDocked() ? "Undock from Edge" : "Dock to Edge", #selector(contextDock), symbol: "sidebar.left")
        add("Settings…", #selector(contextSettings), symbol: "gearshape")
        if onItem {
            menu.addItem(.separator())
            add("Remove from Shelf", #selector(contextRemove), symbol: "minus.circle")
        }
        return menu
    }

    func menuDidClose(_ menu: NSMenu) {
        // Runs after the chosen action, so targets() still sees the clicked items.
        DispatchQueue.main.async { [weak self] in
            self?.menuTargets = nil
            self?.collection.deselectAll(nil)
        }
    }

    // MARK: Quick Look

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        previewURLs = targets().map { $0.url as NSURL }
        guard !previewURLs.isEmpty else { return }
        panel.level = .floating + 1
        panel.makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] }
}
