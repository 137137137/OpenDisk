import SwiftUI

@MainActor
final class ProgressAnimator: ObservableObject {
    @Published private(set) var displayPercentage: Double = 0
    private var timer: Timer?
    private var targetPercentage: Double = 0
    private var internalValue: Double = 0

    func start() {
        guard timer == nil else { return }
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
        guard internalValue < 100 else {
            displayPercentage = 100
            stop()
            return
        }

        let target = targetPercentage
        let current = internalValue
        let gap = target - current

        if target >= 99.9 {
            internalValue = min(100, current + 3.0)
        } else {
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

        if abs(internalValue - displayPercentage) >= 0.5 {
            displayPercentage = internalValue
        }
    }

    deinit {
        timer?.invalidate()
    }
}

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
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Analyzing Disk Usage")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(scanProgress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !currentScanPath.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)

                    Text(currentScanPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if !filesPerSecond.isEmpty {
                        Text(filesPerSecond)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 360)
            }

            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundStyle(.tint)
                Text("Using \(ProcessInfo.processInfo.activeProcessorCount) CPU cores")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if totalUsedDiskSpace > 0 {
                progressSection
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .glassEffect()
    }

    private var actualPercentage: Double {
        guard totalUsedDiskSpace > 0, totalDiskScannedBytes > 0 else { return 0 }
        return min(100.0, Double(totalDiskScannedBytes) / Double(totalUsedDiskSpace) * 100)
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(spacing: 12) {
            Text(String(format: "%.1f%%", animator.displayPercentage))
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.tint)
                .monospacedDigit()

            ProgressView(value: animator.displayPercentage, total: 100)
                .frame(maxWidth: 340)
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
