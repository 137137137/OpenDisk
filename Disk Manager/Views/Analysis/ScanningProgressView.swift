import SwiftUI

/// Displays scanning progress with detailed statistics.
///
/// Shows:
/// - Current scanning status and path
/// - CPU core utilization info
/// - Progress bar with percentage
/// - Estimated time remaining
/// - Files per second rate
struct ScanningProgressView: View {
    let scanProgress: String
    let currentScanPath: String
    let filesPerSecond: String
    let totalDiskScannedBytes: Int64
    let totalUsedDiskSpace: Int64
    let estimatedTimeRemaining: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            VStack(spacing: 12) {
                Text("Analyzing Disk Usage")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(scanProgress)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                // Current scanning path and rate
                if !currentScanPath.isEmpty && !filesPerSecond.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .foregroundStyle(.blue)
                            .font(.caption)

                        Text(currentScanPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Image(systemName: "speedometer")
                            .foregroundStyle(.green)
                            .font(.caption)

                        Text(filesPerSecond)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 300)
                }

                // Enhanced progress display
                VStack(spacing: 16) {
                    // CPU cores info
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundStyle(.blue)
                        Text("Using \(ProcessInfo.processInfo.activeProcessorCount) CPU cores - Maximum parallelization")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    // Main progress section
                    if totalUsedDiskSpace > 0 {
                        progressSection
                    } else {
                        // Initial loading state
                        VStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Initializing multi-core scan...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        let rawPercentage = totalDiskScannedBytes > 0
            ? Double(totalDiskScannedBytes) / Double(totalUsedDiskSpace) * 100
            : 0.0
        let scannedPercentage = min(100.0, max(0.0, rawPercentage))

        VStack(spacing: 12) {
            // Progress header
            HStack(spacing: 8) {
                Text("Scanned: \(ByteFormatter.formatFileSize(totalDiskScannedBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fontWeight(.medium)

                Spacer()

                Text(String(format: "%.1f%%", scannedPercentage))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.blue)
            }
            .frame(maxWidth: 420)

            // Progress bar
            ProgressView(value: scannedPercentage, total: 100)
                .frame(maxWidth: 420, minHeight: 8)
                .scaleEffect(y: 1.5)
                .tint(.blue)

            // Progress footer with time estimate
            HStack {
                Text("of \(ByteFormatter.formatFileSize(totalUsedDiskSpace)) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !estimatedTimeRemaining.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(estimatedTimeRemaining)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 420)
        }
    }
}

#Preview {
    ScanningProgressView(
        scanProgress: "Scanning files...",
        currentScanPath: "/Users/test/Documents",
        filesPerSecond: "15,234 files/sec",
        totalDiskScannedBytes: 250_000_000_000,
        totalUsedDiskSpace: 500_000_000_000,
        estimatedTimeRemaining: "~30 seconds"
    )
    .frame(width: 500, height: 400)
}
