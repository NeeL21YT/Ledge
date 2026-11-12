import AppKit

/// A user-defined action for files on a shelf: a shell command or an app to open them with,
/// optionally with a keyboard shortcut that works while a shelf has focus.
struct CustomAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case shell, app }

    var id = UUID()
    var name = ""
    var kind: Kind = .shell
    /// Shell: the command, which receives the files as "$@" (and "$1", "$2"...). App: path of the app.
    var command = ""
    /// Run once for each file instead of once for all of them.
    var perFile = false
    /// Single character, lowercase. Empty means no shortcut.
    var key = ""
    var command_ = false, option = false, control = false, shift = false

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command_ { flags.insert(.command) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        if shift { flags.insert(.shift) }
        return flags
    }

    var hasShortcut: Bool { !key.isEmpty && !modifierFlags.isEmpty }

    func matches(_ event: NSEvent) -> Bool {
        guard hasShortcut, let typed = event.charactersIgnoringModifiers?.lowercased(), typed == key.lowercased() else { return false }
        return event.modifierFlags.intersection([.command, .option, .control, .shift]) == modifierFlags
    }
}

extension Prefs {
    static var customActions: [CustomAction] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "customActions"),
                  let value = try? JSONDecoder().decode([CustomAction].self, from: data) else { return [] }
            return value
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "customActions") }
    }
}

enum ActionRunner {
    static func run(_ action: CustomAction, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action.kind {
        case .app:
            let app = URL(fileURLWithPath: action.command)
            guard FileManager.default.fileExists(atPath: app.path) else { fail(action, "The app can’t be found."); return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .shell:
            let groups = action.perFile ? urls.map { [$0] } : [urls]
            DispatchQueue.global(qos: .userInitiated).async {
                for group in groups {
                    if let error = execute(action.command, files: group) {
                        DispatchQueue.main.async { fail(action, error) }
                        return
                    }
                }
            }
        }
    }

    /// Runs the command with the files as its arguments. Returns an error message, or nil on success.
    private static func execute(_ command: String, files: [URL]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command, "ledge"] + files.map(\.path)
        task.currentDirectoryURL = files.first?.deletingLastPathComponent()
        let errors = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errors
        do { try task.run() } catch { return error.localizedDescription }
        task.waitUntilExit()
        guard task.terminationStatus != 0 else { return nil }
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? String(format: "The command failed (exit code %d).", task.terminationStatus) : String(text.prefix(400))
    }

    /// Always called on the main thread.
    private static func fail(_ action: CustomAction, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(format: "“%@” didn’t finish", action.name)
        alert.informativeText = message
        alert.runModal()
    }
}
