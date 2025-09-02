import Foundation

class DiskSpaceUtility: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    
    init() {
        fetchDeviceInfo()
    }
    
    func fetchDeviceInfo() {
        DispatchQueue.global(qos: .background).async {
            var deviceList: [DeviceInfo] = []
            
            // Get home folder info
            let homeURL = FileManager.default.homeDirectoryForCurrentUser
            let homeDevice = DeviceInfo(
                name: "Home Folder",
                icon: "house",
                totalStorage: 0,
                availableStorage: 0,
                subtitle: homeURL.path
            )
            deviceList.append(homeDevice)
            
            // Get main disk info
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