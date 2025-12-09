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
                // Background track
                Capsule()
                    .fill(.quaternary)

                // Filled portion - uses system accent color
                Capsule()
                    .fill(.tint)
                    .frame(width: max(0, geometry.size.width * usagePercentage))
            }
        }
        .frame(height: 4)
    }
}
