import AppKit
import SwiftUI

struct ContentView: View {
    @State private var deviceMonitor = DeviceMonitor()
    @State private var scanAccess = ScanAccess()
    @AppStorage("sidebar_folders") private var storedFolders = ""
    @State private var selection: String?
    @State private var active: DeviceInfo?

    var body: some View {
        NavigationSplitView {
            LocationsSidebar(
                devices: deviceMonitor.devices,
                folders: folderLocations,
                selection: $selection,
                onAddFolder: addFolder,
                onRemoveFolder: removeFolder
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            if let active {
                DiskAnalysisView(
                    rootPath: active.path,
                    rootName: active.name,
                    totalUsedSpace: active.usedBytes
                )
                .id(active.path)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 980, idealWidth: 1280, minHeight: 600, idealHeight: 800)
        .onChange(of: selection) { _, path in
            Task { @MainActor in open(path) }
        }
        .environment(scanAccess)
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label(
                ScanAccess.isSandboxed ? "Choose What to Scan" : "Select a Disk",
                systemImage: "internaldrive"
            )
        } description: {
            Text(ScanAccess.isSandboxed
                ? "Grant OpenDisk access to your startup disk to analyze your whole Mac, or to any folder or volume. Your choice is remembered."
                : "Choose a disk or folder in the sidebar to see what’s taking up space.")
        } actions: {
            Button(ScanAccess.isSandboxed ? "Choose a Folder…" : "Scan Folder…", action: addFolder)
        }
        .navigationTitle("OpenDisk")
    }

    private var savedFolderPaths: [String] {
        storedFolders.split(separator: "\n").map(String.init)
    }

    private var folderLocations: [DeviceInfo] {
        let devicePaths = Set(deviceMonitor.devices.map(\.path))
        if ScanAccess.isSandboxed {
            return scanAccess.grants
                .filter { !devicePaths.contains($0.path) }
                .map { folder(path: $0.path, name: $0.name) }
        }
        return savedFolderPaths
            .filter { !devicePaths.contains($0) && FileManager.default.fileExists(atPath: $0) }
            .map { folder(path: $0, name: nil) }
    }

    private func folder(path: String, name: String?) -> DeviceInfo {
        let last = (path as NSString).lastPathComponent
        return DeviceInfo(
            name: name ?? (last.isEmpty ? path : last),
            icon: "folder",
            path: path,
            totalBytes: 0,
            availableBytes: 0
        )
    }

    private func open(_ path: String?) {
        guard let path else {
            active = nil
            return
        }
        guard path != active?.path else { return }

        if let device = deviceMonitor.devices.first(where: { $0.path == path }) {
            guard ScanAccess.isSandboxed, !scanAccess.isGranted(device.path) else {
                active = device
                return
            }
            guard let opened = requestAccess(to: device) else {
                selection = active?.path
                return
            }
            active = opened
            if opened.path != path { selection = opened.path }
            return
        }

        if let folder = folderLocations.first(where: { $0.path == path }) {
            active = folder
        }
    }

    private func requestAccess(to device: DeviceInfo) -> DeviceInfo? {
        let isBootVolume = device.path == "/"
        let start = isBootVolume
            ? URL(fileURLWithPath: "/")
            : URL(fileURLWithPath: device.path).deletingLastPathComponent()
        guard let grant = scanAccess.requestGrant(
            startingAt: start,
            suggestedName: isBootVolume ? nil : device.name
        ) else { return nil }
        let matched = grant.path == device.path
        return DeviceInfo(
            name: grant.name, icon: device.icon, path: grant.path,
            totalBytes: matched ? device.totalBytes : 0,
            availableBytes: matched ? device.availableBytes : 0
        )
    }

    private func addFolder() {
        if ScanAccess.isSandboxed {
            guard let grant = scanAccess.requestGrant() else { return }
            selection = grant.path
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to analyze"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path
        if !deviceMonitor.devices.contains(where: { $0.path == path }),
           !savedFolderPaths.contains(path) {
            storedFolders = (savedFolderPaths + [path]).joined(separator: "\n")
        }
        selection = path
    }

    private func removeFolder(_ folder: DeviceInfo) {
        if selection == folder.path { selection = nil }
        if ScanAccess.isSandboxed {
            if let grant = scanAccess.grants.first(where: { $0.path == folder.path }) {
                scanAccess.removeGrant(grant)
            }
            return
        }
        storedFolders = savedFolderPaths.filter { $0 != folder.path }.joined(separator: "\n")
    }
}

#Preview {
    ContentView()
}
