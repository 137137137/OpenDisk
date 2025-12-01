import SwiftUI

// MARK: - Progress Animator

/// Handles smooth progress animation independently from view updates
@MainActor
final class ProgressAnimator: ObservableObject {
    @Published private(set) var displayPercentage: Double = 0
    private var timer: Timer?
    private var targetPercentage: Double = 0

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func updateTarget(_ target: Double) {
        targetPercentage = target
    }

    private func tick() {
        guard displayPercentage < 100 else {
            stop()
            return
        }

        let target = targetPercentage
        let current = displayPercentage

        // Scan complete - finish quickly
        if target >= 99.9 {
            displayPercentage = min(100, current + 2.0)
            return
        }

        // Speed based on gap (% per frame at 30fps)
        let gap = target - current
        let speed: Double
        if gap > 30 {
            speed = 4.0
        } else if gap > 10 {
            speed = 2.5
        } else if gap > 0 {
            speed = 1.5
        } else if gap > -10 {
            speed = 0.8
        } else if gap > -30 {
            speed = 0.3
        } else {
            speed = 0.1
        }

        displayPercentage = min(99.0, current + speed)
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Scanning Progress View

/// Displays scanning progress with detailed statistics.
struct ScanningProgressView: View {
    let scanProgress: String
    let currentScanPath: String
    let filesPerSecond: String
    let totalDiskScannedBytes: Int64
    let totalUsedDiskSpace: Int64
    let estimatedTimeRemaining: String

    @StateObject private var animator = ProgressAnimator()

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

                Text(String(format: "%.1f%%", animator.displayPercentage))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.blue)
                    .monospacedDigit()
            }
            .frame(maxWidth: 420)

            // Progress bar
            ProgressView(value: animator.displayPercentage, total: 100)
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
        .onChange(of: actualPercentage) { _, newValue in
            animator.updateTarget(newValue)
        }
        .onAppear {
            animator.updateTarget(actualPercentage)
            animator.start()
        }
        .onDisappear {
            animator.stop()
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
