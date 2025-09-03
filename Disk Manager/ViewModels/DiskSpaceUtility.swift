import Foundation

class DiskSpaceUtility: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    private let diskAnalyzer = DiskAnalyzer()
    
    init() {
        fetchDeviceInfo()
    }
    
    func fetchDeviceInfo() {
        DispatchQueue.global(qos: .background).async {
            var deviceList: [DeviceInfo] = []
            
            // Get main disk info - show Computer option for full disk analysis
            if let mainDiskInfo = self.getDiskSpace(for: "/") {
                let computerDevice = DeviceInfo(
                    name: "Computer",
                    icon: "desktopcomputer",
                    path: "/",
                    totalStorage: mainDiskInfo.totalSpace,
                    availableStorage: mainDiskInfo.availableSpace,
                    subtitle: self.formatBytes(mainDiskInfo.totalSpace) + " Total"
                )
                deviceList.append(computerDevice)
            }
            
            // Scan for external volumes asynchronously
            Task {
                await self.diskAnalyzer.scanExternalVolumes()
                let externalVolumes = await MainActor.run {
                    self.diskAnalyzer.externalVolumes
                }
                
                let finalDeviceList = deviceList + externalVolumes.compactMap { volume in
                    guard let volumeInfo = self.getDiskSpace(for: volume.path) else { return nil }
                    return DeviceInfo(
                        name: volume.name,
                        icon: "externaldrive", 
                        path: volume.path,
                        totalStorage: volumeInfo.totalSpace,
                        availableStorage: volumeInfo.availableSpace,
                        subtitle: self.formatBytes(volumeInfo.totalSpace) + " Total"
                    )
                }
                
                await MainActor.run {
                    self.devices = finalDeviceList
                }
            }
        }
    }
    
    private func getDiskSpace(for path: String) -> (totalSpace: Double, availableSpace: Double)? {
        do {
            let url = URL(fileURLWithPath: path)
            let resourceValues = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            
            guard let totalCapacity = resourceValues.volumeTotalCapacity,
                  let availableCapacity = resourceValues.volumeAvailableCapacityForImportantUsage else {
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