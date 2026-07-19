import SwiftUI

/// Root navigation: a disk-picker screen, pushing the analysis screen for
/// the selected disk. `NavigationStack` provides the system back button,
/// title handling and Liquid Glass toolbar treatment.
struct ContentView: View {
    @State private var deviceMonitor = DeviceMonitor()

    var body: some View {
        NavigationStack {
            DevicePickerView(devices: deviceMonitor.devices)
                .navigationDestination(for: DeviceInfo.self) { device in
                    DiskAnalysisView(
                        rootPath: device.path,
                        rootName: device.name,
                        totalUsedSpace: device.usedBytes
                    )
                }
        }
    }
}

#Preview {
    ContentView()
}
