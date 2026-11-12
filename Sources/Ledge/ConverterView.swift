import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConverterView: View {
    @ObservedObject var model: ConverterModel
    @State private var dropTargeted = false

    private var s: Binding<ConvertSettings> { $model.settings }
    private var isGIF: Bool { model.settings.format == .gif }
    private var isWebPOutput: Bool { model.settings.format == .webp || model.settings.format == .auto }

    var body: some View {
        VStack(spacing: 0) {
            fileList
            Divider()
            Form {
                outputSection
                if model.settings.format != .png && model.settings.format != .gif { qualitySection }
                sizeSection
                filesSection
                namingSection
                watermarkSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 560)
        .tint(Brand.accentColor)
        .buttonStyle(BrandButtonStyle())
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.add([url]) } }
                }
            }
            return true
        }
    }

    // MARK: Files

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.items.isEmpty ? "Images" : String(format: (model.items.count == 1 ? "%d image" : "%d images"), model.items.count))
                    .font(.headline)
                Spacer()
                Button("Add…") { model.chooseFiles() }.disabled(model.running)
                Button("Clear") { model.clear() }.disabled(model.running || model.items.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Drop images or folders here").foregroundStyle(.secondary)
                    Text("JPG, PNG, HEIC, GIF, TIFF, BMP, PSD, DNG, AVIF, SVG, PDF, WebP and more")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                List {
                    ForEach(model.items) { item in
                        ItemRow(item: item, remove: { model.remove(item.id) }, canRemove: !model.running)
                    }
                }
                .listStyle(.plain)
                .frame(height: 140)
            }
        }
        .background(dropTargeted ? Brand.accentColor.opacity(0.14) : Color.clear)
    }

    // MARK: Settings

    private var outputSection: some View {
        Section("Output") {
            Picker("Format", selection: s.format) {
                ForEach(OutputFormat.allCases) { Text($0.title).tag($0) }
            }
            Picker("Save to", selection: s.destination) {
                ForEach(Destination.allCases) { Text($0.title).tag($0) }
            }
            if model.settings.destination == .folder {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.settings.folderPath.isEmpty ? "None chosen" : (model.settings.folderPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseOutputFolder() }
                    }
                }
            }
            Text("Converted files are also added to the shelf. EXIF and GPS data are removed unless you keep them below.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var qualitySection: some View {
        Section("WebP / JPEG quality") {
            LabeledContent(model.settings.lossless && isWebPOutput ? "Effort" : "Quality") {
                HStack {
                    Slider(value: s.quality, in: 0...100)
                    Text("\(Int(model.settings.quality))").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
            if isWebPOutput {
                Toggle("Lossless", isOn: s.lossless)
                Picker("Preset", selection: s.preset) {
                    Text("Default").tag(0); Text("Picture").tag(1); Text("Photo").tag(2)
                    Text("Drawing").tag(3); Text("Icon").tag(4); Text("Text").tag(5)
                }
                Picker("Method", selection: s.method) {
                    ForEach(0...6, id: \.self) { Text($0 == 0 ? "0 (fastest)" : $0 == 6 ? "6 (smallest)" : "\($0)").tag($0) }
                }
                Toggle("Sharp YUV (crisper color edges, slower)", isOn: s.sharpYUV)
            }
        }
    }

    private var sizeSection: some View {
        Section("Size") {
            Toggle("Resize to fit within", isOn: s.resize)
            if model.settings.resize {
                HStack {
                    TextField("Width", value: s.maxWidth, format: .number.grouping(.never)).frame(width: 70)
                    Text("×")
                    TextField("Height", value: s.maxHeight, format: .number.grouping(.never)).frame(width: 70)
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                }
                Text("The aspect ratio is kept and small images are never enlarged. Use 0 for no limit on one side.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var filesSection: some View {
        Section("Metadata and files") {
            Toggle("Keep EXIF and GPS data", isOn: s.keepMetadata)
            Toggle("Keep the color profile", isOn: s.keepProfile)
            Toggle("Keep the original extension (photo.jpg.webp)", isOn: s.keepOriginalExtension)
            Toggle("Keep the original file dates", isOn: s.keepDates)
        }
    }

    private var namingSection: some View {
        Section("File names") {
            Picker("Rename", selection: s.rename) {
                ForEach(RenameMode.allCases) { Text($0.title).tag($0) }
            }
            switch model.settings.rename {
            case .keep: EmptyView()
            case .prefix: TextField("Prefix", text: s.renameText)
            case .suffix: TextField("Suffix", text: s.renameText)
            case .replace:
                TextField("Find", text: s.renameFind)
                TextField("Replace with", text: s.renameText)
            case .numbering:
                TextField("Name before the number", text: s.renameText)
                Stepper("Start at \(model.settings.numberingStart)", value: s.numberingStart, in: 0...99999)
            }
            if model.settings.rename != .keep, let first = model.items.first {
                LabeledContent("Example") {
                    Text(ImageConverter.outputName(for: first.url, index: 0, settings: model.settings) + "." + ImageConverter.resolvedFormat(model.settings, for: first.url).fileExtension)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var watermarkSection: some View {
        Section("Watermark") {
            Toggle("Add a watermark", isOn: s.watermark)
            if model.settings.watermark {
                Picker("Type", selection: s.watermarkKind) {
                    Text("Image (logo)").tag(WatermarkKind.image)
                    Text("Text").tag(WatermarkKind.text)
                }
                .pickerStyle(.segmented)
                if model.settings.watermarkKind == .image {
                    LabeledContent("Logo") {
                        HStack {
                            Text(model.settings.watermarkPath.isEmpty ? "None chosen" : (model.settings.watermarkPath as NSString).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Choose…") { model.chooseWatermark() }
                        }
                    }
                } else {
                    TextField("Text", text: s.watermarkText)
                }
                Picker("Position", selection: s.watermarkPosition) {
                    ForEach(WatermarkPosition.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: s.watermarkScale, in: 5...80)
                        Text("\(Int(model.settings.watermarkScale))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: s.watermarkOpacity, in: 10...100)
                        Text("\(Int(model.settings.watermarkOpacity))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Save Current Settings…") { model.savePreset() }
                if !model.presets.isEmpty {
                    Divider()
                    ForEach(model.presets) { preset in Button(preset.name) { model.apply(preset) } }
                    Divider()
                    Menu("Delete Preset") {
                        ForEach(model.presets) { preset in Button(preset.name) { model.delete(preset) } }
                    }
                }
                Divider()
                Button("Reset to Defaults") { model.settings = ConvertSettings() }
            } label: { Text("Presets") }
            .menuStyle(.borderlessButton).fixedSize()

            Button("Preview…") { PreviewWindow.show(model: model) }.disabled(model.items.isEmpty)

            if model.running { ProgressView().controlSize(.small) }
            Text(model.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !model.producedFiles.isEmpty && !model.running {
                Button("Show in Finder") { model.revealResults() }
            }
            Button("Start") { model.start() }
                .buttonStyle(BrandButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct ItemRow: View {
    let item: ConvertItem
    let remove: () -> Void
    let canRemove: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 20, height: 20)
            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            status
            if canRemove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Remove from this list")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .pending:
            Text(FileInfo.formatted(bytes: item.inputBytes)).font(.caption).foregroundStyle(.secondary)
        case .working:
            ProgressView().controlSize(.mini)
        case .done(_, let bytes):
            Text("\(FileInfo.formatted(bytes: item.inputBytes)) → \(FileInfo.formatted(bytes: bytes))")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
        }
    }
}

// MARK: Preview window

struct PreviewView: View {
    @ObservedObject var model: ConverterModel

    var body: some View {
        VStack(spacing: 12) {
            if model.items.count > 1 {
                Picker("Image", selection: $model.previewIndex) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { Text($1.url.lastPathComponent).tag($0) }
                }
            }
            HStack(spacing: 12) {
                pane(title: "Before", image: model.previewOriginal, details: model.previewOriginalDetails)
                pane(title: "After", image: model.previewResult, details: model.previewDetails)
            }
            Text("The preview uses your current settings. Change them in the converter window and it updates.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .tint(Brand.accentColor)
        .frame(minWidth: 720, minHeight: 440)
        .onAppear { model.previewActive = true }
        .onDisappear { model.previewActive = false }
    }

    private func pane(title: String, image: NSImage?, details: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(6)
                } else if model.previewBusy {
                    ProgressView()
                }
                if model.previewBusy && image != nil {
                    VStack { HStack { Spacer(); ProgressView().controlSize(.small).padding(8) }; Spacer() }
                }
            }
            Text(details.isEmpty ? " " : details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

enum PreviewWindow {
    private static var window: NSWindow?

    static func show(model: ConverterModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PreviewView(model: model)))
            w.title = "Preview"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 820, height: 520))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: Converter window

enum ConverterWindow {
    private static var window: NSWindow?
    private static var model: ConverterModel?

    /// Opens the converter with `urls` already in the list. `deliver` receives the converted files.
    @MainActor
    static func show(urls: [URL], deliver: @escaping ([URL]) -> Void) {
        if model == nil { model = ConverterModel() }
        guard let model else { return }
        model.deliver = deliver
        model.add(urls)
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ConverterView(model: model)))
            w.title = "Convert Images"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 580, height: 780))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
