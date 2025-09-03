import SwiftUI

struct StorageProgressBar: View {
    let totalStorage: Double
    let availableStorage: Double
    
    private var usedStorage: Double {
        totalStorage - availableStorage
    }
    
    private var usagePercentage: Double {
        guard totalStorage > 0 else { return 0 }
        return usedStorage / totalStorage
    }
    
    var body: some View {
        ProgressView(value: usagePercentage)
            .progressViewStyle(LinearProgressViewStyle())
            .tint(.primary)
    }
}