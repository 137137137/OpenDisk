import Foundation

@MainActor
class DiskSpaceUtility: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    private let diskAnalyzer = DiskAnalyzer()
    
    init() {
        fetchDeviceInfo()
    }
    
    func fetchDeviceInfo() {
        Task {
            var deviceList: [DeviceInfo] = []
            
            // Get main disk info - show Computer option for full disk analysis
            if let mainDiskInfo = await getDiskSpace(for: "/") {
                let computerDevice = DeviceInfo(
                    name: "Computer",
                    icon: "desktopcomputer",
                    path: "/",
                    totalStorage: mainDiskInfo.totalSpace,
                    availableStorage: mainDiskInfo.availableSpace,
                    subtitle: ByteFormatter.formatDecimal(Int64(mainDiskInfo.totalSpace)) + " Total"
                )
                deviceList.append(computerDevice)
            }
            
            // Scan for external volumes
            let externalVolumes = await diskAnalyzer.scanExternalVolumes()
            
            let externalDevices = await withTaskGroup(of: DeviceInfo?.self) { group in
                var devices: [DeviceInfo] = []
                
                for volume in externalVolumes {
                    group.addTask {
                        guard let volumeInfo = await self.getDiskSpace(for: volume.path) else { return nil }
                        let subtitle = await MainActor.run {
                            ByteFormatter.formatDecimal(Int64(volumeInfo.totalSpace)) + " Total"
                        }
                        return DeviceInfo(
                            name: volume.name,
                            icon: "externaldrive", 
                            path: volume.path,
                            totalStorage: volumeInfo.totalSpace,
                            availableStorage: volumeInfo.availableSpace,
                            subtitle: subtitle
                        )
                    }
                }
                
                for await device in group {
                    if let device = device {
                        devices.append(device)
                    }
                }
                return devices
            }
            
            devices = deviceList + externalDevices
        }
    }
    
    private func getDiskSpace(for path: String) async -> (totalSpace: Double, availableSpace: Double)? {
        let isExternalVolume = path.hasPrefix("/Volumes/")
        
        // For external volumes, use a simpler approach that avoids problematic APIs
        if isExternalVolume {
            return await getDiskSpaceForExternalVolume(path: path)
        }
        
        // For internal volumes, use the standard approach
        return await getDiskSpaceStandard(path: path)
    }
    
    private func getDiskSpaceForExternalVolume(path: String) async -> (totalSpace: Double, availableSpace: Double)? {
        // Use FileManager attributes directly for external volumes to avoid cache deletion API errors
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let totalSize = attributes[.systemSize] as? Int64,
               let freeSize = attributes[.systemFreeSize] as? Int64 {
                return (totalSpace: Double(totalSize), availableSpace: Double(freeSize))
            }
        } catch {
            print("FileManager method failed for external volume \(path): \(error)")
        }
        
        // Fallback: try URL resource values but with basic keys only
        do {
            let url = URL(fileURLWithPath: path)
            let resourceValues = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey
            ])
            
            guard let totalCapacity = resourceValues.volumeTotalCapacity else {
                print("Could not get total capacity for external volume \(path)")
                return nil
            }
            
            // For external volumes, prefer the basic available capacity key
            let availableCapacity = resourceValues.volumeAvailableCapacity ?? 0
            
            return (totalSpace: Double(totalCapacity), availableSpace: Double(availableCapacity))
            
        } catch {
            print("URL resource values method also failed for external volume \(path): \(error)")
            return nil
        }
    }
    
    private func getDiskSpaceStandard(path: String) async -> (totalSpace: Double, availableSpace: Double)? {
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
            
            // Try different available capacity keys in order of preference for internal volumes
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
}