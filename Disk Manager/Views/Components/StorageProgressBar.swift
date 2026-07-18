import SwiftUI

/// Thin capacity bar showing how full a volume is.
struct StorageProgressBar: View {
    let totalBytes: Int64
    let availableBytes: Int64

    private var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - availableBytes) / Double(totalBytes)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)

                Capsule()
                    .fill(.tint)
                    .frame(width: max(0, geometry.size.width * usedFraction))
            }
        }
        .frame(height: 4)
    }
}
