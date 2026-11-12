import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum Thumbnails {
    private final class Entry {
        let image: NSImage, points: CGFloat
        init(_ image: NSImage, _ points: CGFloat) { self.image = image; self.points = points }
    }
    private static let cache = NSCache<NSString, Entry>()

    /// Calls `completion` right away with the best image already known (a cached thumbnail, else the file's icon),
    /// then again with a real thumbnail when one is ready. A cached thumbnail that is big enough ends it there,
    /// so a tile never flashes a generic icon before its picture.
    static func load(_ url: URL, points: CGFloat, completion: @escaping (NSImage) -> Void) {
        let key = url.path as NSString
        let hit = cache.object(forKey: key)
        if let hit, hit.points >= points {
            completion(hit.image)
            return
        }
        completion(hit?.image ?? NSWorkspace.shared.icon(forFile: url.path))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: points, height: points), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            DispatchQueue.main.async {
                cache.setObject(Entry(image, points), forKey: key)
                completion(image)
            }
        }
    }

    /// Starts thumbnail generation ahead of time so the expanded shelf already has its pictures.
    static func prefetch(_ urls: [URL], points: CGFloat = 110) {
        for url in urls where cache.object(forKey: url.path as NSString) == nil { load(url, points: points) { _ in } }
    }
}

/// Human-readable facts about shelf files: "1.4 MB • 1254x1254", "1 Image".
enum FileInfo {
    private static func values(_ url: URL) -> URLResourceValues? {
        try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey])
    }

    static func isDirectory(_ url: URL) -> Bool { values(url)?.isDirectory == true }
    static func isImage(_ url: URL) -> Bool { values(url)?.contentType?.conforms(to: .image) == true }
    static func byteCount(_ url: URL) -> Int64 { Int64(values(url)?.fileSize ?? 0) }

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }

    static func formatted(bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private static let subtitles = NSCache<NSString, NSString>()

    /// Reading pixel sizes touches the file, so results are remembered (keyed by size and date, so edits refresh them).
    static func subtitle(for url: URL) -> String {
        if isDirectory(url) { return "Folder" }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path)|\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = subtitles.object(forKey: stamp) { return cached as String }
        var parts = [formatted(bytes: byteCount(url))]
        if isImage(url), let size = pixelSize(url) { parts.append("\(Int(size.width))x\(Int(size.height))") }
        let result = parts.joined(separator: " • ")
        subtitles.setObject(result as NSString, forKey: stamp)
        return result
    }

    /// Title and subtitle for the expanded header, e.g. ("2 Images", "3.1 MB").
    static func summary(of items: [ShelfItem]) -> (title: String, subtitle: String) {
        let urls = items.map(\.url)
        let n = urls.count
        let key: String
        if n > 0, urls.allSatisfy(isImage) { key = n == 1 ? "%d Image" : "%d Images" }
        else if n > 0, urls.allSatisfy(isDirectory) { key = n == 1 ? "%d Folder" : "%d Folders" }
        else { key = n == 1 ? "%d File" : "%d Files" }
        let total = urls.reduce(Int64(0)) { $0 + byteCount($1) }
        return (n == 0 ? "Shelf" : String(format: key, n), n == 0 ? "" : formatted(bytes: total))
    }
}
