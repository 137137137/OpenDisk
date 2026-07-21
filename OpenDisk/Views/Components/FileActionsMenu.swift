import SwiftUI
import AppKit

/// The shared right-click menu for a single real file/folder: collect it for
/// deletion (blocked for macOS-protected paths), reveal it in Finder, or copy
/// its path. Used by both the results-list rows and the chart rings so the two
/// context menus stay in lockstep.
struct FileActionsMenu: View {
    let file: CollectedFile
    let collector: Collector

    var body: some View {
        Button {
            collector.add(file)
        } label: {
            Label("Add to Collector", systemImage: "trash")
        }
        // macOS-critical locations can't be deleted.
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
