import AppKit

struct ShelfItem: Identifiable, Hashable {
    let id = UUID()
    var url: URL

    var name: String { url.lastPathComponent }
    var isMissing: Bool { !FileManager.default.fileExists(atPath: url.path) }
}

/// The ordered list of files on one shelf. Everything that lands on a shelf is a file on disk:
/// text, web links and raw images are written to a staging folder first.
final class Shelf {
    private(set) var items: [ShelfItem] = []
    var onChange: (() -> Void)?
    /// Items whose file changed (renamed), so their tiles must be redrawn even though their identity is the same.
    private var changedIDs: Set<UUID> = []

    func takeChangedIDs() -> Set<UUID> {
        defer { changedIDs.removeAll() }
        return changedIDs
    }

    func item(id: UUID) -> ShelfItem? { items.first { $0.id == id } }

    func add(_ urls: [URL]) {
        var seen = Set(items.map { $0.url.standardizedFileURL.path })
        let fresh = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh.map { ShelfItem(url: $0) })
        onChange?()
    }

    /// Points an item at a new location (after a rename) without changing its place on the shelf.
    func update(id: UUID, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].url = url
        changedIDs.insert(id)
        onChange?()
    }

    func remove(ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        onChange?()
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        onChange?()
    }
}

/// Where Ledge keeps files it creates itself (dropped text, images, archives, promised files).
enum Staging {
    static let root: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Ledge", isDirectory: true)
    }()

    /// A fresh, unique folder so files with the same name never collide.
    static func makeFolder() -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func purgeOld(olderThanDays days: Double = 3) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: folder) }
        }
    }
}

enum ShelfHistory {
    static func record(_ shelf: Shelf) {
        let paths = shelf.items.filter { !$0.isMissing }.map { $0.url.path }
        guard !paths.isEmpty else { return }
        var all = Prefs.recentShelves.filter { $0 != paths }
        all.insert(paths, at: 0)
        Prefs.recentShelves = Array(all.prefix(8))
    }

    /// Recent shelves with files that no longer exist dropped.
    static var recent: [[URL]] {
        Prefs.recentShelves
            .map { $0.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) } }
            .filter { !$0.isEmpty }
    }
}
