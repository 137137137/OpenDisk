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
        .onAppear(perform: selectBootVolumeIfNeeded)
        .onChange(of: deviceMonitor.devices) { _, _ in
            selectBootVolumeIfNeeded()
        }
    }

    /// Auto-selects the boot volume once devices load, unless the user has
    /// already picked something.
    private func selectBootVolumeIfNeeded() {
        if selectedDevice == nil {
            selectedDevice = deviceMonitor.devices.first(where: \.isBootVolume)
        }
    }
}

#Preview {
    ContentView()
}
