import SwiftUI

// MARK: - Progress Animator

/// Handles smooth progress animation with minimal performance impact
@MainActor
final class ProgressAnimator: ObservableObject {
    @Published private(set) var displayPercentage: Double = 0
    private var timer: Timer?
    private var targetPercentage: Double = 0
    private var internalValue: Double = 0  // Non-published for calculations

    func start() {
        guard timer == nil else { return }
        // 15fps is smooth enough for progress bars, half the CPU of 30fps
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/15.0, repeats: true) { [weak self] _ in
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
        // Complete - stop timer
        guard internalValue < 100 else {
            displayPercentage = 100
            stop()
            return
        }

        let target = targetPercentage
        let current = internalValue
        let gap = target - current

        // Scan complete - finish quickly
        if target >= 99.9 {
            internalValue = min(100, current + 3.0)
        } else {
            // Speed based on gap (% per frame at 15fps - doubled from 30fps)
            let speed: Double
            if gap > 30 {
                speed = 8.0
            } else if gap > 10 {
                speed = 5.0
            } else if gap > 0 {
                speed = 3.0
            } else if gap > -10 {
                speed = 1.5
            } else if gap > -30 {
                speed = 0.5
            } else {
                speed = 0.2
            }
            internalValue = min(99.0, current + speed)
        }

        // Only trigger SwiftUI update if value changed by >= 0.5%
        // This reduces re-renders significantly
        if abs(internalValue - displayPercentage) >= 0.5 {
            displayPercentage = internalValue
        }
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
            // Percentage display
            Text(String(format: "%.1f%%", animator.displayPercentage))
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.blue)
                .monospacedDigit()

            // Progress bar
            ProgressView(value: animator.displayPercentage, total: 100)
                .frame(maxWidth: 420, minHeight: 8)
                .scaleEffect(y: 1.5)
                .tint(.blue)
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
