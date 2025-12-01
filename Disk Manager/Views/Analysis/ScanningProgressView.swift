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

    // Smooth progress - always moving, speed adjusts based on actual progress
    @State private var displayPercentage: Double = 0

    // 60fps timer for smooth visual updates
    private let timer = Timer.publish(every: 1.0/60.0, on: .main, in: .common).autoconnect()

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

    /// Actual percentage from scan data
    private var actualPercentage: Double {
        guard totalUsedDiskSpace > 0, totalDiskScannedBytes > 0 else { return 0 }
        return min(100.0, Double(totalDiskScannedBytes) / Double(totalUsedDiskSpace) * 100)
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(spacing: 12) {
            // Progress header
            HStack(spacing: 8) {
                Text("Scanned: \(ByteFormatter.formatFileSize(totalDiskScannedBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fontWeight(.medium)

                Spacer()

                Text(String(format: "%.1f%%", displayPercentage))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.blue)
                    .monospacedDigit()
            }
            .frame(maxWidth: 420)

            // Progress bar - uses smoothly interpolated displayPercentage
            ProgressView(value: displayPercentage, total: 100)
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
        .onReceive(timer) { _ in
            let target = actualPercentage
            let current = displayPercentage

            // Scan complete - snap to 100%
            if target >= 99.9 {
                displayPercentage = min(100, current + 2.0)
                return
            }

            // Base speed: ~30% per second at 60fps = 0.5% per frame
            // This ensures we'd reach 99% in about 3 seconds if moving steadily
            let baseSpeed: Double = 0.5

            // Adjust speed based on gap between actual and display
            let gap = target - current
            let speed: Double

            if gap > 30 {
                speed = baseSpeed * 4.0   // Very behind - fast catchup
            } else if gap > 10 {
                speed = baseSpeed * 2.5   // Behind - speed up
            } else if gap > 0 {
                speed = baseSpeed * 1.5   // Slightly behind - normal+
            } else if gap > -10 {
                speed = baseSpeed * 0.8   // Slightly ahead - slow down
            } else if gap > -30 {
                speed = baseSpeed * 0.3   // Ahead - crawl
            } else {
                speed = baseSpeed * 0.1   // Way ahead - barely move
            }

            // Always move forward, cap at 99% until scan completes
            displayPercentage = min(99.0, current + speed)
        }
        .onAppear {
            displayPercentage = 0
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
