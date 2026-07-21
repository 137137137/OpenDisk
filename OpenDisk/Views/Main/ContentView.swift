import SwiftUI

/// Root navigation: a disk-picker screen, pushing the analysis screen for
/// the selected disk or a user-chosen folder. `NavigationStack` provides
/// the system back button, title handling and toolbar treatment.
struct ContentView: View {
    @State private var deviceMonitor = DeviceMonitor()
    @State private var scanAccess = ScanAccess()
    @State private var path: [DeviceInfo] = []

    var body: some View {
        NavigationStack(path: $path) {
            DevicePickerView(
                devices: deviceMonitor.devices,
                onScanFolder: { folderDevice in path.append(folderDevice) }
            )
            .navigationDestination(for: DeviceInfo.self) { device in
                DiskAnalysisView(
                    rootPath: device.path,
                    rootName: device.name,
                    totalUsedSpace: device.usedBytes
                )
            }
        }
        // Reachable by both the picker (to grant/list locations) and the
        // analysis screen (to hold security-scoped access during a scan).
        .environment(scanAccess)
    }
}

#Preview {
    ContentView()
}
