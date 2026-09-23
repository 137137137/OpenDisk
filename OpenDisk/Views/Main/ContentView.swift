import SwiftUI

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
        .environment(scanAccess)
    }
}

#Preview {
    ContentView()
}
