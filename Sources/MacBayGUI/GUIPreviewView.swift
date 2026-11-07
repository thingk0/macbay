import SwiftUI

struct GUIPreviewView: View {
    let preview: GUIPreview
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Preview", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
            GUIPageHeading(title: preview.title, subtitle: preview.subtitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GUIPanel {
                        Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 14) {
                            ForEach(preview.rows) { row in
                                GridRow {
                                    Text(row.label).foregroundStyle(.secondary).frame(width: 135, alignment: .leading)
                                    Text(row.value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                }.font(.callout)
                            }
                        }
                    }
                    if preview.needsReview {
                        Label("Review the compatibility and space warnings below.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    ForEach(Array(preview.messages.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(maxHeight: 420)
            Divider()
            HStack {
                Label("Preview only. No files were changed.", systemImage: "eye")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: dismiss).guiButton(prominent: true).controlSize(.regular).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 640).fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: dismiss)
    }
}
