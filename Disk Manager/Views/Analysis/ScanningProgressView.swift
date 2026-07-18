import SwiftUI

/// Smooths the jumpy real scan percentage into a steadily advancing
/// display value, easing faster the further it lags behind the target.
@MainActor
private final class ProgressAnimator: ObservableObject {
    @Published private(set) var displayPercentage: Double = 0

    private var timer: Timer?
    private var targetPercentage: Double = 0
    private var internalValue: Double = 0

    private static let ticksPerSecond = 15.0
    /// Advance speed (percent per tick) by how far display lags target.
    private static let easing: [(minimumGap: Double, speed: Double)] = [
        (30, 8.0), (10, 5.0), (0, 3.0), (-10, 1.5), (-30, 0.5), (-.infinity, 0.2),
    ]

    func start(target: Double) {
        internalValue = 0
        displayPercentage = 0
        targetPercentage = target
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / Self.ticksPerSecond, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
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

        if targetPercentage >= 99.9 {
            internalValue = min(100, internalValue + 3.0)
        } else {
            let gap = targetPercentage - internalValue
            let speed = Self.easing.first { gap > $0.minimumGap }?.speed ?? 0.2
            internalValue = min(99.0, internalValue + speed)
        }

        if abs(internalValue - displayPercentage) >= 0.5 {
            displayPercentage = internalValue
        }
    }

    deinit {
        timer?.invalidate()
    }
}

/// Scan-in-progress panel: status line, current path, throughput, and an
/// animated progress meter.
struct ScanningProgressView: View {
    let statusDescription: String
    let currentScanPath: String
    let filesPerSecond: String
    let totalDiskScannedBytes: Int64
    let totalUsedDiskSpace: Int64

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

                Text(statusDescription)
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
            animator.start(target: actualPercentage)
        }
        .onDisappear {
            animator.stop()
        }
    }
}

#Preview {
    ScanningProgressView(
        statusDescription: "Scanning: 250 GB (1,234,567 items)",
        currentScanPath: "/Users/test/Documents",
        filesPerSecond: "152,340 files/sec",
        totalDiskScannedBytes: 250_000_000_000,
        totalUsedDiskSpace: 500_000_000_000
    )
    .frame(width: 500, height: 400)
}
