import AppKit

/// One floating shelf: its model, panel and view controller.
final class ShelfWindowController: NSObject {
    let shelf = Shelf()
    /// True while the shelf was opened by a shake and nothing has been dropped on it yet.
    var isAutoOpened: Bool
    var onClosed: ((ShelfWindowController) -> Void)?

    private let panel: ShelfPanel
    private var dockEdge: Edge?
    private var dockTimer: Timer?

    private enum Edge { case left, right }
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    private let viewController: ShelfViewController

    init(urls: [URL], autoOpened: Bool) {
        isAutoOpened = autoOpened
        viewController = ShelfViewController(shelf: shelf)
        panel = ShelfPanel(contentRect: NSRect(origin: .zero, size: viewController.desiredSize),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()

        panel.contentViewController = viewController
        panel.appearance = NSAppearance(named: .darkAqua)
        // Auto Layout would size the window to the hidden expanded header; the controller owns the size.
        panel.setContentSize(viewController.desiredSize)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEscape = { [weak self] in self?.close() }

        viewController.onClose = { [weak self] in self?.close() }
        viewController.onToggleDock = { [weak self] in self?.toggleDock() }
        viewController.isDocked = { [weak self] in self?.dockEdge != nil }
        viewController.onDesiredSizeChange = { [weak self] in self?.resize(to: $0) }
        let previousOnChange = shelf.onChange
        shelf.onChange = { [weak self] in
            previousOnChange?()
            if self?.shelf.items.isEmpty == false { self?.isAutoOpened = false }
        }
        shelf.add(urls)
    }

    /// Pointer is over the shelf, with a little slack around the edge.
    var containsMouse: Bool { panel.frame.insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation) }

    func show(near point: NSPoint, makeKey: Bool) {
        let size = panel.frame.size
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
            origin.y = min(max(origin.y, area.minY + 8), area.maxY - size.height - 8)
        }
        // Fade in while easing up a few points, so the card settles into place.
        var start = origin
        start.y -= 10
        panel.setFrameOrigin(start)
        panel.alphaValue = 0
        if makeKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = Self.easeOut
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
    }

    func close() {
        dockTimer?.invalidate()
        ShelfHistory.record(shelf)
        onClosed?(self)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    // MARK: Docking

    /// A docked shelf hides against the nearest screen edge, leaving a thin strip,
    /// and slides out while the pointer is over it or the shelf has focus.
    private func toggleDock() {
        if dockEdge != nil {
            dockEdge = nil
            dockTimer?.invalidate()
            slide(toVisible: true, edge: nil)
            return
        }
        guard let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        dockEdge = panel.frame.midX < area.midX ? .left : .right
        dockTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.updateDock() }
        updateDock()
    }

    private func updateDock() {
        guard let edge = dockEdge else { return }
        let hot = panel.frame.contains(NSEvent.mouseLocation) || panel.isKeyWindow
        slide(toVisible: hot, edge: edge)
    }

    private func slide(toVisible visible: Bool, edge: Edge?) {
        guard let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = panel.frame
        let strip: CGFloat = 14
        switch edge {
        case .left?: frame.origin.x = visible ? area.minX + 6 : area.minX - frame.width + strip
        case .right?: frame.origin.x = visible ? area.maxX - frame.width - 6 : area.maxX - strip
        case nil: frame.origin.x = min(max(frame.origin.x, area.minX + 8), area.maxX - frame.width - 8)
        }
        guard abs(frame.origin.x - panel.frame.origin.x) > 0.5 else { return }
        panel.animateFrame(to: frame, duration: 0.26)
    }

    /// Resizes keeping the top-left corner in place, then nudges the shelf back on screen.
    private func resize(to size: NSSize) {
        var frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        frame.origin.y += frame.height - size.height
        frame.size = size
        if dockEdge == nil, let area = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, area.minX + 8), area.maxX - size.width - 8)
            frame.origin.y = max(frame.origin.y, area.minY + 8)
        }
        guard panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        // The window's built-in resize animation is stiff and relayouts every frame; use one eased group instead.
        panel.animateFrame(to: frame, duration: 0.3)
    }
}

final class ShelfManager {
    private var controllers: [ShelfWindowController] = []

    @discardableResult
    func openShelf(urls: [URL] = [], near point: NSPoint = NSEvent.mouseLocation, autoOpened: Bool = false) -> ShelfWindowController {
        let controller = ShelfWindowController(urls: urls, autoOpened: autoOpened)
        controller.onClosed = { [weak self] c in self?.controllers.removeAll { $0 === c } }
        controllers.append(controller)
        controller.show(near: point, makeKey: !autoOpened)
        return controller
    }

    /// Called when a shake happens mid-drag.
    func openForDrag(at point: NSPoint) {
        guard !controllers.contains(where: { $0.isAutoOpened }) else { return }
        openShelf(near: point, autoOpened: true)
    }

    /// Called when a drag finishes outside Ledge: shelves that opened for it and stayed empty go away.
    /// The global mouse-up can arrive just before the drop reaches a shelf, so wait for a drop to land
    /// and never close a shelf the pointer is still over.
    func closeEmptyAutoShelves() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.controllers
                .filter { $0.isAutoOpened && $0.shelf.items.isEmpty && !$0.containsMouse }
                .forEach { $0.close() }
        }
    }
}
