import SwiftUI

struct ContentView: View {
    @State private var deviceMonitor = DeviceMonitor()
    @State private var selectedDevice: DeviceInfo?

    var body: some View {
        NavigationSplitView {
            List(deviceMonitor.devices, selection: $selectedDevice) { device in
                DeviceRow(device: device)
                    .tag(device)
            }
            .listStyle(.sidebar)
            .navigationTitle("Devices")
        } detail: {
            if let selectedDevice {
                DiskAnalysisView(
                    rootPath: selectedDevice.path,
                    rootName: selectedDevice.name,
                    totalUsedSpace: selectedDevice.usedBytes
                ) {
                    self.selectedDevice = nil
                }
                // Re-key the view per device so its navigation state resets
                // when the selection jumps directly between devices.
                .id(selectedDevice.id)
            } else {
                ContentUnavailableView(
                    "Select a device to analyze",
                    systemImage: "externaldrive",
                    description: Text("Choose a device from the sidebar to view its disk usage")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    ContentView()
}
