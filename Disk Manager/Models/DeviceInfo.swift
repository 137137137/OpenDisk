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
        ByteFormatter.formatDecimalNoFraction(totalStorage)
    }

    var formattedAvailableStorage: String {
        ByteFormatter.formatDecimalNoFraction(availableStorage)
    }

    var formattedUsedStorage: String {
        ByteFormatter.formatDecimalNoFraction(usedStorage)
    }
}

