import SwiftUI

struct ScanStatusBar<Leading: View>: View {
    let isScanning: Bool
    var phase: ScanPhase = .scanning
    var stepsCompleted = 0
    var stepsTotal = 0
    let progressFraction: Double?
    let scannedBytes: Int64
    let itemsScanned: Int
    let scanStartDate: Date?
    let scanDuration: TimeInterval
    @ViewBuilder let leading: Leading

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
            HStack(spacing: 8) {
                leading
                    .frame(maxWidth: .infinity, alignment: .leading)
                status
                    .font(.footnote)
                    .fixedSize()
                    .padding(.trailing, 14)
            }
        }
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        if isScanning && phase == .checkingChanges {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking what changed since the last scan…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if isScanning && phase == .applyingChanges {
            HStack(spacing: 6) {
                ProgressView(value: Double(stepsCompleted), total: Double(max(stepsTotal, 1)))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 80)
                Text("Updating changed folders (\(stepsCompleted.formatted()) of \(stepsTotal.formatted()))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if isScanning {
            HStack(spacing: 6) {
                if let progressFraction {
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 80)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(itemsScanned > 0 ? scanStatus : "Scanning…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !filesPerSecond.isEmpty {
                    Text("· \(filesPerSecond)")
                        .foregroundStyle(.tertiary)
                }
            }
        } else if scanDuration > 0 {
            Text(DurationFormatter.scanDuration(scanDuration))
                .foregroundStyle(.tertiary)
        }
    }
}
