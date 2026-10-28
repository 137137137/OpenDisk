import Foundation

enum ByteFormatter {
    private static let fileFormatter = Mutex<ByteCountFormatter>({
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return formatter
    }())

    private static let decimalNoFractionFormatter = Mutex<ByteCountFormatter>({
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting = false
        formatter.zeroPadsFractionDigits = false
        formatter.allowedUnits = [.useGB, .useTB]
        return formatter
    }())

    static func formatFileSize(_ bytes: Int64) -> String {
        fileFormatter.withLock { $0.string(fromByteCount: bytes) }
    }

    static func formatCapacity(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 || bytes <= 0
            ? formatDecimalNoFraction(max(bytes, 0))
            : formatFileSize(bytes)
    }

    static func formatDecimalNoFraction(_ bytes: Int64) -> String {
        let formatted = decimalNoFractionFormatter.withLock { $0.string(fromByteCount: bytes) }
        if let range = formatted.range(of: "[.,]\\d+", options: .regularExpression) {
            return String(formatted[..<range.lowerBound] + formatted[range.upperBound...])
        }
        return formatted
    }
}

enum DurationFormatter {
    static func scanDuration(_ duration: TimeInterval) -> String {
        let elapsed: String
        if duration < 1 {
            elapsed = Duration.milliseconds(Int64((duration * 1_000).rounded()))
                .formatted(.units(allowed: [.milliseconds], width: .abbreviated))
        } else if duration < 60 {
            elapsed = Duration.milliseconds(Int64((duration * 1_000).rounded()))
                .formatted(.units(allowed: [.seconds], width: .wide, fractionalPart: .show(length: 1)))
        } else {
            let total = Int64(duration.rounded())
            let units: Set<Duration.UnitsFormatStyle.Unit> = total >= 3_600 ? [.hours, .minutes] : [.minutes, .seconds]
            elapsed = Duration.seconds(total)
                .formatted(.units(allowed: units, width: .abbreviated, zeroValueUnits: .show(length: 1)))
        }
        return String(localized: "Scanned in \(elapsed)")
    }
}
