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
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 4)
                
                // Used storage
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.blue)
                    .frame(width: geometry.size.width * usagePercentage, height: 4)
            }
        }
        .frame(height: 4)
    }
}