import SwiftUI
import AppKit

struct FileActionsMenu: View {
    let file: CollectedFile
    let collector: Collector

    var body: some View {
        Button {
            collector.add(file)
        } label: {
            Label("Add to Collector", systemImage: "trash")
        }
        .disabled(ProtectedPaths.isProtected(file.path))

        Divider()

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
    }
}
