import AppKit
import SwiftUI

/// First-launch guide, also reachable from the menu bar → Welcome Guide.
private struct WelcomeView: View {
    let done: () -> Void

    private let steps: [(icon: String, title: String, text: String)] = [
        ("hand.draw", "Shake while dragging", "Pick up a file, text or link in any app and shake the mouse left and right. A shelf opens under your pointer."),
        ("tray.and.arrow.down", "Drop it on the shelf", "The shelf holds a reference, never a copy. Go anywhere you like, then drag the files back out into any app."),
        ("keyboard", "Open one by hand", "Press ⌃⌥Space for an empty shelf or ⌃⌥V to fill one from the clipboard."),
        ("photo.on.rectangle", "Convert images", "Right-click a shelf item or use the menu bar to convert HEIC, PNG, JPG and more to WebP, in batches, on your Mac."),
        ("slider.horizontal.3", "Make it yours", "In Settings, set shake sensitivity and choose apps or file types that should never open a shelf."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Ledge").font(.largeTitle.bold())
                Text("A tiny shelf for your files, right in the menu bar.").foregroundStyle(.secondary)
            }
            ForEach(steps, id: \.title) { step in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: step.icon).font(.title2).frame(width: 30).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(.headline)
                        Text(step.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Ledge lives in the menu bar. Find this guide again under Welcome Guide.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Open Settings") { SettingsWindow.show() }
                Button("Get Started", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
    }
}

enum WelcomeWindow {
    private static var window: NSWindow?

    /// Shows the guide automatically once, on first launch.
    static func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "welcomeShown") else { return }
        UserDefaults.standard.set(true, forKey: "welcomeShown")
        show()
    }

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView { window?.close() }))
            w.title = "Welcome to Ledge"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
