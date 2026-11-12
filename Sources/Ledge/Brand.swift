import AppKit
import SwiftUI

/// Ledge's colors, taken from the app icon: sage green and warm clay. Used instead of the system accent
/// color so the app looks the same whatever accent the user picked.
enum Brand {
    /// Sage green, light enough to read on dark surfaces. Toggles, sliders, selection, drop outline.
    static let accent = NSColor(srgbRed: 0.50, green: 0.66, blue: 0.56, alpha: 1)
    /// Warm clay, for hover states and small highlights.
    static let clay = NSColor(srgbRed: 0.85, green: 0.68, blue: 0.55, alpha: 1)

    static var accentColor: Color { Color(nsColor: accent) }
    static var clayColor: Color { Color(nsColor: clay) }
}

/// Buttons in Ledge's windows: a soft fill that lights up in the brand color on hover and shrinks a little when pressed.
struct BrandButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, prominent: prominent)
    }

    fileprivate struct BrandButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill)
                )
                .scaleEffect(configuration.isPressed ? 0.95 : (hovering && enabled ? 1.03 : 1))
                .opacity(enabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.14), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if prominent { return hovering && enabled ? Brand.clayColor : Brand.accentColor }
            if configuration.isPressed { return Brand.accentColor.opacity(0.5) }
            return hovering && enabled ? Brand.accentColor.opacity(0.38) : Color.white.opacity(0.1)
        }
    }
}
