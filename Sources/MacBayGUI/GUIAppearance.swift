import AppKit
import SwiftUI

extension View {
    func guiButton(prominent: Bool = false) -> some View {
        modifier(GUIStandardButton(prominent: prominent))
    }
}

private struct GUIStandardButton: ViewModifier {
    let prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) }
        else { content.buttonStyle(.bordered) }
    }
}

/// Apply the user's appearance choice without adding a second material behind the window.
struct GUIWindowAppearance: NSViewRepresentable {
    let appearance: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let name: NSAppearance.Name? = appearance == "light" ? .aqua : appearance == "dark" ? .darkAqua : nil
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, window.appearance?.name != name else { return }
            window.appearance = name.flatMap(NSAppearance.init(named:))
        }
    }
}
