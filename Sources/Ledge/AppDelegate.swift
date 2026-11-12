import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = ShelfManager()
    private let shake = ShakeDetector()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Staging.purgeOld()
        setUpStatusItem()
        WelcomeWindow.showIfFirstLaunch()

        shake.onShake = { [weak self] point in self?.manager.openForDrag(at: point) }
        shake.onDragEnd = { [weak self] in self?.manager.closeEmptyAutoShelves() }
        if Prefs.shakeEnabled { shake.start() }
        NotificationCenter.default.addObserver(forName: .shakePreferenceChanged, object: nil, queue: .main) { [weak self] _ in
            if Prefs.shakeEnabled { self?.shake.start() } else { self?.shake.stop() }
        }

        let mods = controlKey | optionKey
        HotKey.register(keyCode: kVK_Space, modifiers: mods, id: 1) { [weak self] in self?.manager.openShelf() }
        HotKey.register(keyCode: kVK_ANSI_V, modifiers: mods, id: 2) { [weak self] in self?.newClipboardShelf() }

        // Lets scripts and tests open a shelf: open ledge://new
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Opening Ledge again (from Applications or Spotlight) shows Settings, so the app is reachable
    /// even when a menu bar manager has hidden its icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    // MARK: Status item

    private func setUpStatusItem() {
        // macOS remembers where the icon sat. After a crowded menu bar or a reinstall that position can point
        // off-screen, which hides the icon for good, so drop an implausible saved position.
        let key = "NSStatusItem Preferred Position Item-0"
        let width = NSScreen.screens.map(\.frame.width).max() ?? 1600
        if let saved = UserDefaults.standard.object(forKey: key) as? Double, saved > width || saved < 0 {
            UserDefaults.standard.removeObject(forKey: key)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        statusItem.button?.image = MenuBarIcon.image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addItem(to: menu, "New Shelf", #selector(newShelf), key: " ", mods: [.control, .option])
        addItem(to: menu, "New Shelf from Clipboard", #selector(newClipboardShelfAction), key: "v", mods: [.control, .option])

        let recents = ShelfHistory.recent
        let recentItem = NSMenuItem(title: "Recent Shelves", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (index, urls) in recents.enumerated() {
            let names = urls.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
            let more = urls.count > 2 ? " +\(urls.count - 2)" : ""
            let item = NSMenuItem(title: "\(names)\(more)", action: #selector(restoreShelf(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            sub.addItem(item)
        }
        if recents.isEmpty { sub.addItem(NSMenuItem(title: "None", action: nil, keyEquivalent: "")) }
        recentItem.submenu = sub
        menu.addItem(recentItem)
        addItem(to: menu, "Convert Images…", #selector(openConverter), key: "k")

        menu.addItem(.separator())
        addItem(to: menu, "Settings…", #selector(openSettings), key: ",")
        addItem(to: menu, "Welcome Guide", #selector(openWelcome))
        let shakeItem = addItem(to: menu, "Shake to Open Shelf", #selector(toggleShake))
        shakeItem.state = Prefs.shakeEnabled ? .on : .off
        let loginItem = addItem(to: menu, "Launch at Login", #selector(toggleLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        addItem(to: menu, "Quit Ledge", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                         mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    // MARK: Actions

    @objc private func newShelf() { manager.openShelf() }
    @objc private func newClipboardShelfAction() { newClipboardShelf() }

    private func newClipboardShelf() {
        PasteboardImporter.urls(from: .general) { [weak self] urls in
            guard let self else { return }
            if urls.isEmpty { NSSound.beep() } else { self.manager.openShelf(urls: urls) }
        }
    }

    @objc private func restoreShelf(_ sender: NSMenuItem) {
        let recents = ShelfHistory.recent
        guard recents.indices.contains(sender.tag) else { return }
        manager.openShelf(urls: recents[sender.tag])
    }

    @objc private func openSettings() { SettingsWindow.show() }
    @objc private func openWelcome() { WelcomeWindow.show() }

    /// Converted files land on a new shelf when the converter was opened from the menu bar.
    @MainActor @objc private func openConverter() {
        ConverterWindow.show(urls: []) { [weak self] converted in self?.manager.openShelf(urls: converted) }
    }

    @objc private func toggleShake() {
        Prefs.shakeEnabled.toggle()
        if Prefs.shakeEnabled { shake.start() } else { shake.stop() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @MainActor @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string), url.scheme == "ledge" else { return }
        switch url.host {
        case "clipboard": newClipboardShelf()
        case "convert": openConverter()
        default: manager.openShelf()
        }
    }
}
