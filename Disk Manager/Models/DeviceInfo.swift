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
    
    var formattedUsedStorage: String {
        formatBytes(usedStorage)
    }
    
    private func formatBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting = false
        formatter.includesCount = true
        formatter.includesUnit = true
        formatter.zeroPadsFractionDigits = false
        formatter.allowedUnits = [.useGB, .useTB] // Prefer GB and TB units
        formatter.formattingContext = .standalone
        
        // Round to nearest GB/TB for cleaner display
        let formattedString = formatter.string(fromByteCount: Int64(bytes))
        
        // Remove decimal places by parsing and reformatting
        if let range = formattedString.range(of: "\\.\\d+", options: .regularExpression) {
            return String(formattedString[..<range.lowerBound] + formattedString[range.upperBound...])
        }
        
        return formattedString
    }
}

