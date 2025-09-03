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
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            
            guard let totalCapacity = resourceValues.volumeTotalCapacity else {
                print("Could not get total capacity for \(path)")
                return nil
            }
            
            // Try different available capacity keys in order of preference
            var availableCapacity: Int? = nil
            
            if let importantUsage = resourceValues.volumeAvailableCapacityForImportantUsage {
                availableCapacity = Int(importantUsage)
            } else if let generalAvailable = resourceValues.volumeAvailableCapacity {
                availableCapacity = Int(generalAvailable)
            }
            
            guard let available = availableCapacity else {
                print("Could not get available capacity for \(path)")
                return nil
            }
            
            return (totalSpace: Double(totalCapacity), availableSpace: Double(available))
            
        } catch {
            print("Error getting disk space for \(path): \(error)")
            
            // Fallback: try using FileManager attributes
            do {
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
                if let totalSize = attributes[.systemSize] as? Int64,
                   let freeSize = attributes[.systemFreeSize] as? Int64 {
                    return (totalSpace: Double(totalSize), availableSpace: Double(freeSize))
                }
            } catch {
                print("Fallback method also failed for \(path): \(error)")
            }
            
            return nil
        }
    }
    
    private func formatBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: Int64(bytes))
    }
}