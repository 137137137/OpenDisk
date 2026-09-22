import SwiftUI

/// Bottom bar under the analysis split view:
/// live progress + throughput while a scan runs, totals and duration once
/// it finishes, and the volume's capacity throughout ("X available of Y",
/// the phrasing System Settings › Storage uses).
struct ScanStatusBar: View {
    let isScanning: Bool
    /// What the scan is doing; words the stretch before any item has been
    /// counted (cache + change-journal work reads as a stall otherwise).
    var phase: ScanPhase = .scanning
    /// Fraction of the volume's used bytes scanned so far; nil shows an
    /// indeterminate bar.
    let progressFraction: Double?
    /// Raw scan counters; this view owns their formatting.
    let scannedBytes: Int64
    let itemsScanned: Int
    let scanStartDate: Date?
    let scanDuration: TimeInterval
    let totalBytes: Int64
    let itemCount: Int
    /// Capacity of the volume being analyzed; nil hides the readout.
    var volumeCapacity: VolumeCapacity?

    private var scanStatus: String {
        "Scanning: \(ByteFormatter.formatFileSize(scannedBytes)) (\(itemsScanned.formatted()) items)"
    }

    private var filesPerSecond: String {
        guard let scanStartDate, itemsScanned > 0 else { return "" }
        let elapsed = Date().timeIntervalSince(scanStartDate)
        guard elapsed > 0 else { return "" }
        return "\(Int(Double(itemsScanned) / elapsed).formatted()) files/sec"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if isScanning {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            HStack(spacing: 6) {
                if isScanning {
                    ProgressView()
                        .controlSize(.mini)
                    Text(itemsScanned > 0
                        ? scanStatus
                        : phase == .checkingChanges
                            ? "Checking what changed since the last scan…"
                            : "Scanning…")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !filesPerSecond.isEmpty {
                        Text("· \(filesPerSecond)")
                            .foregroundStyle(.tertiary)
                    }
                } else if scanDuration > 0 {
                    Text(DurationFormatter.scanDuration(scanDuration))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if let volumeCapacity {
                    capacityReadout(volumeCapacity)
                    Spacer(minLength: 12)
                }

                Text(ByteFormatter.formatFileSize(totalBytes))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("· \(itemCount) item\(itemCount == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    /// Capacity bar plus "X available of Y". The tooltip and accessibility
    /// value carry the full used / available / total breakdown so the bar
    /// text can stay short.
    private func capacityReadout(_ capacity: VolumeCapacity) -> some View {
        let available = ByteFormatter.formatFileSize(capacity.available)
        let used = ByteFormatter.formatFileSize(capacity.used)
        let total = ByteFormatter.formatFileSize(capacity.total)
        return HStack(spacing: 8) {
            StorageProgressBar(
                totalBytes: capacity.total,
                availableBytes: capacity.available
            )
            .frame(width: 96)
            Text("\(available) available of \(total)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .help("Used: \(used)\nAvailable: \(available)\nTotal: \(total)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk space")
        .accessibilityValue("\(used) used, \(available) available of \(total)")
    }
}
