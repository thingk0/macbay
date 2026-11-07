import AppKit
import SwiftUI

struct GUISearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    var placeholder = "Search apps"

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if focusRequest > context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: GUISearchField
        var lastFocusRequest = 0
        init(_ parent: GUISearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }
    }
}
