import SwiftUI

/// Bottom bar under the analysis split view:
/// live progress + throughput while a scan runs, totals and duration once
/// it finishes.
struct ScanStatusBar: View {
    let isScanning: Bool
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
            if isScanning {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            HStack(spacing: 12) {
                if isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(itemsScanned > 0 ? scanStatus : "Scanning…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !filesPerSecond.isEmpty {
                            Text("· \(filesPerSecond)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("Total")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    if scanDuration > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text(DurationFormatter.scanDuration(scanDuration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Text(ByteFormatter.formatFileSize(totalBytes))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text("(\(itemCount) items)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}
