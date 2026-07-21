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
                    Text(itemsScanned > 0 ? scanStatus : "Scanning…")
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
}
