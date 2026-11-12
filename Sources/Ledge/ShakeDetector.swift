import AppKit

/// Watches global mouse events and fires when the user shakes something they are dragging.
/// "Dragging something" means the drag pasteboard changed since the mouse went down, so
/// moving a window or selecting text never triggers it.
final class ShakeDetector {
    var onShake: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    /// Horizontal travel that counts as a stroke, in points.
    private let stroke: CGFloat = 35
    /// Direction changes needed within `window` seconds (4 = about two quick back-and-forths).
    private var reversalsNeeded: Int { [6, 4, 3][min(max(Prefs.shakeSensitivity, 0), 2)] }
    private let window: TimeInterval = 0.9

    private var monitors: [Any] = []
    private var samples: [(time: TimeInterval, x: CGFloat)] = []
    private var pasteboardCountAtMouseDown = 0
    private var fired = false
    /// The drag started in an app on the ignore list.
    private var ignoredSource = false

    private var dragPasteboard: NSPasteboard { NSPasteboard(name: .drag) }

    func start() {
        guard monitors.isEmpty else { return }
        let add = { (mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) in
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { self.monitors.append(m) }
        }
        add(.leftMouseDown) { [weak self] _ in
            guard let self else { return }
            self.samples.removeAll()
            self.fired = false
            self.pasteboardCountAtMouseDown = self.dragPasteboard.changeCount
            let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            self.ignoredSource = source.map { id in Prefs.shakeIgnoredApps.contains { $0.id == id } } ?? false
        }
        add(.leftMouseDragged) { [weak self] event in self?.dragged(event) }
        add(.leftMouseUp) { [weak self] _ in
            guard let self else { return }
            self.samples.removeAll()
            self.fired = false
            self.onDragEnd?()
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        samples.removeAll()
    }

    private func dragged(_ event: NSEvent) {
        guard !fired, !ignoredSource, dragPasteboard.changeCount != pasteboardCountAtMouseDown else { return }
        let now = event.timestamp
        samples.append((now, NSEvent.mouseLocation.x))
        samples.removeAll { now - $0.time > window }

        if reversals(in: samples.map(\.x)) >= reversalsNeeded {
            if draggedFilesAreIgnored() { samples.removeAll(); return }
            fired = true
            samples.removeAll()
            onShake?(NSEvent.mouseLocation)
        }
    }

    /// True when the drag is ignored text, or every dragged file has an extension on the ignore list.
    private func draggedFilesAreIgnored() -> Bool {
        let urls = dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty {
            // Selected text (a snippet) has no file URL.
            return Prefs.shakeIgnoreTextEnabled && dragPasteboard.canReadObject(forClasses: [NSString.self], options: nil)
        }
        guard Prefs.shakeIgnoreFilesEnabled else { return false }
        let types = Set(Prefs.shakeIgnoredTypes)
        guard !types.isEmpty else { return false }
        return urls.allSatisfy { types.contains($0.pathExtension.lowercased()) }
    }

    /// Counts direction changes, ignoring jitter smaller than `stroke`.
    private func reversals(in xs: [CGFloat]) -> Int {
        guard var extreme = xs.first else { return 0 }
        var direction = 0
        var count = 0
        for x in xs.dropFirst() {
            switch direction {
            case 0:
                if abs(x - extreme) >= stroke { direction = x > extreme ? 1 : -1; extreme = x }
            case 1:
                if x > extreme { extreme = x } else if extreme - x >= stroke { direction = -1; extreme = x; count += 1 }
            default:
                if x < extreme { extreme = x } else if x - extreme >= stroke { direction = 1; extreme = x; count += 1 }
            }
        }
        return count
    }
}
