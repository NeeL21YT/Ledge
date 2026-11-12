import AppKit

/// Renames files on a shelf, on disk. One file gets a plain name field; several get a rule
/// (prefix, suffix, find and replace, or numbering) with a live preview.
enum Renamer {
    enum Mode: Int, CaseIterable {
        case prefix, suffix, replace, numbering

        var title: String {
            switch self {
            case .prefix: return "Add prefix"
            case .suffix: return "Add suffix"
            case .replace: return "Find and replace"
            case .numbering: return "Numbering"
            }
        }
    }

    /// The new file name for `url`; the extension is always kept.
    static func newName(for url: URL, index: Int, mode: Mode, text: String, find: String) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let name: String
        switch mode {
        case .prefix: name = text + base
        case .suffix: name = base + text
        case .replace: name = find.isEmpty ? base : base.replacingOccurrences(of: find, with: text)
        case .numbering: name = text + String(format: "%03d", index + 1)
        }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return ext.isEmpty ? safe : "\(safe).\(ext)"
    }

    @MainActor
    static func run(items: [ShelfItem], shelf: Shelf) {
        guard !items.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = items.count == 1 ? "Rename file" : String(format: "Rename %d files", items.count)
        alert.informativeText = "This renames the files on disk."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let form = RenameForm(items: items)
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = form.primaryField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let plan = zip(items, form.names()).map { (item: $0, name: $1) }
        let fm = FileManager.default
        var targets: [(ShelfItem, URL)] = []
        var problems: [String] = []
        var seen = Set<String>()
        for (item, name) in plan {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains("/") else { problems.append(String(format: "“%@” is not a valid name.", name)); continue }
            let destination = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
            if destination.path == item.url.path { continue }
            let key = destination.path.lowercased()
            // A case-only change on a case-insensitive disk points at the same file; anything else must not exist yet.
            let sameFile = destination.path.lowercased() == item.url.path.lowercased()
            if !seen.insert(key).inserted || (fm.fileExists(atPath: destination.path) && !sameFile) {
                problems.append(String(format: "“%@” already exists.", trimmed))
                continue
            }
            targets.append((item, destination))
        }
        if !problems.isEmpty {
            let failure = NSAlert()
            failure.messageText = "Nothing was renamed"
            failure.informativeText = problems.prefix(6).joined(separator: "\n")
            failure.runModal()
            return
        }
        for (item, destination) in targets {
            do {
                try fm.moveItem(at: item.url, to: destination)
                shelf.update(id: item.id, to: destination)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
        }
    }
}

/// The dialog's contents. Builds the right controls for one file or many and previews the first result.
private final class RenameForm: NSObject, NSTextFieldDelegate {
    let items: [ShelfItem]
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
    let primaryField = NSTextField()
    private let findField = NSTextField()
    private let modePopup = NSPopUpButton()
    private let preview = NSTextField(labelWithString: "")
    private var single: Bool { items.count == 1 }

    init(items: [ShelfItem]) {
        self.items = items
        super.init()
        primaryField.delegate = self
        findField.delegate = self
        preview.textColor = .secondaryLabelColor
        preview.font = .systemFont(ofSize: 11)
        preview.lineBreakMode = .byTruncatingMiddle

        if single {
            primaryField.stringValue = items[0].name
            layout([primaryField])
            // Select the name, not the extension.
            DispatchQueue.main.async { [primaryField, items] in
                primaryField.currentEditor()?.selectedRange = NSRange(location: 0, length: (items[0].url.deletingPathExtension().lastPathComponent as NSString).length)
            }
        } else {
            Mode.allCases.forEach { modePopup.addItem(withTitle: $0.title) }
            modePopup.target = self
            modePopup.action = #selector(modeChanged)
            primaryField.placeholderString = "Text"
            findField.placeholderString = "Find"
            layout([modePopup, findField, primaryField, preview])
            modeChanged()
        }
    }

    private typealias Mode = Renamer.Mode

    private func layout(_ views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            view.widthAnchor.constraint(equalToConstant: 340),
        ])
        for v in views where v is NSTextField || v is NSPopUpButton {
            v.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        view.layoutSubtreeIfNeeded()
        view.frame.size.height = stack.fittingSize.height
    }

    private var mode: Mode { Mode(rawValue: modePopup.indexOfSelectedItem) ?? .prefix }

    @objc private func modeChanged() {
        findField.isHidden = mode != .replace
        primaryField.placeholderString = mode == .replace ? "Replace with" : mode == .numbering ? "Name before the number" : "Text"
        updatePreview()
    }

    func controlTextDidChange(_ obj: Notification) { updatePreview() }

    private func updatePreview() {
        guard !single else { return }
        preview.stringValue = names().first.map { "\(items[0].name)  →  \($0)" } ?? ""
    }

    /// The new file name for each item, in order.
    func names() -> [String] {
        if single { return [primaryField.stringValue] }
        return items.enumerated().map { index, item in
            Renamer.newName(for: item.url, index: index, mode: mode, text: primaryField.stringValue, find: findField.stringValue)
        }
    }
}
