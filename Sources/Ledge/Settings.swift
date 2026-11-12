import AppKit
import SwiftUI
import ServiceManagement

extension Notification.Name {
    static let shakePreferenceChanged = Notification.Name("LedgeShakePreferenceChanged")
}

struct SettingsView: View {
    @State private var shake = Prefs.shakeEnabled
    @State private var sensitivity = Prefs.shakeSensitivity
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var quick = Prefs.quickSettings
    @State private var ignored = Prefs.shakeIgnoredApps
    @State private var ignoreFiles = Prefs.shakeIgnoreFilesEnabled
    @State private var ignoredTypes = Prefs.shakeIgnoredTypes
    @State private var ignoreText = Prefs.shakeIgnoreTextEnabled
    @State private var newType = ""
    @State private var actions = Prefs.customActions
    @State private var noAlias = Prefs.noAliasInSameFolder
    @State private var copyOut = Prefs.copyOnDragOut
    @State private var autoClose = Prefs.autoCloseAfterDrag
    @State private var quickReplace = Prefs.quickReplacesSources

    var body: some View {
        Form {
            Section("Shelf") {
                Toggle("Shake to open a shelf while dragging", isOn: $shake)
                    .onChange(of: shake) { value in
                        Prefs.shakeEnabled = value
                        NotificationCenter.default.post(name: .shakePreferenceChanged, object: nil)
                    }
                Picker("Shake sensitivity", selection: $sensitivity) {
                    Text("Low").tag(0)
                    Text("Medium").tag(1)
                    Text("High").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(!shake)
                .onChange(of: sensitivity) { Prefs.shakeSensitivity = $0 }
                Toggle("Copy files instead of moving them when dragging out", isOn: $copyOut)
                    .onChange(of: copyOut) { Prefs.copyOnDragOut = $0 }
                Toggle("Don’t create aliases when dropping in the same folder", isOn: $noAlias)
                    .onChange(of: noAlias) { Prefs.noAliasInSameFolder = $0 }
                Toggle("Close the shelf after files are dragged out", isOn: $autoClose)
                    .onChange(of: autoClose) { Prefs.autoCloseAfterDrag = $0 }
            }
            Section("Apps that never open a shelf") {
                if ignored.isEmpty {
                    Text("Shaking a drag opens a shelf from any app.").foregroundStyle(.secondary)
                }
                ForEach(ignored) { app in
                    HStack {
                        Image(nsImage: Self.icon(for: app.id)).resizable().frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        Button { ignored.removeAll { $0.id == app.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Add App") {
                    ForEach(Self.runningApps().filter { app in !ignored.contains { $0.id == app.id } }) { app in
                        Button(app.name) { ignored.append(app) }
                    }
                    Divider()
                    Button("Choose…") { if let app = Self.chooseApp(), !ignored.contains(where: { $0.id == app.id }) { ignored.append(app) } }
                }
                .disabled(!shake)
            }
            .onChange(of: ignored) { Prefs.shakeIgnoredApps = $0 }
            Section("File types that never open a shelf") {
                Toggle("Ignore dragged text snippets", isOn: $ignoreText)
                    .onChange(of: ignoreText) { Prefs.shakeIgnoreTextEnabled = $0 }
                Toggle("Ignore these file types when shaking", isOn: $ignoreFiles)
                    .onChange(of: ignoreFiles) { Prefs.shakeIgnoreFilesEnabled = $0 }
                if ignoredTypes.isEmpty {
                    Text("Add an extension such as dmg or zip. A drag only skips the shelf when every file in it is on this list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(ignoredTypes, id: \.self) { type in
                    HStack {
                        Text(".\(type)")
                        Spacer()
                        Button { ignoredTypes.removeAll { $0 == type } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Extension, e.g. dmg", text: $newType).onSubmit(addType)
                    Button("Add", action: addType)
                        .disabled(newType.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty)
                }
                .disabled(!ignoreFiles)
            }
            .onChange(of: ignoredTypes) { Prefs.shakeIgnoredTypes = $0 }
            Section("Custom actions") {
                if actions.isEmpty {
                    Text("Add your own actions to the shelf’s Actions menu. A command receives the files as \"$@\".")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($actions) { $action in
                    ActionEditor(action: $action) { actions.removeAll { $0.id == action.id } }
                }
                Button("Add Action") { actions.append(CustomAction(name: "New action")) }
            }
            .onChange(of: actions) { Prefs.customActions = $0 }
            Section("Quick Convert") {
                Picker("Convert to", selection: $quick.format) {
                    Text("Auto (WebP, or PNG for WebP files)").tag(OutputFormat.auto)
                    Text("WebP").tag(OutputFormat.webp)
                    Text("PNG").tag(OutputFormat.png)
                    Text("JPEG").tag(OutputFormat.jpeg)
                    Text("GIF").tag(OutputFormat.gif)
                }
                if quick.format != .png && quick.format != .gif {
                    LabeledContent(quick.lossless && quick.format != .jpeg ? "Effort" : "Quality") {
                        HStack {
                            Slider(value: $quick.quality, in: 0...100)
                            Text("\(Int(quick.quality))").monospacedDigit().frame(width: 30, alignment: .trailing)
                        }
                    }
                    if quick.format != .jpeg { Toggle("Lossless", isOn: $quick.lossless) }
                }
                Toggle("Resize to fit within", isOn: $quick.resize)
                if quick.resize {
                    HStack {
                        TextField("Width", value: $quick.maxWidth, format: .number.grouping(.never)).frame(width: 70)
                        Text("×")
                        TextField("Height", value: $quick.maxHeight, format: .number.grouping(.never)).frame(width: 70)
                        Text("px").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Toggle("Keep EXIF and GPS data", isOn: $quick.keepMetadata)
                Toggle("Keep the color profile", isOn: $quick.keepProfile)
                Toggle("Replace the original on the shelf", isOn: $quickReplace)
                Text("Applies to Quick Convert in the shelf menu. The original files on disk are never changed. Use Convert Images… for watermarks, renaming and more.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: quick) { Prefs.quickSettings = $0 }
            .onChange(of: quickReplace) { Prefs.quickReplacesSources = $0 }
            Section("General") {
                Toggle("Launch at login", isOn: $login)
                    .onChange(of: login) { value in
                        do {
                            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            login = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("Global shortcuts") {
                LabeledContent("New shelf", value: "⌃⌥Space")
                LabeledContent("New shelf from clipboard", value: "⌃⌥V")
            }
            Section {
                VStack(spacing: 2) {
                    CreditView()
                    SupportLinkView()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .tint(Brand.accentColor)
        .buttonStyle(BrandButtonStyle())
        .frame(minWidth: 440, maxWidth: 560, minHeight: 320, maxHeight: .infinity)
    }
}

extension SettingsView {
    static func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return NSImage() }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func addType() {
        let type = newType.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        newType = ""
        if !type.isEmpty, !ignoredTypes.contains(type) { ignoredTypes.append(type) }
    }

    static func runningApps() -> [IgnoredApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { IgnoredApp(id: $0, name: app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func chooseApp() -> IgnoredApp? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        return IgnoredApp(id: id, name: name)
    }
}

enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Ledge Settings"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            // Tall content scrolls; never open taller than the screen.
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - 120
            w.setContentSize(NSSize(width: 460, height: min(680, available)))
            w.contentMinSize = NSSize(width: 440, height: 320)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// One custom action in Settings: name, what it runs, and an optional shortcut.
private struct ActionEditor: View {
    @Binding var action: CustomAction
    let remove: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // One block with one spacing value, so every gap between rows is the same.
            VStack(alignment: .leading, spacing: 12) {
                row("Runs") {
                    Picker("Runs", selection: $action.kind) {
                        Text("Shell command").tag(CustomAction.Kind.shell)
                        Text("Open with app").tag(CustomAction.Kind.app)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if action.kind == .shell {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command")
                        TextField("Command", text: $action.command, prompt: Text("open -a Preview \"$@\""))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    row("Run once for each file") { Toggle("Run once for each file", isOn: $action.perFile).labelsHidden() }
                } else {
                    row("App") {
                        Text(action.command.isEmpty ? "None chosen" : ((action.command as NSString).lastPathComponent as NSString).deletingPathExtension)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseApp() }
                    }
                }
                row("Shortcut") {
                    HStack(spacing: 6) {
                        modifier("⌃", $action.control)
                        modifier("⌥", $action.option)
                        modifier("⇧", $action.shift)
                        modifier("⌘", $action.command_)
                        TextField("Key", text: Binding(get: { action.key }, set: { action.key = String($0.suffix(1)).lowercased() }))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .frame(width: 40)
                    }
                }
                Text("Shortcuts work while a shelf is focused and need at least one modifier.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Delete Action", role: .destructive, action: remove)
            }
            .padding(.vertical, 8)
        } label: {
            TextField("Name", text: $action.name).textFieldStyle(.plain).font(.headline)
        }
    }

    /// A label on the left, its controls on the right.
    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            content()
        }
    }

    private func modifier(_ symbol: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(symbol, isOn: isOn)
            .toggleStyle(.button)
            .frame(width: 34)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { action.command = url.path }
    }
}

/// "Built with ♥ by GaLaXantic Studios". On hover the name changes color and is underlined.
private struct CreditView: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text("Built with").foregroundStyle(.secondary)
            Image(systemName: "heart.fill")
                .foregroundStyle(Color.red)
            Text("by").foregroundStyle(.secondary)
            Text("GaLaXantic Studios")
                .fontWeight(hovering ? .semibold : .regular)
                .foregroundStyle(hovering ? Brand.clayColor : Color.secondary)
                .underline(hovering)
        }
        .font(.caption)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { NSWorkspace.shared.open(URL(string: "https://github.com/NeeL21YT/Ledge")!) }
        .help("https://github.com/NeeL21YT/Ledge")
    }
}

/// Optional "Support Ledge on Ko-fi" link. Quiet by design: it lives only in Settings.
private struct SupportLinkView: View {
    private static let url = "https://ko-fi.com/Q5Q06K4FD"
    @State private var hovering = false

    var body: some View {
        Label("Support Ledge on Ko-fi", systemImage: "cup.and.saucer")
            .font(.caption)
            .foregroundStyle(hovering ? Brand.clayColor : Color.secondary)
            .underline(hovering)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture { NSWorkspace.shared.open(URL(string: Self.url)!) }
            .help(Self.url)
    }
}
