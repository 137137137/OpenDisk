import SwiftUI
import AppKit

struct FileActionsMenu: View {
    let file: CollectedFile
    let collector: Collector
    @Environment(\.sidebarFolders) private var sidebarFolders

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

        if file.isDirectory, !file.path.hasPrefix("::") {
            if sidebarFolders.contains(file.path) {
                Button {
                    sidebarFolders.remove(file.path)
                } label: {
                    Label("Remove from Sidebar", systemImage: "sidebar.left")
                }
            } else {
                Button {
                    sidebarFolders.add(file.path, file.size)
                } label: {
                    Label("Add to Sidebar", systemImage: "sidebar.left")
                }
            }
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
    }
}
