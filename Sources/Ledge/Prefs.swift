import AppKit

enum Prefs {
    private static let defaults = UserDefaults.standard

    static var shakeEnabled: Bool {
        get { defaults.object(forKey: "shakeEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shakeEnabled") }
    }

    /// Dragging files out into the folder they already live in copies them instead of making an alias.
    static var noAliasInSameFolder: Bool {
        get { defaults.object(forKey: "noAliasInSameFolder") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "noAliasInSameFolder") }
    }

    /// Close the shelf once its files have been dragged out to another app or folder.
    static var autoCloseAfterDrag: Bool {
        get { defaults.bool(forKey: "autoCloseAfterDrag") }
        set { defaults.set(newValue, forKey: "autoCloseAfterDrag") }
    }

    /// Dragging files out of a shelf copies them instead of moving them. Off by default, so a drag moves.
    static var copyOnDragOut: Bool {
        get { defaults.bool(forKey: "copyOnDragOut") }
        set { defaults.set(newValue, forKey: "copyOnDragOut") }
    }

    /// Operations offered to other apps when files are dragged out of a shelf.
    static var outsideDragMask: NSDragOperation {
        if copyOnDragOut { return .copy }
        return noAliasInSameFolder ? [.move, .copy] : [.move, .copy, .generic, .link]
    }

    /// Expanded shelf shows a list instead of a grid.
    static var listLayout: Bool {
        get { defaults.bool(forKey: "listLayout") }
        set { defaults.set(newValue, forKey: "listLayout") }
    }

    /// 0 = low, 1 = medium, 2 = high.
    static var shakeSensitivity: Int {
        get { defaults.object(forKey: "shakeSensitivity") as? Int ?? 1 }
        set { defaults.set(newValue, forKey: "shakeSensitivity") }
    }

    /// Paths of the most recently closed non-empty shelves, newest first.
    static var recentShelves: [[String]] {
        get { defaults.array(forKey: "recentShelves") as? [[String]] ?? [] }
        set { defaults.set(newValue, forKey: "recentShelves") }
    }

    /// Apps whose drags never open a shelf: bundle identifier and display name.
    static var shakeIgnoredApps: [IgnoredApp] {
        get {
            guard let data = defaults.data(forKey: "shakeIgnoredApps"),
                  let value = try? JSONDecoder().decode([IgnoredApp].self, from: data) else { return [] }
            return value
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "shakeIgnoredApps") }
    }
}

extension Prefs {
    /// Turns the file-type ignore list on or off without clearing it.
    static var shakeIgnoreFilesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "shakeIgnoreFilesEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "shakeIgnoreFilesEnabled") }
    }

    /// Skips the shelf when the drag is selected text rather than files. Off by default.
    static var shakeIgnoreTextEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "shakeIgnoreTextEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "shakeIgnoreTextEnabled") }
    }

    /// File extensions (lowercase, no dot) whose drags never open a shelf.
    static var shakeIgnoredTypes: [String] {
        get { UserDefaults.standard.stringArray(forKey: "shakeIgnoredTypes") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "shakeIgnoredTypes") }
    }
}

struct IgnoredApp: Codable, Identifiable, Hashable {
    var id: String // bundle identifier
    var name: String
}
