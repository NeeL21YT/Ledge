import AppKit

/// Public iCloud Drive links, the first cloud service. Files already in iCloud Drive are published as they are;
/// anything else is copied into "Ledge Shares" in iCloud Drive first, so the original is never moved.
enum CloudLinks {
    enum LinkError: LocalizedError {
        case iCloudOff, notUploaded(String), failed(String)

        var errorDescription: String? {
            switch self {
            case .iCloudOff: return "iCloud Drive is turned off or you are not signed in. Turn it on in System Settings > Apple Account > iCloud."
            case .notUploaded(let name): return String(format: "“%@” is still uploading to iCloud. Try again in a moment.", name)
            case .failed(let message): return message
            }
        }
    }

    static var driveFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// Makes a link for every file. Blocks, so call it off the main thread.
    static func makeLinks(for urls: [URL]) throws -> [URL] {
        guard FileManager.default.ubiquityIdentityToken != nil,
              FileManager.default.fileExists(atPath: driveFolder.path) else { throw LinkError.iCloudOff }
        return try urls.map { try link(for: $0) }
    }

    private static func link(for url: URL) throws -> URL {
        let fm = FileManager.default
        var item = url
        if !url.standardizedFileURL.path.hasPrefix(driveFolder.standardizedFileURL.path + "/") {
            let folder = driveFolder.appendingPathComponent("Ledge Shares", isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var destination = folder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n)")
                    .appendingPathExtension(url.pathExtension)
                n += 1
            }
            do { try fm.copyItem(at: url, to: destination) } catch { throw LinkError.failed(error.localizedDescription) }
            item = destination
        }
        // A file has to finish uploading before iCloud will publish it, so retry for a while.
        var lastError: Error?
        for attempt in 0..<20 {
            do {
                var expiration: NSDate?
                return try fm.url(forPublishingUbiquitousItemAt: item, expiration: &expiration)
            } catch {
                lastError = error
                if attempt < 19 { Thread.sleep(forTimeInterval: 3) }
            }
        }
        _ = lastError
        throw LinkError.notUploaded(item.lastPathComponent)
    }
}
