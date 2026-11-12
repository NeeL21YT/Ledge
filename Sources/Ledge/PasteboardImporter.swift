import AppKit

/// Turns whatever is on a pasteboard (a drag or the clipboard) into file URLs for a shelf.
/// Priority: real files, file promises (Mail, Photos), images, web links, plain text.
enum PasteboardImporter {
    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()

    /// Must be called synchronously from the drop handler; `completion` runs on the main queue.
    static func urls(from pb: NSPasteboard, completion: @escaping ([URL]) -> Void) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let files = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !files.isEmpty {
            completion(files.map { URL(fileURLWithPath: $0.path) })
            return
        }

        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let folder = Staging.makeFolder()
            let group = DispatchGroup()
            var received: [URL] = []
            for receiver in receivers {
                group.enter()
                receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { url, error in
                    if error == nil { received.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(received) }
            return
        }

        if let url = imageFile(from: pb) ?? webLinkFile(from: pb) ?? textFile(from: pb) {
            completion([url])
            return
        }
        completion([])
    }

    private static func imageFile(from pb: NSPasteboard) -> URL? {
        let data = pb.data(forType: .png) ?? pb.data(forType: .tiff)
        guard let data, let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        return write(png, named: "Image \(stamp).png")
    }

    private static func webLinkFile(from pb: NSPasteboard) -> URL? {
        guard let link = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
              let host = link.host, link.scheme?.hasPrefix("http") == true,
              let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString], format: .xml, options: 0)
        else { return nil }
        return write(data, named: "\(host).webloc")
    }

    private static func textFile(from pb: NSPasteboard) -> URL? {
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        let firstLine = text.components(separatedBy: .newlines).first ?? "Text"
        return write(data, named: "\(firstLine.prefix(40)).txt")
    }

    private static func write(_ data: Data, named name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = Staging.makeFolder().appendingPathComponent(safe)
        do { try data.write(to: url); return url } catch { return nil }
    }
}
