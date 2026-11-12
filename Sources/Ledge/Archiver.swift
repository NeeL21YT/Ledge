import Foundation

enum Archiver {
    /// Zips the given files into one archive in the staging folder. Runs off the main thread.
    static func zip(_ urls: [URL], completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = makeArchive(urls)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func makeArchive(_ urls: [URL]) -> URL? {
        let fm = FileManager.default
        let work = Staging.makeFolder()
        let content = work.appendingPathComponent("content", isDirectory: true)
        try? fm.createDirectory(at: content, withIntermediateDirectories: true)

        // Symlinks keep big files in place and let us rename on collision.
        var names: [String] = []
        for url in urls {
            var name = url.lastPathComponent
            var n = 2
            while names.contains(name) {
                name = "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)"
                n += 1
            }
            names.append(name)
            try? fm.createSymbolicLink(at: content.appendingPathComponent(name), withDestinationURL: url)
        }

        let archiveName = urls.count == 1 ? "\(urls[0].lastPathComponent).zip" : "Archive.zip"
        let out = Staging.makeFolder().appendingPathComponent(archiveName)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = content
        task.arguments = ["-qr", out.path] + names
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        try? fm.removeItem(at: work)
        return task.terminationStatus == 0 && fm.fileExists(atPath: out.path) ? out : nil
    }
}
