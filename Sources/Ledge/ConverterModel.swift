import AppKit
import SwiftUI

struct ConvertItem: Identifiable {
    enum Status: Equatable {
        case pending, working
        case done(output: URL, bytes: Int64)
        case failed(String)
    }
    let id = UUID()
    let url: URL
    var status: Status = .pending
    var inputBytes: Int64 { FileInfo.byteCount(url) }
}

/// State behind the converter window: the file list, the settings, presets, the run, and the preview.
@MainActor
final class ConverterModel: ObservableObject {
    @Published var items: [ConvertItem] = []
    @Published var settings: ConvertSettings = Prefs.convertSettings {
        didSet {
            Prefs.convertSettings = settings
            schedulePreview()
        }
    }
    @Published var presets: [ConvertPreset] = Prefs.convertPresets
    @Published private(set) var running = false
    @Published private(set) var summary = ""

    // Preview
    @Published var previewIndex = 0 { didSet { schedulePreview() } }
    @Published private(set) var previewOriginal: NSImage?
    @Published private(set) var previewResult: NSImage?
    @Published private(set) var previewDetails = ""
    @Published private(set) var previewOriginalDetails = ""
    @Published private(set) var previewBusy = false
    var previewActive = false { didSet { if previewActive { schedulePreview() } } }

    /// Receives the converted files (the shelf adds them).
    var deliver: ([URL]) -> Void = { _ in }
    private var previewTask: Task<Void, Never>?

    // MARK: Files

    func add(_ urls: [URL]) {
        guard !running else { return }
        let known = Set(items.map { $0.url.standardizedFileURL.path })
        let fresh = ImageConverter.imageFiles(in: urls).filter { !known.contains($0.standardizedFileURL.path) }
        items.append(contentsOf: fresh.map { ConvertItem(url: $0) })
        summary = ""
        schedulePreview()
    }

    func remove(_ id: UUID) {
        guard !running else { return }
        items.removeAll { $0.id == id }
        previewIndex = min(previewIndex, max(items.count - 1, 0))
        schedulePreview()
    }

    func clear() {
        guard !running else { return }
        items.removeAll()
        summary = ""
        previewIndex = 0
    }

    func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose images or folders of images"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { settings.folderPath = url.path }
    }

    func chooseWatermark() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use as Watermark"
        if panel.runModal() == .OK, let url = panel.url { settings.watermarkPath = url.path }
    }

    // MARK: Presets

    func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save settings as a preset"
        alert.informativeText = "Give this combination of settings a name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Web photos, 1600 px"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = presets.firstIndex(where: { $0.name == name }) {
            presets[index].settings = settings
        } else {
            presets.append(ConvertPreset(name: name, settings: settings))
        }
        Prefs.convertPresets = presets
    }

    func apply(_ preset: ConvertPreset) { settings = preset.settings }

    func delete(_ preset: ConvertPreset) {
        presets.removeAll { $0.id == preset.id }
        Prefs.convertPresets = presets
    }

    // MARK: Running

    var canStart: Bool { !running && !items.isEmpty }

    func start() {
        guard canStart else { return }
        let settings = self.settings
        let urls = items.map(\.url)
        let outputs = ImageConverter.plan(urls, settings: settings, stagingFolder: Staging.makeFolder())
        for i in items.indices { items[i].status = .pending }
        running = true
        summary = "Converting…"

        Task.detached(priority: .userInitiated) { [weak self] in
            let watermark = ImageConverter.loadWatermark(settings)
            let width = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
            await withTaskGroup(of: (Int, Result<Int64, Error>).self) { group in
                var next = 0
                func launch() {
                    guard next < urls.count else { return }
                    let i = next
                    next += 1
                    group.addTask(priority: .userInitiated) {
                        await self?.markWorking(i)
                        let result = Result { try ImageConverter.convert(urls[i], to: outputs[i], settings: settings, watermark: watermark) }
                        return (i, result)
                    }
                }
                for _ in 0..<width { launch() }
                while let (i, result) = await group.next() {
                    await self?.record(i, result: result, output: outputs[i])
                    launch()
                }
            }
            await self?.finish()
        }
    }

    private func markWorking(_ index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].status = .working
    }

    private func record(_ index: Int, result: Result<Int64, Error>, output: URL) {
        guard items.indices.contains(index) else { return }
        switch result {
        case .success(let bytes): items[index].status = .done(output: output, bytes: bytes)
        case .failure(let error): items[index].status = .failed(error.localizedDescription)
        }
    }

    private func finish() {
        running = false
        var produced: [URL] = []
        var before: Int64 = 0, after: Int64 = 0, failed = 0
        for item in items {
            switch item.status {
            case .done(let output, let bytes): produced.append(output); before += item.inputBytes; after += bytes
            case .failed: failed += 1
            default: break
            }
        }
        var parts = [String(format: "%d converted", produced.count)]
        if before > 0 {
            let saved = Int((1 - Double(after) / Double(before)) * 100)
            parts.append(saved >= 0 ? String(format: "%@ saved (%d%%)", FileInfo.formatted(bytes: before - after), saved)
                                    : String(format: "%@ larger", FileInfo.formatted(bytes: after - before)))
        }
        if failed > 0 { parts.append(String(format: "%d failed", failed)) }
        summary = parts.joined(separator: " • ")
        if !produced.isEmpty { deliver(produced) }
    }

    var producedFiles: [URL] {
        items.compactMap { if case .done(let url, _) = $0.status { return url } else { return nil } }
    }

    func revealResults() { NSWorkspace.shared.activateFileViewerSelecting(producedFiles) }

    // MARK: Preview

    private func schedulePreview() {
        guard previewActive else { return }
        previewTask?.cancel()
        guard items.indices.contains(previewIndex) else {
            previewOriginal = nil; previewResult = nil; previewDetails = ""; previewOriginalDetails = ""
            return
        }
        let url = items[previewIndex].url
        let settings = self.settings
        previewBusy = true
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000) // wait for sliders to settle
            if Task.isCancelled { return }
            let result: (NSImage?, NSImage?, String, String) = await Task.detached(priority: .userInitiated) {
                let original = NSImage(contentsOf: url)
                let inputBytes = FileInfo.byteCount(url)
                let size = FileInfo.pixelSize(url).map { "\(Int($0.width))x\(Int($0.height))" } ?? ""
                let originalDetails = [url.pathExtension.uppercased(), FileInfo.formatted(bytes: inputBytes), size]
                    .filter { !$0.isEmpty }.joined(separator: " • ")
                guard let encoded = try? ImageConverter.encode(url, settings: settings, watermark: ImageConverter.loadWatermark(settings)) else {
                    return (original, nil, originalDetails, "Can’t convert this image")
                }
                let bytes = Int64(encoded.data.count)
                var details = [encoded.fileExtension.uppercased(), FileInfo.formatted(bytes: bytes), "\(encoded.width)x\(encoded.height)"]
                if inputBytes > 0 {
                    let change = Int((1 - Double(bytes) / Double(inputBytes)) * 100)
                    details.append(change >= 0 ? String(format: "%d%% smaller", change) : String(format: "%d%% larger", -change))
                }
                return (original, NSImage(data: encoded.data), originalDetails, details.joined(separator: " • "))
            }.value
            if Task.isCancelled { return }
            guard let self else { return }
            self.previewOriginal = result.0
            self.previewResult = result.1
            self.previewOriginalDetails = result.2
            self.previewDetails = result.3
            self.previewBusy = false
        }
    }
}
