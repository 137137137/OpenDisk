import AppKit
import SwiftUI

struct ContentView: View {
    @State private var deviceMonitor = DeviceMonitor()
    @State private var scanAccess = ScanAccess()
    @AppStorage("sidebar_folders") private var storedFolders = ""
    @State private var selection: String?
    @State private var active: DeviceInfo?
    @State private var isChoosingFolder = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var didSelectInitialLocation = false
    @AppStorage("last_location") private var lastLocation = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
                    totalUsedSpace: active.usedBytes,
                    onScanFinished: {
                        withAnimation { columnVisibility = .detailOnly }
                    }
                )
                .id(active.path)
            } else {
                placeholder
            }
        }
        .frame(
            minWidth: 980, idealWidth: 1280, maxWidth: .infinity,
            minHeight: 600, idealHeight: 800, maxHeight: .infinity
        )
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { addFolder(at: url) }
        }
        .fileDialogConfirmationLabel("Scan")
        .fileDialogMessage("Choose a folder to analyze")
        .onChange(of: selection) { _, path in
            Task { @MainActor in open(path) }
        }
        .onChange(of: active?.path) { _, path in
            if let path { lastLocation = path }
        }
        .onChange(of: deviceMonitor.devices, initial: true) {
            selectInitialLocation()
        }
        .environment(scanAccess)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Text("No Location Selected")
                .font(.title3)
                .foregroundStyle(.tertiary)
            if ScanAccess.isSandboxed && scanAccess.grants.isEmpty {
                Text("Choose a disk in the sidebar. OpenDisk asks for access once and remembers it.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("OpenDisk")
    }

    private func selectInitialLocation() {
        guard selection == nil, !didSelectInitialLocation, !deviceMonitor.devices.isEmpty else { return }
        didSelectInitialLocation = true
        let canOpen = { (location: DeviceInfo) in
            !ScanAccess.isSandboxed || scanAccess.isGranted(location.path)
        }
        let locations = deviceMonitor.devices + folderLocations
        if let last = locations.first(where: { $0.path == lastLocation }),
           Self.isInternal(last.path), canOpen(last) {
            selection = last.path
        } else if let computer = deviceMonitor.devices.first(where: { $0.path == "/" }), canOpen(computer) {
            selection = computer.path
        }
    }

    private static func isInternal(_ path: String) -> Bool {
        path != "/Volumes" && !path.hasPrefix("/Volumes/")
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

        isChoosingFolder = true
    }

    private func addFolder(at url: URL) {
        let path = url.path
        if !deviceMonitor.devices.contains(where: { $0.path == path }),
           !savedFolderPaths.contains(path) {
            storedFolders = (savedFolderPaths + [path]).joined(separator: "\n")
        }
        selection = path
    }

    private func removeFolder(_ folder: DeviceInfo) {
        let wasSelected = selection == folder.path
        if ScanAccess.isSandboxed {
            if let grant = scanAccess.grants.first(where: { $0.path == folder.path }) {
                scanAccess.removeGrant(grant)
            }
        } else {
            storedFolders = savedFolderPaths.filter { $0 != folder.path }.joined(separator: "\n")
        }
        if wasSelected { selection = nil }
    }
}

#Preview {
    ContentView()
}
