import Foundation

struct DeviceInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let icon: String
    let path: String  // Path to scan when selected
    let totalStorage: Double
    let availableStorage: Double
    let subtitle: String?
    
    var usedStorage: Double {
        totalStorage - availableStorage
    }
    
    var usagePercentage: Double {
        usedStorage / totalStorage
    }
    
    var formattedTotalStorage: String {
        formatBytes(totalStorage)
    }
    
    var formattedAvailableStorage: String {
        formatBytes(availableStorage)
    }
    
    private func formatBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

