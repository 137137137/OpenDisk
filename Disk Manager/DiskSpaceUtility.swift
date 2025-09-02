import Foundation

class DiskSpaceUtility: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    
    init() {
        fetchDeviceInfo()
    }
    
    func fetchDeviceInfo() {
        DispatchQueue.global(qos: .background).async {
            var deviceList: [DeviceInfo] = []
            
            // Get main disk info - only show Computer option for full disk analysis
            if let mainDiskInfo = self.getDiskSpace(for: "/") {
                let computerDevice = DeviceInfo(
                    name: "Computer",
                    icon: "desktopcomputer",
                    totalStorage: mainDiskInfo.totalSpace,
                    availableStorage: mainDiskInfo.availableSpace,
                    subtitle: self.formatBytes(mainDiskInfo.totalSpace) + " Total"
                )
                deviceList.append(computerDevice)
            }
            
            DispatchQueue.main.async {
                self.devices = deviceList
            }
        }
    }
    
    private func getDiskSpace(for path: String) -> (totalSpace: Double, availableSpace: Double)? {
        do {
            let url = URL(fileURLWithPath: path)
            let resourceValues = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey
            ])
            
            guard let totalCapacity = resourceValues.volumeTotalCapacity,
                  let availableCapacity = resourceValues.volumeAvailableCapacity else {
                return nil
            }
            
            return (totalSpace: Double(totalCapacity), availableSpace: Double(availableCapacity))
        } catch {
            print("Error getting disk space: \(error)")
            return nil
        }
    }
    
    private func formatBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: Int64(bytes))
    }
}