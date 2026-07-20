import SwiftUI

/// Thin capacity bar showing how full a volume is — the standard linear
/// progress control, which adapts to appearance and accessibility settings
/// on its own.
struct StorageProgressBar: View {
    let totalBytes: Int64
    let availableBytes: Int64

    private var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - availableBytes) / Double(totalBytes)
    }

    var body: some View {
        ProgressView(value: usedFraction)
            .progressViewStyle(.linear)
            .controlSize(.small)
    }
}
